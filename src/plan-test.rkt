#lang racket/base

;; Validation for the occurrences.db plan (st-d44.1.1). Asserts properties that
;; hold for ANY valid topological order, not a hard-coded sequence.

(require rackunit
         racket/set
         racket/list
         racket/format
         "model.rkt"
         "beeatlas.rkt"
         "plan-datalog.rkt"
         "exec.rkt")

(define-values (ordered pruned) (plan beeatlas-graph 'occurrences.db))
(define required (list->set ordered))

;; 1. The whole point: occurrences.db prunes exactly the 11 post-dbt steps.
(check-equal? (list->set pruned)
              (set 'dedup-candidates 'dedup-gate 'topology-postprocess
                   'species-export 'species-maps 'places-export
                   'collectors-export 'collectors-events-export 'notes-harvest
                   'places-maps 'feeds)
              "occurrences.db prunes the post-dbt export/render/gate tail")

(check-equal? (length ordered) 21 "21 tasks upstream of occurrences.db")
(check-equal? (+ (length ordered) (set-count pruned)) 32 "32 tasks total")

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
                         feeds collectors.json geographies))])
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
