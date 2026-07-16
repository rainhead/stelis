#lang racket/base

;; Validation for the occurrences.db plan (st-d44.1.1). Asserts properties that
;; hold for ANY valid topological order, not a hard-coded sequence.

(require rackunit
         racket/set
         racket/list
         racket/format
         racket/runtime-path
         "model.rkt"
         "beeatlas.rkt"
         "plan-datalog.rkt"
         "exec.rkt"
         "cache.rkt")

(define-values (ordered pruned) (plan beeatlas-graph 'occurrences.db))
(define required (list->set ordered))

;; 1. The whole point: occurrences.db prunes the post-dbt tail (the 11 export/
;;    render/gate steps + place-marts, which serves those exports, not the db).
(check-equal? (list->set pruned)
              (set 'dedup-candidates 'dedup-gate 'topology-postprocess
                   'species-export 'species-maps 'places-export
                   'collectors-export 'collectors-events-export
                   'notes-harvest 'notes-assemble
                   'places-maps 'feeds 'place-marts)
              "occurrences.db prunes the post-dbt export/render/gate tail")

(check-equal? (length ordered) 22 "22 tasks upstream of occurrences.db (+ the integrity gate, st-0vz)")
(check-equal? (+ (length ordered) (set-count pruned)) 35 "35 tasks total (notes split into harvest + assemble, st-pd1)")

;; 2. Target producer, the dbt hinge, and gates-via-token are all present.
(for ([t (in-list '(generate-sqlite dbt-build taxa-download
                    resolution-gate checklist-resolution-gate inactive-gate
                    places-validation))])
  (check-true (set-member? required t) (~a t " is upstream of occurrences.db")))

;; 3. The emitted order is a VALID topological order: every task follows the
;;    producers of its inputs (restricted to the required set). This is the
;;    "respects run.py's edges" check, order-independent.
(define pos (for/hash ([n (in-list ordered)] [i (in-naturals)]) (values n i)))
(for ([consumer (in-list ordered)])
  (define t (hash-ref (graph-tasks beeatlas-graph) consumer))
  (for ([in (in-list (task-inputs t))])
    (define producer (producer-of beeatlas-graph in))
    (when (and producer (set-member? required producer))
      (check-true (< (hash-ref pos producer) (hash-ref pos consumer))
                  (~a producer " (produces " in ") must precede " consumer)))))

;; 4. The orderings the design specifically promises.
(check-true (< (hash-ref pos 'resolution-gate) (hash-ref pos 'dbt-build))
            "a gate precedes the task it guards")
(check-true (< (hash-ref pos 'dbt-build) (hash-ref pos 'generate-sqlite))
            "dbt-build precedes the target producer")

;; 5. Slice 1b cross-check: the Datalog reachability closure must compute the
;;    SAME required-task set as the plain-Racket recursion, for every target —
;;    including intermediates, siblings, and an external leaf (empty set).
(for ([target (in-list '(occurrences.db occurrences.parquet species.json
                         feeds collectors.json places.json geographies))])
  (check-equal? (datalog-required-tasks beeatlas-graph target)
                (required-tasks beeatlas-graph target)
                (~a "datalog closure = plain-racket recursion for " target)))

;; 6. Slice 2/st-d44.4 partial-success core: a failed producer blocks its
;;    dependents, an ok producer does not, and unrelated failures don't block.
(check-equal? (blockers-of beeatlas-graph 'generate-sqlite (hash 'dbt-build 'failed))
              '(dbt-build)
              "generate-sqlite is blocked when its producer dbt-build failed")
(check-equal? (blockers-of beeatlas-graph 'generate-sqlite (hash 'dbt-build 'ok))
              '()
              "generate-sqlite runs when dbt-build succeeded")
(check-equal? (blockers-of beeatlas-graph 'generate-sqlite (hash 'species-export 'failed))
              '()
              "an unrelated task's failure does not block generate-sqlite")

;; 7. Caching (st-d44.3): a task is cacheable only when ALL its inputs are
;;    content-addressable. generate-sqlite's inputs are files. dbt-build's
;;    db-relations become addressable once a resolve-relation is supplied
;;    (st-d5d), but its GATE-TOKEN inputs never are, so it stays unresolvable
;;    regardless — asserted here with no relation resolver (relations fall
;;    through to unresolvable too), which is enough to keep it uncacheable.
(define-runtime-path model-rkt "model.rkt") ; a file that exists, resolved by source location
(define an-existing-file (path->string model-rkt))
(define (stub-resolve a)
  (case a [(occurrences.parquet taxa.csv.gz) an-existing-file] [else #f]))
(check-true (snapshot? (input-snapshot beeatlas-graph 'generate-sqlite stub-resolve))
            "generate-sqlite is cacheable (all inputs are files)")
(let ([d (input-snapshot beeatlas-graph 'dbt-build stub-resolve)])
  (check-equal? (decision-reason d) 'inputs-unresolvable
                "dbt-build is not cacheable (gate-token inputs are never content-addressable)"))
(let ([d (input-snapshot beeatlas-graph 'taxa-download stub-resolve)])
  (check-equal? (decision-reason d) 'boundary
                "boundary tasks are never content-cached (ingestion re-runs)"))

;; 8. species.json — a second built+verified target beyond occurrences.db
;;    (st-4cm slice, st-h4m). It plans as its own cone, and species-export reads
;;    occurrences.parquet (a hard requirement that was missing from the edge until
;;    this target exercised it — regression guard for that fidelity fix).
(let-values ([(sp-ordered _sp-pruned) (plan beeatlas-graph 'species.json)])
  (check-not-false (memq 'species-export sp-ordered)
                   "species.json's plan runs species-export")
  (check-not-false (memq 'dbt-build sp-ordered)
                   "species.json depends on the dbt hinge")
  (check-false (memq 'generate-sqlite sp-ordered)
               "species.json does NOT pull in the occurrences.db producer"))
(check-not-false (memq 'occurrences.parquet
                       (task-inputs (hash-ref (graph-tasks beeatlas-graph) 'species-export)))
                 "species-export consumes occurrences.parquet (seasonality accumulation)")

;; 9. place-marts + collectors.json (st-4cm slice 2). collectors.json's cone runs
;;    dbt-build -> place-marts -> species-export -> collectors-export, in that
;;    order; collectors-export reads the EXPORT_DIR copies (@export), not the
;;    sandbox originals. place-marts' inputs must all resolve (else it can never
;;    cache — the geojson resolution gap that this slice fixed).
(let-values ([(co-ordered _co-pruned) (plan beeatlas-graph 'collectors.json)])
  (define pos (for/hash ([n (in-list co-ordered)] [i (in-naturals)]) (values n i)))
  (for ([t '(dbt-build place-marts species-export collectors-export)])
    (check-not-false (memq t co-ordered) (~a t " is in collectors.json's plan")))
  (check-true (< (hash-ref pos 'place-marts) (hash-ref pos 'collectors-export))
              "place-marts runs before collectors-export")
  (check-true (< (hash-ref pos 'dbt-build) (hash-ref pos 'place-marts))
              "dbt-build runs before place-marts"))
(check-equal? (task-inputs (hash-ref (graph-tasks beeatlas-graph) 'collectors-export))
              '(occurrences.parquet@export species.parquet@export)
              "collectors-export reads the EXPORT_DIR copies, not the sandbox originals")
(let ([stub (lambda (a) an-existing-file)]) ; everything resolves
  (check-true (snapshot? (input-snapshot beeatlas-graph 'place-marts stub))
              "place-marts is cacheable once all its mart inputs resolve"))

;; 10. places.json (st-4cm slice 3). places_export reads its parquets from
;;     EXPORT_DIR (@export copies), not the sandbox — the same Pitfall-5 shape as
;;     collectors-export. Its plan pulls place-marts (which produces the @export
;;     copies it reads) and runs after dbt-build; one invocation writes three
;;     outputs, so place_details.json must have places-export as its producer.
(let-values ([(pl-ordered _pl-pruned) (plan beeatlas-graph 'places.json)])
  (define pos (for/hash ([n (in-list pl-ordered)] [i (in-naturals)]) (values n i)))
  (for ([t '(dbt-build place-marts species-export places-export)])
    (check-not-false (memq t pl-ordered) (~a t " is in places.json's plan")))
  (check-true (< (hash-ref pos 'place-marts) (hash-ref pos 'places-export))
              "place-marts runs before places-export")
  (check-true (< (hash-ref pos 'species-export) (hash-ref pos 'places-export))
              "species-export (its @export species.parquet) runs before places-export")
  (check-false (memq 'generate-sqlite pl-ordered)
               "places.json does NOT pull in the occurrences.db producer"))
(check-equal? (task-inputs (hash-ref (graph-tasks beeatlas-graph) 'places-export))
              '(occurrence_places.parquet@export occurrences.parquet@export
                species.parquet@export geographies_places)
              "places-export reads the EXPORT_DIR copies, not the sandbox originals")
(check-equal? (task-outputs (hash-ref (graph-tasks beeatlas-graph) 'places-export))
              '(places.geojson places.json place_details.json)
              "one places_export invocation produces all three outputs")

;; 11. topology-postprocess + collectors-events-export terminals (st-4cm slice 4).
;;     Both were fictional edges until built+verified; beeatlas-hyq made them write
;;     DISTINCT outputs (no sibling-file mutation), so each is a single-file export
;;     with one producer. Pin the corrected edges and their cones.
;;
;;     topology reads the three region marts' @export copies (Pitfall 5, not the
;;     sandbox originals) and writes three .clean.geojson siblings; its cone is just
;;     dbt-build -> place-marts -> topology, and it pulls in NEITHER species-export
;;     nor the occurrences.db producer.
(check-equal? (task-inputs (hash-ref (graph-tasks beeatlas-graph) 'topology-postprocess))
              '(counties.geojson@export ecoregions.geojson@export wilderness.geojson@export)
              "topology reads the @export mart copies, not the sandbox originals")
(check-equal? (task-outputs (hash-ref (graph-tasks beeatlas-graph) 'topology-postprocess))
              '(counties.clean.geojson ecoregions.clean.geojson wilderness.clean.geojson)
              "topology writes a distinct .clean.geojson per layer (no in-place rewrite)")
(let-values ([(tp-ordered _p) (plan beeatlas-graph 'counties.clean.geojson)])
  (define pos (for/hash ([n (in-list tp-ordered)] [i (in-naturals)]) (values n i)))
  (for ([t '(dbt-build place-marts topology-postprocess)])
    (check-not-false (memq t tp-ordered) (~a t " is in counties.clean.geojson's plan")))
  (check-true (< (hash-ref pos 'place-marts) (hash-ref pos 'topology-postprocess))
              "place-marts (the @export copies) runs before topology")
  (check-false (memq 'species-export tp-ordered)
               "topology's cone does NOT pull in species-export")
  (check-false (memq 'generate-sqlite tp-ordered)
               "topology's cone does NOT pull in the occurrences.db producer"))

;;     collectors-events extends the base collectors.json's records into a DISTINCT
;;     collectors.events.json (+ its sidecar), reading occurrences.parquet@export and
;;     the species/higher-taxa JSON for slug resolution; its cone adds collectors-
;;     export and species-export on top of place-marts.
(check-equal? (task-inputs (hash-ref (graph-tasks beeatlas-graph) 'collectors-events-export))
              '(collectors.json occurrences.parquet@export species.json higher_taxa.json)
              "collectors-events reads base collectors.json + @export occ + slug JSON")
(check-equal? (task-outputs (hash-ref (graph-tasks beeatlas-graph) 'collectors-events-export))
              '(collectors.events.json collector_event_pages.json)
              "collectors-events writes a distinct enriched file, not collectors.json in place")
(let-values ([(ce-ordered _p) (plan beeatlas-graph 'collectors.events.json)])
  (define pos (for/hash ([n (in-list ce-ordered)] [i (in-naturals)]) (values n i)))
  (for ([t '(dbt-build place-marts species-export collectors-export collectors-events-export)])
    (check-not-false (memq t ce-ordered) (~a t " is in collectors.events.json's plan")))
  (check-true (< (hash-ref pos 'collectors-export) (hash-ref pos 'collectors-events-export))
              "collectors-export (the base collectors.json) runs before the events step")
  (check-false (memq 'generate-sqlite ce-ordered)
               "collectors.events.json does NOT pull in the occurrences.db producer"))

;; 12. Fail-loud guard (st-6qc). A 'file or 'dir output that resolves to #f drops
;;     silently out of env-output-paths (never verified, never hashed); the guard
;;     turns that into a hard error. A built+verified target's whole plan resolves;
;;     an unwired terminal (dedup_candidates.csv — no beeatlas-path entry yet)
;;     raises, naming it.
(define guard-env (make-build-env beeatlas-path (build-path "/tmp/guard-out")
                                  (build-path "/tmp/guard-cache")))
(let-values ([(pl-ordered _p) (plan beeatlas-graph 'places.json)])
  (check-not-exn
   (lambda () (check-output-paths-resolvable beeatlas-graph pl-ordered guard-env))
   "places.json's plan has no unresolvable file outputs"))
(let-values ([(dc-ordered _p) (plan beeatlas-graph 'dedup_candidates.csv)])
  (check-exn
   #rx"unresolvable file/dir output"
   (lambda () (check-output-paths-resolvable beeatlas-graph dc-ordered guard-env))
   "an unwired terminal (dedup_candidates.csv) is rejected loudly, not skipped"))
;; slice-4 terminals must have EVERY output resolvable, incl. the multi-output
;; siblings (topology's 3 .clean.geojson; collectors-events' enriched file AND its
;; collector_event_pages.json sidecar — the latter was missing from the resolver
;; until --verify's st-6qc guard surfaced it, st-dtq). The 'dir terminals (st-cly)
;; now resolve too: species-maps/place-maps/feeds each land as a directory.
(for ([tgt '(counties.clean.geojson collectors.events.json
             species-maps place-maps feeds)])
  (let-values ([(ordered _p) (plan beeatlas-graph tgt)])
    (check-not-exn
     (lambda () (check-output-paths-resolvable beeatlas-graph ordered guard-env))
     (~a tgt "'s plan has no unresolvable file/dir outputs"))))

;; 13. ADR 0004 build clock (st-3mi): the SOURCE_DATE_EPOCH the executor injects
;;     into every task must be a deterministic function of the source snapshot —
;;     numeric and STABLE across calls, or --verify's build-twice compare is moot.
;;     (Injection into the subprocess env is exercised by the exec path; here we
;;     pin the value's shape and stability.)
(let ([e1 (beeatlas-source-date-epoch)]
      [e2 (beeatlas-source-date-epoch)])
  (check-true (regexp-match? #px"^[0-9]+$" e1) "build clock is a numeric epoch")
  (check-equal? e1 e2 "build clock is stable across calls (deterministic)"))

;; 14. notes.json provenance reconciliation (st-msn). notes-harvest emits a DERIVED
;;     notes.json (reproducible from the store, so cutoff-eligible), and reads the
;;     AUTHORITATIVE notes store — a producerless 'file leaf whose forward-only-ness
;;     is structural (the graph has no way to rebuild it). The store is a declared
;;     input, fixing the previously under-declared edge.
(let ([notes  (hash-ref (graph-artifacts beeatlas-graph) 'notes.json)]
      [store  (hash-ref (graph-artifacts beeatlas-graph) 'notes-store.db)]
      [harvest (hash-ref (graph-tasks beeatlas-graph) 'notes-harvest)])
  (check-eq? (artifact-provenance notes) 'derived
             "notes.json is derived (was mislabeled authoritative)")
  (check-eq? (artifact-provenance store) 'authoritative
             "the authoritative label moved to the input store")
  (check-eq? (artifact-kind store) 'file "the store is a file input")
  (check-false (producer-of beeatlas-graph 'notes-store.db)
               "the store has no producer — forward-only by construction")
  (check-true (and (memq 'notes-store.db (task-inputs harvest)) #t)
              "notes-harvest declares the store as an input (edge no longer under-declared)"))
