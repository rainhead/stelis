#lang racket/base

;; The IO seam for taxon reasoning (st-ozp) — the impure adapter that makes
;; taxon-inherit.rkt's pure core runnable as a build node.
;;
;; Mirrors delta-explain.rkt's relationship to delta.rkt: the core stays pure and
;; testable on fixtures, and EVERYTHING that touches DuckDB, the fact file, or the
;; filesystem lives here. Effects at the boundary (DESIGN), even when the
;; transform itself has moved inside the engine.
;;
;; What it does, in order: read each species' lineage off the species mart, fold
;; the lineages into one rank tree, read the curated assertions, run the closure,
;; refuse to publish a conflicted result, cross-check against Bee-Gap's
;; independent per-species values, and write the reasoning artifact.

(require json
         racket/list
         racket/set
         racket/string
         racket/format
         racket/file
         "duckdb.rkt"
         "taxon-inherit.rkt"
         "cache.rkt"   ; env-resolve — artifact name -> where it lives
         "exec.rkt")   ; check-context accessors — the derivation-node interface

(provide (struct-out species-row)
         read-lineages
         lineages->taxonomy
         species-index
         reasoning-jsexpr
         beegap-nesting
         beegap-agreement
         BEEGAP-NESTING
         make-taxon-reasoning)

;; One row of the species mart: the JOIN key, the DISPLAY name, and the lineage.
;;   canonical  : string — lowercase canonical_name; beeatlas's join key
;;                everywhere (the notes store keys by it too), so the emitted
;;                artifact keys by it as well
;;   scientific : string — scientificName, the published form ("Biastes fulviventris")
;;   ranks      : (listof (or/c string #f)) — family…subgenus, #f where absent
(struct species-row (canonical scientific ranks) #:transparent)

;; The rank columns of the species mart, coarsest first — RANKS minus 'species,
;; which the row supplies as its canonical_name.
(define LINEAGE-RANKS (reverse (cdr (reverse RANKS))))

;; --- Reading the taxonomy ---------------------------------------------------------

;; read-lineages : path-string -> (listof species-row)
;; Every species' lineage from the species mart parquet, via DuckDB.
;;
;; coalesce(…,'') is not decoration: the DuckDB CLI's -list output renders SQL
;; NULL as the literal text "NULL" (checked on 1.5.5), so a subgenus-less species
;; would arrive as a taxon NAMED "NULL" and every such species across the whole
;; family would be merged into one bogus subgenus. Coalescing in SQL makes absence
;; unambiguous — the empty string, which lineage->taxa already treats as a missing
;; rank. Raises if the mart can't be read: a derivation with no taxonomy has
;; nothing to say, and silence would publish an empty artifact.
(define (read-lineages parquet)
  (define cols (append '("canonical_name" "scientificName")
                       (map symbol->string LINEAGE-RANKS)))
  (define sql
    (string-append
     "SELECT " (string-join (for/list ([c (in-list cols)])
                              (string-append "coalesce(" c ",'')"))
                            ", ")
     " FROM read_parquet('" (~a parquet) "') ORDER BY canonical_name"))
  (define out (duckdb-query #f sql))
  (unless out (error 'read-lineages "could not read ~a via duckdb" parquet))
  (for*/list ([line (in-list (string-split out "\n"))]
              [tup (in-value (string-split line "|" #:trim? #f))]
              #:when (and (= (length tup) (length cols))
                          (not (string=? (first tup) ""))))
    (species-row (first tup)
                 (if (string=? (second tup) "") (first tup) (second tup))
                 (map blank->false (drop tup 2)))))

(define (blank->false s) (if (string=? s "") #f s))

;; lineages->taxonomy : (listof species-row) -> (listof taxon)
;; Every lineage folded into one deduplicated rank tree. Genus-level checklist
;; records (39 of them: canonical_name "biastes", no specific epithet) come along
;; as species-rank nodes under their genus. That is correct rather than a defect
;; — such a record IS characterized by what its genus inherits, and the site keys
;; those pages by canonical_name like any other.
(define (lineages->taxonomy rows)
  (merge-taxa
   (append*
    (for/list ([r (in-list rows)])
      (lineage->taxa
       (map cons RANKS (append (species-row-ranks r) (list (species-row-canonical r)))))))))

;; species-index : (listof species-row) -> hash
;; taxon key -> the species-row behind it, so a derived fact can be turned back
;; into a published record (the join key and the display name).
(define (species-index rows)
  (for/hash ([r (in-list rows)])
    (values (make-taxon-key 'species (species-row-canonical r)) r)))

;; --- The published artifact --------------------------------------------------------

;; reasoning-jsexpr : (listof inherited) hash hash -> jsexpr
;; The artifact: canonical_name -> the traits derived for it, each with its proof
;; and its learner-facing sentence. Derived facts whose subject is a HIGHER taxon
;; (genus:Nomada and friends) are computed too and simply not emitted here — the
;; higher-taxon pages are a later slice, and this file's key space is species.
;; Object keys are emitted sorted (write-json orders them), and the per-species
;; list keeps the core's total order, so the file is byte-stable.
(define (reasoning-jsexpr rows index assertions glossary)
  (define ix (assertion-index assertions))
  (define by-species (make-hash))
  (for ([r (in-list rows)])
    (define sr (hash-ref index (inherited-subject r) #f))
    (when sr
      (hash-update! by-species (species-row-canonical sr)
                    (lambda (v) (cons (trait-jsexpr r sr ix) v))
                    '())))
  (hasheq 'glossary (for/hasheq ([(v d) (in-hash glossary)]) (values v d))
          'species (for/hasheq ([(k v) (in-hash by-species)])
                     (values (string->symbol k) (reverse v)))))

;; One derived trait as published. `hosts' and `note' ride SEPARATELY as well as
;; inside `explanation', so the site can lay them out rather than being handed one
;; opaque paragraph; what the value MEANS is not here at all — it is in the
;; top-level glossary, once, instead of repeated across a hundred species.
(define (trait-jsexpr r sr ix)
  (define a (hash-ref ix (list (inherited-source r) (inherited-trait r)) #f))
  (define base
    (hasheq 'trait (symbol->string (inherited-trait r))
            'value (symbol->string (inherited-value r))
            'because (hasheq 'rank (symbol->string (inherited-source-rank r))
                             'taxon (inherited-source-name r))
            'explanation (explanation-string r (species-row-scientific sr) ix)))
  (let* ([h (if (and a (assertion-hosts a)) (hash-set base 'hosts (assertion-hosts a)) base)]
         [h (if (and a (assertion-note a)) (hash-set h 'note (assertion-note a)) h)])
    h))

;; --- Cross-check against Bee-Gap ----------------------------------------------------

;; Our vocabulary against the spelling species_traits.nesting uses. This is a
;; CROSS-CHECK correspondence only — it is never published, and neither value is
;; rewritten into the other. It exists so the node can report how far an
;; independent per-species source agrees with what one high-rank assertion
;; derived: agreement is evidence the inheritance is sound, and the disagreements
;; are where a curator should look.
(define BEEGAP-NESTING (hash 'cleptoparasitic "Host Nest"))

;; beegap-nesting : path-string -> hash
;; canonical_name -> its Bee-Gap nesting value ("" where the source has none).
;; An unreadable mart yields an empty hash: the cross-check is a REPORT, and
;; losing it must not fail a build whose reasoning is otherwise fine.
(define (beegap-nesting parquet)
  (define out
    (duckdb-query #f (string-append
                      "SELECT coalesce(canonical_name,''), coalesce(nesting,'')"
                      " FROM read_parquet('" (~a parquet) "')")))
  (cond
    [(not out) (hash)]
    [else
     (for*/hash ([line (in-list (string-split out "\n"))]
                 [tup (in-value (string-split line "|" #:trim? #f))]
                 #:when (and (= 2 (length tup)) (not (string=? (first tup) ""))))
       (values (first tup) (second tup)))]))

;; beegap-agreement : (listof inherited) hash hash
;;   -> (values agree gaps disagreements uncovered)
;; How the derived nesting traits compare to Bee-Gap's per-species values, in BOTH
;; directions:
;;   agree/gaps/disagreements — over species the reasoning characterizes: how many
;;     Bee-Gap confirms, how many it has no value for (the coverage win), and where
;;     the two contradict each other.
;;   uncovered — the REVERSE: species Bee-Gap calls parasitic that NO assertion
;;     reaches. Checking only the first direction makes "0 disagreements" flattering
;;     but hollow, since a species the closure never touches can never disagree with
;;     anything. An entry here is one of two things, both worth a look: a cuckoo
;;     lineage nobody has asserted yet, or a bad record in Bee-Gap — the taxonomy
;;     acting as an independent check on the per-species source.
;; Nothing here is fatal. Which source is right is a curator's call, not the build's.
(define (beegap-agreement rows index beegap)
  (define parasitic-values (hash-values BEEGAP-NESTING))
  ;; canonical names the reasoning gave a nesting trait to
  (define characterized
    (for*/set ([r (in-list rows)]
               #:when (eq? 'nesting (inherited-trait r))
               [sr (in-value (hash-ref index (inherited-subject r) #f))]
               #:when sr)
      (species-row-canonical sr)))
  (define uncovered
    (sort (for/list ([(canonical value) (in-hash beegap)]
                     #:when (and (member value parasitic-values)
                                 (not (set-member? characterized canonical))))
            canonical)
          string<?))
  (define-values (agree gaps disagreements)
    (for/fold ([agree 0] [gaps 0] [bad '()])
              ([r (in-list rows)]
               #:when (eq? 'nesting (inherited-trait r))
               [sr (in-value (hash-ref index (inherited-subject r) #f))]
               #:when sr)
      (define expected (hash-ref BEEGAP-NESTING (inherited-value r) #f))
      (define actual (hash-ref beegap (species-row-canonical sr) ""))
      (cond
        [(string=? actual "") (values agree (add1 gaps) bad)]
        [(equal? actual expected) (values (add1 agree) gaps bad)]
        [else (values agree gaps (cons (species-row-canonical sr) bad))])))
  (values agree gaps (sort disagreements string<?) uncovered))

;; --- The node ------------------------------------------------------------------------

;; make-taxon-reasoning : symbol symbol symbol symbol
;;                        -> (check-context -> (values boolean string))
;; The `derivation' run body, given the ARTIFACT NAMES it reads and writes; every
;; path is resolved through the build-env, so the node carries no hardcoded
;; locations and moves with --export-dir like any other task.
;;
;; Everything is wrapped: a hand-edited fact file with a typo raises out of the
;; parser, and an exception escaping here would abort the whole build rather than
;; this one node. Caught, it fails just this node and blocks only its downstream —
;; the ordinary partial-success flow, which is the right blast radius for a
;; curator's editing mistake.
(define (make-taxon-reasoning species-artifact traits-artifact
                              facts-artifact output-artifact)
  (lambda (ctx)
    (with-handlers ([exn:fail? (lambda (e) (values #f (exn-message e)))])
      (define env (check-context-env ctx))
      (define (path-of a)
        (or (and env (env-resolve env a))
            (error 'taxon-reasoning "no path for artifact ~a" a)))
      (define parquet (path-of species-artifact))
      (define facts (path-of facts-artifact))
      (define out (path-of output-artifact))

      (define rows (read-lineages parquet))
      (define taxa (lineages->taxonomy rows))
      (define index (species-index rows))
      (define-values (glossary assertions) (read-fact-file facts))
      (define unresolved (unresolved-assertions taxa assertions))
      (define derived (inherited-traits (taxonomy->theory taxa assertions)))
      (define conflicts (trait-conflicts derived))

      (cond
        [(pair? conflicts)
         ;; ADR 0008 deferred defeasible override until a real lineage conflicted.
         ;; This is that moment arriving: refuse to publish a result whose meaning
         ;; is undecided, and name the lineage so the rule can be designed on it.
         (values #f (format "CONFLICT: ~a taxon/trait pair(s) inherit two values — ~a. Most-specific-wins is not yet decided (ADR 0008); refusing to publish."
                            (length conflicts)
                            (string-join
                             (for/list ([c (in-list (take conflicts (min 3 (length conflicts))))])
                               (format "~a ~a" (first c) (second c)))
                             ", ")))]
        [else
         (define j (reasoning-jsexpr derived index assertions glossary))
         (make-directory* (path-only* out))
         (call-with-output-file out #:exists 'replace
           (lambda (o) (write-json j o) (newline o)))
         (define-values (agree gaps bad uncovered)
           (beegap-agreement derived index (beegap-nesting (path-of traits-artifact))))
         (values #t (summary (hash-count (hash-ref j 'species)) (length assertions) (length derived)
                             agree gaps bad uncovered unresolved))]))))

(define (summary species assertions derived agree gaps bad uncovered unresolved)
  (string-append
   (format "~a species characterized from ~a assertion(s) (~a derived facts incl. higher taxa)"
           species assertions derived)
   (format "; vs Bee-Gap nesting: ~a agree, ~a gap(s) filled, ~a disagree"
           agree gaps (length bad))
   (if (pair? bad) (format " [~a]" (string-join (take bad (min 5 (length bad))) ", ")) "")
   (if (pair? uncovered)
       (format "; ~a Bee-Gap parasitic species NOT reached by any assertion [~a]"
               (length uncovered)
               (string-join (take uncovered (min 5 (length uncovered))) ", "))
       "")
   (if (pair? unresolved)
       (format "; ~a assertion(s) matched no local taxon: ~a"
               (length unresolved)
               (string-join (map assertion-name unresolved) ", "))
       "")))

;; the directory part of a path, as a path (racket/path's path-only returns #f
;; for a bare filename; a build-env always resolves to a complete path, but this
;; keeps the node honest if one ever doesn't).
(define (path-only* p)
  (define-values (dir _name _dir?) (split-path (if (path? p) p (string->path p))))
  (if (path? dir) dir (current-directory)))
