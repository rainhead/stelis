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
         "taxon-edges.rkt"
         "taxon-risk.rkt"
         "cache.rkt"   ; env-resolve — artifact name -> where it lives
         "exec.rkt")   ; check-context accessors — the derivation-node interface

(provide (struct-out species-row)
         read-lineages
         read-lineages*
         lineages->taxonomy
         species-index
         reasoning-jsexpr
         beegap-nesting
         beegap-agreement
         BEEGAP-NESTING
         read-host-edges
         read-forage-edges
         species-diet
         nesting-index
         dependencies-jsexpr
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

;; read-lineages* : path-string -> (listof species-row)
;; read-lineages, refusing an EMPTY result. Zero rows is not a legitimate state
;; here — a species mart with no species means the read matched nothing (a renamed
;; column, an output format change that fails the arity guard, a truncated mart),
;; and the reasoning would otherwise derive nothing, publish an artifact with an
;; empty species map, and report success. The site loader is absence-tolerant, so
;; every page would silently lose its reasoning on a GREEN build. Fail loudly
;; instead: a failed node blocks its downstream and leaves the last good artifact.
(define (read-lineages* parquet)
  (define rows (read-lineages parquet))
  (when (null? rows)
    (error 'taxon-reasoning
           "~a yielded no species rows — the taxonomy read matched nothing (renamed column? changed CLI output format?); refusing to publish an empty artifact"
           parquet))
  rows)

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

;; --- Edge typing inputs (st-an7) ----------------------------------------------------

;; read-host-edges : path-string -> (listof (cons string string))
;; The bee_parasite_hosts seed: (parasite canonical . host display name), one
;; per record. Refuses an empty read for read-lineages*'s reason: the seed has
;; hundreds of rows, so zero means the read matched nothing (renamed column,
;; format change) and publishing "no parasites depend on anything" on a green
;; build is exactly the silent wrong answer this family of guards exists for.
(define (read-host-edges csv)
  (define out
    (duckdb-query #f (string-append
                      "SELECT coalesce(parasite,''), coalesce(host_taxon,'')"
                      " FROM read_csv('" (~a csv) "') ORDER BY 1, 2")))
  (unless out (error 'taxon-reasoning "could not read ~a via duckdb" csv))
  (define rows
    (for*/list ([line (in-list (string-split out "\n"))]
                [tup (in-value (string-split line "|" #:trim? #f))]
                #:when (and (= 2 (length tup))
                            (not (string=? (first tup) ""))
                            (not (string=? (second tup) ""))))
      (cons (first tup) (second tup))))
  (when (null? rows)
    (error 'taxon-reasoning
           "~a yielded no parasite-host rows — the read matched nothing; refusing to publish an empty dependence set" csv))
  rows)

;; read-forage-edges : path-string -> (listof (list string (or/c string #f) string))
;; The bee_specialist_hosts seed: (canonical family-or-#f detail). The family is
;; legitimately absent where Fowler gives only a genus ("Larrea Cav."), so only
;; a blank canonical or detail drops a row; a blank family becomes #f, the same
;; absence-made-unambiguous move read-lineages makes.
(define (read-forage-edges csv)
  (define out
    (duckdb-query #f (string-append
                      "SELECT coalesce(canonical_name,''), coalesce(host_plant_family,''),"
                      " coalesce(host_plant_detail,'')"
                      " FROM read_csv('" (~a csv) "') ORDER BY 1, 3")))
  (unless out (error 'taxon-reasoning "could not read ~a via duckdb" csv))
  (define rows
    (for*/list ([line (in-list (string-split out "\n"))]
                [tup (in-value (string-split line "|" #:trim? #f))]
                #:when (and (= 3 (length tup))
                            (not (string=? (first tup) ""))
                            (not (string=? (third tup) ""))))
      (list (first tup) (blank->false (second tup)) (third tup))))
  (when (null? rows)
    (error 'taxon-reasoning
           "~a yielded no specialist rows — the read matched nothing; refusing to publish an empty dependence set" csv))
  rows)

;; species-diet : path-string -> hash
;; canonical_name -> Bee-Gap's INDEPENDENT foraging value, lowercase ("" where
;; absent), read from the bee_traits_beegap SEED — deliberately NOT the mart's
;; diet_breadth, which already merges the sources with Fowler winning ties
;; (species_traits.sql: membership in bee_specialist_hosts IS 'specialist'), so
;; flagging Fowler edges against it can only ever say 'agrees. The mart merges
;; the disagreement away silently; this flag is what makes it visible as
;; editorial content (st-an7 D2).
;; STRICT where beegap-nesting is tolerant, on purpose: the nesting read feeds a
;; report, so losing it costs a note; this feeds the PUBLISHED 'disputed /
;; 'no-value flag on every forage edge, and an unreadable seed silently
;; publishing "no-value" everywhere would erase the dispute record on a green
;; build. Raising lands in the node's handler and fails just this node.
(define (species-diet csv)
  (define out
    (duckdb-query #f (string-append
                      "SELECT coalesce(canonical_name,''), lower(coalesce(foraging,''))"
                      " FROM read_csv('" (~a csv) "')")))
  (unless out (error 'taxon-reasoning "could not read foraging from ~a via duckdb" csv))
  (for*/hash ([line (in-list (string-split out "\n"))]
              [tup (in-value (string-split line "|" #:trim? #f))]
              #:when (and (= 2 (length tup)) (not (string=? (first tup) ""))))
    (values (first tup) (second tup))))

;; nesting-index : (listof inherited) hash -> hash
;; canonical_name -> the species' inherited NESTING fact. This join is the reason
;; typing lives beside the closure (st-an7 D1): a parasite edge is obligate
;; because its bee is cleptoparasitic, and that fact — proof and all — is the
;; closure's own output, which nothing outside the engine can consume without
;; inverting the graph.
(define (nesting-index derived index)
  (for*/hash ([r (in-list derived)]
              #:when (eq? 'nesting (inherited-trait r))
              [sr (in-value (hash-ref index (inherited-subject r) #f))]
              #:when sr)
    (values (species-row-canonical sr) r)))

;; dependencies-jsexpr : (listof host-dependence) (listof forage-dependence)
;;                       (listof necessity) (string -> string) -> jsexpr
;; The typed-edge artifact: canonical_name -> its dependences, each with proof,
;; grounding, and flags — and, where the closure could claim it strictly, its
;; at_risk facts (st-6x9) with the proof tree and the learner-facing sentence.
;; Keys sort via write-json; the lists keep the cores' total order, so the file
;; is byte-stable.
(define (dependencies-jsexpr hosts forage necessities display-of)
  (define by-species (make-hash))
  (for ([h (in-list hosts)])
    (hash-update! by-species (host-dependence-species h)
                  (lambda (v) (hash-set v 'hosts (host-jsexpr h))) (hasheq)))
  (for ([f (in-list forage)])
    (hash-update! by-species (forage-dependence-species f)
                  (lambda (v) (hash-set v 'forage (forage-jsexpr f))) (hasheq)))
  (for ([n (in-list necessities)])
    (hash-update! by-species (necessity-species n)
                  (lambda (v) (hash-update v 'at_risk
                                           (lambda (l) (append l (list (necessity-jsexpr n display-of))))
                                           '()))
                  (hasheq)))
  (hasheq 'species
          (for/hasheq ([(k v) (in-hash by-species)])
            (values (string->symbol k) v))))

;; One strict at-risk fact as published. `via` nests each host's OWN necessity —
;; the forall materialized — so a reader (or the site) can unfold the chain to
;; the oligolecty it bottoms out at; the dispute flag rides every level it
;; holds at, never summarized away.
(define (necessity-jsexpr n display-of)
  (hasheq 'grain (symbol->string (necessity-grain n))
          'target (necessity-target n)
          'disputed (necessity-flagged? n)
          'explanation (necessity-sentence n (display-of (necessity-species n)))
          'via (if (necessity-via n)
                   (for/list ([v (in-list (necessity-via n))])
                     (hasheq 'host (car v)
                             'needs (necessity-jsexpr (cdr v) display-of)))
                   (json-null))))

(define (host-jsexpr h)
  (hasheq 'because
          (case (host-dependence-proof h)
            [(characterized)
             (hasheq 'kind "characterized"
                     'trait "nesting" 'value "cleptoparasitic"
                     'rank (symbol->string (host-dependence-source-rank h))
                     'taxon (host-dependence-source-name h))]
            [else (hasheq 'kind "recorded" 'source "bee_parasite_hosts")])
          'targets
          (for/list ([t (in-list (host-dependence-targets h))])
            (hasheq 'name (car t) 'in_atlas (cdr t)))))

(define (forage-jsexpr f)
  (hasheq 'source "fowler-droege"
          'beegap (case (forage-dependence-beegap f)
                    [(agrees) "agrees"] [(no-value) "no-value"] [else "disputed"])
          'plants (for/list ([p (in-list (forage-dependence-plants f))])
                    (hasheq 'family (or (car p) (json-null)) 'detail (cdr p)))))

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
                              facts-artifact output-artifact
                              parasite-artifact specialist-artifact
                              beegap-seed-artifact deps-output-artifact)
  (lambda (ctx)
    (with-handlers ([exn:fail? (lambda (e) (values #f (exn-message e)))])
      (define env (check-context-env ctx))
      (define (path-of a)
        (or (and env (env-resolve env a))
            (error 'taxon-reasoning "no path for artifact ~a" a)))
      (define parquet (path-of species-artifact))
      (define facts (path-of facts-artifact))
      (define out (path-of output-artifact))
      (define deps-out (path-of deps-output-artifact))

      (define rows (read-lineages* parquet))
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
         ;; Everything fallible runs BEFORE the write. Writing first and then
         ;; raising leaves the worst possible state: the node fails, so run-plan
         ;; skips observe-outputs! and no receipt is stored — the PREVIOUS receipt
         ;; survives, pointing at the OLD hash, while disk holds the NEW bytes.
         ;; The next build sees unchanged inputs and an existing output (presence
         ;; is all the cache checks, never content) and skips forever, with the
         ;; receipt permanently disagreeing with the file.
         (define j (reasoning-jsexpr derived index assertions glossary))
         (define-values (agree gaps bad uncovered)
           (beegap-agreement derived index (beegap-nesting (path-of traits-artifact))))
         ;; the typed edges (st-an7): a post-pass over the closure's own output —
         ;; NOT a second derivation (ADR 0008 D5 would demand a fresh argument);
         ;; the same node, consuming its own inheritance in-process.
         (define atlas (for/set ([r (in-list rows)]) (species-row-canonical r)))
         (define hosts
           (host-dependencies (read-host-edges (path-of parasite-artifact))
                              (nesting-index derived index) atlas))
         (define forage
           (forage-dependencies (read-forage-edges (path-of specialist-artifact))
                                (species-diet (path-of beegap-seed-artifact)) atlas))
         ;; the at-risk closure (st-6x9): strict necessity only — every any-of
         ;; node on the chain collapsed, every host grounded (see taxon-risk.rkt)
         (define risk-base (base-necessities forage))
         (define risk-derived (derived-necessities hosts risk-base))
         (define display-of
           (let ([m (for/hash ([r (in-list rows)])
                      (values (species-row-canonical r) (species-row-scientific r)))])
             (lambda (c) (hash-ref m c c))))
         (define dj (dependencies-jsexpr hosts forage
                                         (append risk-base risk-derived)
                                         display-of))
         (define note (string-append
                       (summary (hash-count (hash-ref j 'species)) (length assertions)
                                (length derived) agree gaps bad uncovered unresolved)
                       (deps-summary hosts forage)
                       (format "; at-risk: ~a strict fact(s) (~a base, ~a derived, ~a disputed)"
                               (+ (length risk-base) (length risk-derived))
                               (length risk-base) (length risk-derived)
                               (for/sum ([n (in-list (append risk-base risk-derived))])
                                 (if (necessity-flagged? n) 1 0)))))
         ;; both artifacts written only after everything fallible has run — the
         ;; receipt-vs-disk argument above covers the pair
         (make-directory* (path-only* out))
         (call-with-output-file out #:exists 'replace
           (lambda (o) (write-json j o) (newline o)))
         (make-directory* (path-only* deps-out))
         (call-with-output-file deps-out #:exists 'replace
           (lambda (o) (write-json dj o) (newline o)))
         (values #t note)]))))

;; the typed-edge half of the node's note: coverage, proof flavors, grounding,
;; and the flag tallies — the operator-facing record of what D2/D3/D4 decided
(define (deps-summary hosts forage)
  (define recorded (for/sum ([h (in-list hosts)])
                     (if (eq? 'recorded (host-dependence-proof h)) 1 0)))
  (define ungrounded
    (for/sum ([h (in-list hosts)])
      (if (for/or ([t (in-list (host-dependence-targets h))]) (cdr t)) 0 1)))
  (define (flag f) (for/sum ([d (in-list forage)])
                     (if (eq? f (forage-dependence-beegap d)) 1 0)))
  (format "; deps: ~a parasite(s) typed (~a source-proof-only, ~a with no in-atlas host), ~a specialist(s) typed (diet_breadth: ~a agree, ~a no value, ~a disputed)"
          (length hosts) recorded ungrounded
          (length forage) (flag 'agrees) (flag 'no-value) (flag 'disputed)))

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
