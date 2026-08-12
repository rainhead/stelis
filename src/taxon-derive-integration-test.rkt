#lang racket/base

;; Integration validation for taxon reasoning (st-ozp): the pure core in
;; taxon-inherit.rkt is tested on fixtures; this is the environment-coupled half —
;; the DuckDB reads, the checked-in fact file, and the claim ADR 0008 actually
;; made, checked against the REAL beeatlas taxonomy.
;;
;; The claim under test is not "the closure runs". It is the value prop: a handful
;; of high-rank assertions characterize species that no per-species source covers,
;; and where a per-species source DOES cover them, it agrees. Both halves are
;; measured here, against Bee-Gap's independently-sourced species_traits.nesting.
;;
;; GATED, like fan-out-key-integration-test: absent a beeatlas checkout with built
;; marts, or DuckDB, it prints a skip note and passes, keeping the suite green in
;; CI (which has neither).

(require rackunit
         racket/system
         racket/list
         racket/set
         racket/string
         "beeatlas.rkt"
         "taxon-inherit.rkt"
         "taxon-derive.rkt")

;; All three inputs come from the graph's own resolver, not a second copy of the
;; path facts — if placement moves in beeatlas.rkt, this test moves with it.
;; (#f export-dir: all three sit at fixed paths, none is EXPORT_DIR-relative.)
(define species-parquet (beeatlas-path 'species.parquet #f))
(define traits-parquet (beeatlas-path 'species_traits.parquet #f))
(define facts (beeatlas-path 'taxon-traits.rktd #f))

(define (usable?)
  (and (find-executable-path "duckdb")
       (file-exists? species-parquet)
       (file-exists? traits-parquet)
       (file-exists? facts)))

(cond
  [(not (usable?))
   (printf "taxon-derive-integration-test: SKIPPED — needs a beeatlas checkout with built marts + duckdb\n")]
  [else
   (define rows (read-lineages species-parquet))
   (define taxa (lineages->taxonomy rows))
   (define index (species-index rows))
   (define-values (glossary assertions) (read-fact-file facts))
   (define derived (inherited-traits (taxonomy->theory taxa assertions)))

   ;; --- the taxonomy read is sane ------------------------------------------------
   (check-true (> (length rows) 100) "the species mart yields lineages")
   (check-true (> (length taxa) (length rows))
               "folding lineages yields MORE nodes than species — the higher ranks")
   (check-equal? (unresolved-assertions taxa assertions) '()
                 "every checked-in assertion names a taxon that exists on this checklist")

   ;; The failure this guards against is specific and was hit live: the DuckDB CLI
   ;; renders SQL NULL as the text "NULL", so a subgenus-less species would arrive
   ;; as a taxon literally named NULL and every such species — across unrelated
   ;; genera — would be merged under one bogus subgenus.
   (check-false (for/or ([t (in-list taxa)]) (equal? (taxon-name t) "NULL"))
                "no taxon is named \"NULL\" — SQL absence survived the CLI's text output")

   ;; --- the reasoning reaches real species ---------------------------------------
   (define species-facts
     (for/list ([d (in-list derived)] #:when (hash-ref index (inherited-subject d) #f)) d))
   (check-true (> (length species-facts) 40)
               "a couple of high-rank assertions characterize dozens of species")
   (check-equal? (trait-conflicts derived) '()
                 "no lineage inherits two values — most-specific-wins stays deferred (ADR 0008)")

   ;; both assertion ranks actually reach species: a subfamily 3–4 ranks up AND a
   ;; subgenus 1 rank up. If only one did, the depth claim would be untested.
   (define source-ranks
     (for/set ([d (in-list species-facts)]) (inherited-source-rank d)))
   (check-true (and (set-member? source-ranks 'subfamily)
                    (set-member? source-ranks 'subgenus))
               "traits descend from BOTH a high rank and a low one — depth is not fixed")

   ;; --- the value prop, measured -------------------------------------------------
   (define-values (agree gaps disagreements uncovered)
     (beegap-agreement derived index (beegap-nesting traits-parquet)))
   (check-true (> gaps 0)
               "inheritance FILLS species Bee-Gap has no nesting value for — the coverage win")
   ;; A READ-integrity guard, not an agreement guard: agreement-where-covered is
   ;; pinned EXACTLY by disagreements = '() below, and a beegap-nesting read that
   ;; broke (renamed column, format change) would pass both neighbours vacuously —
   ;; every species lands in `gaps`, which stays > 0, with nothing left to disagree.
   ;; So bound the SHAPE: Bee-Gap covers the clear majority of the characterized
   ;; set, and a collapsed read shows as gaps swallowing it. Majority, not a tight
   ;; ratio, on purpose: the first cut demanded agree > 5×gaps, and ordinary
   ;; upstream drift broke it (st-36e — Bee-Gap gained values for 6 species,
   ;; 2026-08; production sat at 6.7× while a week-stale local mart sat at 4.5×,
   ;; so the suite failed on exactly the checkouts that had done nothing wrong).
   (check-true (> agree gaps)
               "Bee-Gap covers most characterized species — a collapsed traits read \
would show as gaps swallowing the set")
   (check-equal? disagreements '()
                 "no species where the inherited trait contradicts Bee-Gap's own")
   ;; The reverse direction. Not pinned to an exact list — that would break on any
   ;; checklist change — but held small: a large number means a whole cuckoo
   ;; lineage has gone unasserted, which is exactly what this is here to notice.
   (check-true (< (length uncovered) 5)
               "few Bee-Gap parasitic species escape every assertion")
   (printf "taxon-derive-integration-test: ~a species characterized · Bee-Gap ~a agree, ~a gap(s) filled · ~a uncovered ~s\n"
           (length species-facts) agree gaps (length uncovered) uncovered)

   ;; --- an empty read must never publish quietly -------------------------------
   ;; Zero rows is not a legitimate state: it means the read matched nothing (a
   ;; renamed column, a CLI output-format change that fails the arity guard). The
   ;; artifact would be written with an empty species map, the node would report
   ;; success, and the absence-tolerant site loader would silently drop the
   ;; reasoning from every page on a green build.
   (let ([empty-parquet (build-path (find-system-path 'temp-dir) "stelis-empty-species.parquet")])
     (void (system (format "duckdb -c \"COPY (SELECT * FROM read_parquet('~a') WHERE false) TO '~a' (FORMAT PARQUET)\" >/dev/null 2>&1"
                           species-parquet empty-parquet)))
     (when (file-exists? empty-parquet)
       (check-equal? (read-lineages empty-parquet) '()
                     "the plain reader returns empty — it does not raise")
       (check-exn #rx"yielded no species rows"
                  (lambda () (read-lineages* empty-parquet))
                  "…but the guarded reader the node uses REFUSES to proceed")
       (delete-file empty-parquet)))

   ;; --- the published sentence ------------------------------------------------------
   (define j (reasoning-jsexpr derived index assertions glossary))
   (define species-map (hash-ref j 'species))
   (check-equal? (hash-count species-map) (length species-facts)
                 "one entry per characterized species (each carries one trait here)")
   (check-true (hash-has-key? (hash-ref j 'glossary) 'cleptoparasitic)
               "the value's DEFINITION ships once, at top level — not repeated per species")
   (define sample (hash-ref species-map (string->symbol (species-row-canonical
                                               (hash-ref index (inherited-subject
                                                                (first species-facts)))))))
   (define entry (first sample))
   (check-true (string-contains? (hash-ref entry 'explanation) "inherited from the")
               "the published explanation names the proof, not just the value")
   (check-true (hash-has-key? entry 'hosts)
               "…and every cuckoo lineage here says WHAT it parasitizes — the part that differs")
   ;; The redundancy this replaced: the definition of the term must NOT be inlined
   ;; into each species' sentence, or a reader visiting two cuckoo pages reads it twice.
   (check-false (string-contains? (hash-ref entry 'explanation) "builds no nest")
                "the glossary definition is not restated in the per-species explanation")])
