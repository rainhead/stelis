#lang racket/base

;; Taxon trait inheritance (st-ozp) — the pure reasoning core of the Horizon 2
;; substrate beachhead (ADR 0008).
;;
;; One sparse assertion at a high rank — "all Nomadinae are cleptoparasitic" —
;; INHERITS down the taxonomic rank tree to every descendant species. That is
;; unbounded-depth transitive closure carrying a proof of WHERE the trait came
;; from: the two properties ADR 0008's gate asked for, and the two a recursive
;; CTE gives grudgingly. This is the fifth application of the Datalog layer and
;; the first that reasons about the DOMAIN rather than about the build.
;;
;; PURE: taxa (key/rank/name/parent) + assertions in, derived traits out. No IO,
;; no build node, no beeatlas — the adapter supplies the taxonomy (beeatlas.rkt
;; reads it off the species mart), exec.rkt runs the whole thing as a node.
;;
;; Following provenance-datalog.rkt's split: the THEORY answers STRUCTURE (which
;; ancestor carries the trait, at which rank); PROSE — the curator's note behind
;; an assertion — stays beside it in a plain hash and is composed in only at
;; rendering. Same division of labour, learner-facing audience.

(require datalog
         racket/dict
         racket/list
         racket/set
         racket/string
         racket/format)

(provide RANKS
         (struct-out taxon)
         (struct-out assertion)
         (struct-out inherited)
         make-taxon-key
         lineage->taxa
         merge-taxa
         taxonomy->theory
         unresolved-assertions
         inherited-traits
         trait-conflicts
         assertion-index
         explanation-string
         parse-fact-file
         read-fact-file)

;; The rank tree's spine, coarsest first. A lineage is a path down this list;
;; ranks a given organism lacks are simply absent (see lineage->taxa).
(define RANKS '(family subfamily tribe genus subgenus species))

;; A node of the rank tree.
;;   key    : symbol — its identity, `rank:name' (see make-taxon-key)
;;   rank   : symbol — one of RANKS
;;   name   : string — the taxon name as published ("Nomadinae")
;;   parent : (or/c symbol #f) — the key of its nearest present ancestor
(struct taxon (key rank name parent) #:transparent)

;; A curator's assertion, as authored in the fact file: trait T holds with value
;; V for everything at or below (rank, name).
;;   hosts : (or/c string #f) — for a parasite, the noun phrase naming what this
;;           lineage attacks. This is the part that DIFFERS between lineages and
;;           is therefore the part worth publishing per taxon.
;;   note  : (or/c string #f) — reserved for something genuinely particular to
;;           this lineage. Optional, and meant to stay empty: what the trait
;;           MEANS belongs in the glossary, said once, not restated in every
;;           clause. (The first draft of this file did restate it, and a reader
;;           visiting two cuckoo pages met the same paragraph twice.)
(struct assertion (rank name trait value hosts note) #:transparent)

;; One derived trait, with its proof: subject S has trait T = V BECAUSE `source'
;; (a taxon at `source-rank' named `source-name') asserts it. source = subject
;; when the assertion was made directly at that taxon.
(struct inherited (subject trait value source source-rank source-name) #:transparent)

;; make-taxon-key : symbol string -> symbol
;; A taxon's identity. Rank-qualified because a name alone is ambiguous across
;; ranks (Triepeolus is both a genus and one of its subgenera). Within a rank a
;; name is assumed unique — merge-taxa CHECKS that rather than trusting it.
(define (make-taxon-key rank name) (string->symbol (format "~a:~a" rank name)))

;; --- Building the tree ---------------------------------------------------------

;; lineage->taxa : (listof (cons symbol (or/c string #f))) -> (listof taxon)
;; One organism's lineage — (rank . name) pairs, coarsest first — as linked taxon
;; nodes. A rank the organism LACKS (name #f or "") is skipped, and the next
;; present rank links to the nearest present ancestor: sparsity is the norm here
;; (4 of the 5 Nomadinae genera on the beeatlas checklist have species with no
;; subgenus), and a gap must not break the chain to the root, or the trait would
;; stop descending exactly where the data thins out.
(define (lineage->taxa pairs)
  (let loop ([ps pairs] [parent #f] [acc '()])
    (cond
      [(null? ps) (reverse acc)]
      [else
       (define rank (caar ps))
       (define name (cdar ps))
       (cond
         [(or (not name) (equal? name "")) (loop (cdr ps) parent acc)]
         [else
          (define k (make-taxon-key rank name))
          (loop (cdr ps) k (cons (taxon k rank name parent) acc))])])))

;; merge-taxa : (listof taxon) -> (listof taxon)
;; Every lineage's nodes into one deduplicated tree, sorted by key.
;;
;; A key reached with two different parents is one of two very different things,
;; and conflating them was a real defect:
;;
;;   A RANK GAP — the parents lie on ONE lineage. Melecta reached from complete
;;   rows has parent tribe:Melectini; from a row whose `tribe' cell is blank it
;;   has parent subfamily:Apinae. Nothing is ambiguous: the second row simply
;;   carried less information, and Apinae is an ancestor of Melectini. This is
;;   ordinary sparsity — what lineage->taxa's rank-skipping is FOR — so it
;;   resolves to the most specific parent. Treating it as an error meant one
;;   blank cell anywhere in the mart failed the node and staled the artifact for
;;   every species.
;;
;;   A HOMONYM — the parents lie on DIFFERENT lineages, e.g. subgenus
;;   "Triepeolus" under both genus:Triepeolus and genus:Epeolus. Here rank+name
;;   genuinely is not a unique identity, and picking one would graft a whole
;;   subtree onto the wrong lineage so every trait asserted above it inherits to
;;   the wrong species. Still an ERROR. Loud beats subtle.
;;
;; The test that separates them: is every other candidate parent an ancestor of
;; the most specific one? Keys are resolved coarsest-rank first, so a node's
;; candidate parents are always settled before the node itself is judged.
(define (merge-taxa taxa)
  (define candidates (make-hash))
  (for ([t (in-list taxa)])
    (hash-update! candidates (taxon-key t) (lambda (v) (cons t v)) '()))
  (define (rank-index r) (or (index-of RANKS r) -1))
  (define settled (make-hash))
  (define keys
    (sort (hash-keys candidates) <
          #:key (lambda (k) (rank-index (taxon-rank (car (hash-ref candidates k)))))))
  (for ([k (in-list keys)])
    (define ts (hash-ref candidates k))
    (define parents (remove-duplicates (map taxon-parent ts)))
    (hash-set! settled k
               (if (null? (cdr parents))
                   (car ts)
                   (resolve-parent k ts parents settled rank-index))))
  (sort (hash-values settled) symbol<? #:key taxon-key))

;; The most specific candidate, once every other candidate is confirmed to sit on
;; its ancestor chain. A #f parent (a lineage with no higher rank present at all)
;; is vacuously on every chain — it asserts nothing about ancestry.
(define (resolve-parent k ts parents settled rank-index)
  (define best
    (argmax (lambda (t) (let ([p (taxon-parent t)])
                          (if p (rank-index (taxon-rank-of p settled)) -1)))
            ts))
  (define chain (parent-chain (taxon-parent best) settled))
  (for ([p (in-list parents)])
    (unless (or (not p) (equal? p (taxon-parent best)) (member p chain))
      (error 'merge-taxa
             "homonym: ~a appears under both ~a and ~a, which are on different lineages — rank+name is not a unique identity here"
             k (or (taxon-parent best) '<root>) p)))
  best)

;; a settled node's rank, for comparing how specific two candidate parents are
(define (taxon-rank-of k settled)
  (define t (hash-ref settled k #f))
  (if t (taxon-rank t) 'family))

;; k and everything above it, using the already-settled parents
(define (parent-chain k settled)
  (let loop ([k k] [acc '()])
    (cond
      [(not k) (reverse acc)]
      [else
       (define t (hash-ref settled k #f))
       (loop (and t (taxon-parent t)) (cons k acc))])))

;; --- The theory ------------------------------------------------------------------
;;
;;   taxon(K)              K is a node of the rank tree
;;   rank-of(K, R)         …at rank R
;;   name-of(K, N)         …published as N
;;   parent(K, P)          K's nearest present ancestor
;;   asserts(K, T, V)      a curator asserted trait T = V at K
;;
;;   covers(S, X) :- parent(X, S).                    ; S characterizes X…
;;   covers(S, X) :- covers(S, M), parent(X, M).      ; …at unbounded depth
;;   has-trait(X, T, V, S, R) :- asserts(S, T, V), rank-of(S, R), covers(S, X).
;;   has-trait(S, T, V, S, R) :- asserts(S, T, V), rank-of(S, R).  ; …and at S itself
;;
;; DIRECTION IS A PERFORMANCE DECISION here, not just taste. The obvious phrasing
;; is upward — ancestor(X,Y) closed over parent, then "X has the trait if some
;; ancestor asserts it". Measured on the real beeatlas taxonomy (830 taxa, 2
;; assertions) that costs 8.7s, because with X free the tabled engine explores
;; every taxon's ancestry. Phrased DOWNWARD, with S bound by `asserts' before the
;; recursive literal, it explores only the subtree beneath each asserting node:
;; 221ms, a 40× cut. It is also the truer reading of what an assertion DOES — it
;; characterizes its subtree — so the fast form is the honest one. (Binding the
;; source first in the upward form recovers only 1.8s; left-recursion, 5.0s.)
;;
;; The derived fact carries its SOURCE and the source's RANK. The source is the
;; proof — it is what "because" prints. The rank rides along so a most-specific-
;; wins priority rule can layer on later without re-deriving anything (ADR 0008's
;; defeasible override, deferred until a real lineage actually conflicts —
;; trait-conflicts below is what will notice that day).

;; taxonomy->theory : (listof taxon) (listof assertion) -> theory
;; Assertions naming a taxon absent from this taxonomy are simply not asserted;
;; they are NOT an error here (a checklist covers one region, an assertion file
;; may reasonably name a taxon that has no local species). unresolved-assertions
;; reports them so they can never vanish silently.
(define (taxonomy->theory taxa assertions)
  (define thy (make-theory))
  (define known (for/set ([t (in-list taxa)]) (taxon-key t)))
  (for ([t (in-list taxa)])
    (define k (taxon-key t))
    (assert-taxon! thy k)
    (assert-rank-of! thy k (taxon-rank t))
    (assert-name-of! thy k (taxon-name t))
    (when (taxon-parent t) (assert-parent! thy k (taxon-parent t))))
  (for ([a (in-list assertions)])
    (define k (assertion-key a))
    (when (set-member? known k)
      (assert-asserts! thy k (assertion-trait a) (assertion-value a))))
  (datalog thy
           (! (:- (covers S X) (parent X S)))
           (! (:- (covers S X) (covers S M) (parent X M)))
           (! (:- (has-trait X T V S R)
                  (asserts S T V) (rank-of S R) (covers S X)))
           (! (:- (has-trait S T V S R)
                  (asserts S T V) (rank-of S R))))
  thy)

;; unresolved-assertions : (listof taxon) (listof assertion) -> (listof assertion)
;; Authored assertions naming no taxon in this taxonomy — a typo, a rank spelled
;; differently, or a taxon with no species in this region. Reported, never fatal.
(define (unresolved-assertions taxa assertions)
  (define known (for/set ([t (in-list taxa)]) (taxon-key t)))
  (for/list ([a (in-list assertions)] #:unless (set-member? known (assertion-key a)))
    a))

(define (assertion-key a) (make-taxon-key (assertion-rank a) (assertion-name a)))

;; --- Queries ---------------------------------------------------------------------

;; inherited-traits : theory -> (listof inherited)
;; Every derived trait in the taxonomy, sorted (subject, trait, source) so the
;; emitted artifact is byte-stable. ONE query answers it: the closure has already
;; done the work, and the source name is looked up per DISTINCT source (a handful
;; of assertions, not one lookup per species).
(define (inherited-traits thy)
  (define rows
    (for/list ([s (in-list (datalog thy (? (has-trait X T V S R))))])
      (inherited (dict-ref s 'X) (dict-ref s 'T) (dict-ref s 'V)
                 (dict-ref s 'S) (dict-ref s 'R)
                 #f)))                      ; source-name filled in below
  (define names
    (for/hash ([src (in-set (for/set ([r (in-list rows)]) (inherited-source r)))])
      (values src (taxon-name-of thy src))))
  (sort (for/list ([r (in-list rows)])
          (struct-copy inherited r
                       [source-name (hash-ref names (inherited-source r))]))
        inherited<?))

;; taxon-name-of : theory symbol -> (or/c string #f)
(define (taxon-name-of thy k)
  (define subst (datalog thy (? (name-of #,k N))))
  (and (pair? subst) (dict-ref (car subst) 'N)))

;; Lexicographic on (subject, trait, source) — a TOTAL order, so the emitted
;; artifact is byte-stable whatever order the engine yields tuples in. It must
;; stop at the FIRST differing component; scanning past it (a `for/or' over the
;; component pairs) silently sorts by a later component instead, which orders
;; correctly only for inputs that were already nearly sorted.
(define (inherited<? a b)
  (define (key r) (list (~a (inherited-subject r)) (~a (inherited-trait r))
                        (~a (inherited-source r))))
  (let loop ([xs (key a)] [ys (key b)])
    (cond
      [(null? xs) #f]
      [(string=? (car xs) (car ys)) (loop (cdr xs) (cdr ys))]
      [else (string<? (car xs) (car ys))])))

;; trait-conflicts : (listof inherited) -> (listof (list subject trait (listof inherited)))
;; Subjects reached by the SAME trait with DIFFERENT values — the day defeasible
;; override stops being deferrable (ADR 0008 / st-ozp: decide it from a real
;; lineage, not in the abstract). Empty until that day; the caller decides what a
;; conflict means (the beeatlas node fails on one, loudly).
(define (trait-conflicts rows)
  (define groups (make-hash))
  (for ([r (in-list rows)])
    (define k (cons (inherited-subject r) (inherited-trait r)))
    (hash-update! groups k (lambda (v) (cons r v)) '()))
  (sort
   (for/list ([(k rs) (in-hash groups)]
              #:when (> (set-count (for/set ([r (in-list rs)]) (inherited-value r))) 1))
     (list (car k) (cdr k) (sort rs inherited<?)))
   string<? #:key (lambda (g) (~a (first g) " " (second g)))))

;; --- Prose -----------------------------------------------------------------------

;; assertion-index : (listof assertion) -> hash
;; (source-key trait) -> the assertion behind it. The prose half of the split: the
;; theory knows WHICH ancestor carries the trait; this knows what to say about it.
(define (assertion-index assertions)
  (for/hash ([a (in-list assertions)])
    (values (list (assertion-key a) (assertion-trait a)) a)))

;; explanation-string : inherited string hash -> string
;; The learner-facing sentence — the published output ADR 0008 says earns the
;; substrate. `subject-name' is what to call the subject (a species' canonical
;; name; the taxonomy stores names per taxon but the subject may be a species
;; the caller names better). A trait asserted at the subject itself gets no
;; "inherited from" clause — it wasn't inherited.
;;
;; "Itself" is judged by NAME, not by key. A checklist carries genus-level records
;; as species-rank rows, so `species:stelis' and `genus:Stelis' are distinct nodes
;; that denote the same animal, and comparing keys yields the nonsense "Stelis is
;; cleptoparasitic, inherited from the genus Stelis." Two nodes published under
;; one name are one taxon as far as a reader is concerned.
;;
;; What the VALUE means is NOT composed in here — that is the glossary's job, said
;; once per page rather than once per species. This sentence carries only what is
;; specific: the proof, who the lineage attacks, and any particular note.
(define (explanation-string inh subject-name index)
  (define a (hash-ref index (list (inherited-source inh) (inherited-trait inh)) #f))
  (define self?
    (or (eq? (inherited-subject inh) (inherited-source inh))
        (equal? subject-name (inherited-source-name inh))))
  (define lead
    (if self?
        (format "~a is ~a." subject-name (inherited-value inh))
        (format "~a is ~a, inherited from the ~a ~a."
                subject-name (inherited-value inh)
                (inherited-source-rank inh) (inherited-source-name inh))))
  (define hosts (and a (assertion-hosts a)))
  (define note (and a (assertion-note a)))
  (apply string-append
         lead
         (append (if hosts (list (format " It parasitizes ~a." hosts)) '())
                 (if note (list " " note) '()))))

;; --- The fact file ---------------------------------------------------------------
;;
;; Checked into stelis, an INPUT ARTIFACT of the derivation node (st-ozp design:
;; curated config, not a forward-only authored store — there is no authoring UI
;; and editing the file is the whole workflow). Its shape:
;;
;;   (traits
;;     (subfamily "Nomadinae"
;;       (nesting cleptoparasitic "Nomadine bees are cuckoos: …"))
;;     (subgenus "Psithyrus"
;;       (nesting cleptoparasitic "…")))
;;
;; One clause per taxon, one (trait value note) per trait asserted there.

;; parse-fact-file : any -> (values hash (listof assertion))
;; The pure parser, so the shape is testable without a file. Returns the glossary
;; (trait VALUE -> its definition) and the assertions. Raises on anything
;; malformed, naming the offending clause — a fact file is hand-edited, and a
;; silently-dropped assertion is a trait that quietly stops being published.
(define (parse-fact-file datum)
  (unless (and (list? datum) (pair? datum) (eq? 'taxon-traits (car datum)))
    (error 'parse-fact-file "expected a (taxon-traits …) form, got: ~e" datum))
  (define glossary (make-hash))
  (define assertions '())
  (for ([section (in-list (cdr datum))])
    (unless (and (list? section) (pair? section))
      (error 'parse-fact-file "expected a (glossary …) or (traits …) section, got: ~e" section))
    (case (car section)
      [(glossary)
       (for ([entry (in-list (cdr section))])
         (unless (and (list? entry) (= 2 (length entry))
                      (symbol? (first entry)) (string? (second entry)))
           (error 'parse-fact-file "expected (value \"definition\"), got: ~e" entry))
         (hash-set! glossary (first entry) (second entry)))]
      [(traits)
       (set! assertions (append assertions (append* (map parse-clause (cdr section)))))]
      [else (error 'parse-fact-file "unknown section ~a (expected glossary or traits)"
                   (car section))]))
  ;; Every asserted value must be defined. The glossary is what carries the
  ;; MEANING now that the per-clause notes no longer restate it, so an undefined
  ;; value would publish a bare word — worse than the redundancy it replaced.
  (for ([a (in-list assertions)])
    (unless (hash-has-key? glossary (assertion-value a))
      (error 'parse-fact-file
             "no glossary entry for value ~a (asserted at ~a ~s) — the glossary carries what the term MEANS"
             (assertion-value a) (assertion-rank a) (assertion-name a))))
  (values (hash-copy/immutable glossary) assertions))

(define (hash-copy/immutable h)
  (for/hash ([(k v) (in-hash h)]) (values k v)))

;; One (rank "Name" (trait value field …) …) clause. Fields are named so the
;; optional ones can be omitted without positional placeholders:
;;   (hosts "…")  what this lineage attacks — the part that differs per lineage
;;   (note  "…")  something particular to this lineage; usually absent
(define (parse-clause clause)
  (unless (and (list? clause) (>= (length clause) 2)
               (symbol? (first clause)) (string? (second clause)))
    (error 'parse-fact-file
           "expected (rank \"Name\" (trait value field …) …), got: ~e" clause))
  (define rank (first clause))
  (define name (second clause))
  (unless (memq rank RANKS)
    (error 'parse-fact-file "unknown rank ~a in ~e (known: ~a)" rank clause
           (string-join (map ~a RANKS) ", ")))
  (for/list ([tv (in-list (cddr clause))])
    (unless (and (list? tv) (>= (length tv) 2)
                 (symbol? (first tv)) (symbol? (second tv)))
      (error 'parse-fact-file
             "expected (trait value field …) under ~a ~s, got: ~e" rank name tv))
    (define fields
      (for/hash ([f (in-list (cddr tv))])
        (unless (and (list? f) (= 2 (length f))
                     (memq (first f) '(hosts note)) (string? (second f)))
          (error 'parse-fact-file
                 "expected (hosts \"…\") or (note \"…\") under ~a ~s, got: ~e" rank name f))
        (values (first f) (second f))))
    (assertion rank name (first tv) (second tv)
               (hash-ref fields 'hosts #f) (hash-ref fields 'note #f))))

;; read-fact-file : path-string -> (values hash (listof assertion))
(define (read-fact-file path)
  (parse-fact-file (call-with-input-file path read)))

;; --- Fact assertion helpers (runtime values spliced as constants) ----------------
;; `!' is syntax: the predicate is a literal, only TERMS splice. One helper per
;; predicate, exactly as provenance-datalog.rkt does it.

(define (assert-taxon! thy k)      (datalog thy (! (taxon #,k)))          (void))
(define (assert-rank-of! thy k r)  (datalog thy (! (rank-of #,k #,r)))    (void))
(define (assert-name-of! thy k n)  (datalog thy (! (name-of #,k #,n)))    (void))
(define (assert-parent! thy k p)   (datalog thy (! (parent #,k #,p)))     (void))
(define (assert-asserts! thy k t v)
  (datalog thy (! (asserts #,k #,t #,v))) (void))
