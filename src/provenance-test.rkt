#lang racket/base

;; Cross-check the Datalog provenance rules (provenance-datalog.rkt, st-yg7.3)
;; against the plain-Racket explanation walk, in the slice-1a/1b tradition:
;; same question, two engines, answers must agree.
;;
;; The invariant: datalog `stale' == the walk's would-run frontier. A task is
;; stale iff its own verdict is 'run OR it sits below a stale upstream — which
;; is exactly membership in walk-explanations' frontier (glyph ▶ or ≈).

(require rackunit
         racket/set
         racket/runtime-path
         "model.rkt"
         "cache.rkt"
         "explain.rkt"
         "provenance-datalog.rkt"
         "beeatlas.rkt")

;; frontier of an explanation list: tasks that run or are conditional
(define (frontier exps)
  (for/set ([e (in-list exps)]
            #:unless (and (eq? 'skip (decision-verdict (explanation-decision e)))
                          (null? (explanation-upstreams e))))
    (explanation-task e)))

(define (cross-check g exps msg)
  (define thy (explanations->theory g exps))
  (check-equal? (datalog-stale-tasks thy) (frontier exps) msg)
  ;; and per task, the one-hop blames match the walk's upstream attribution
  (for ([e (in-list exps)])
    (check-equal? (datalog-direct-blames thy (explanation-task e))
                  (list->set (explanation-upstreams e))
                  (format "~a: one-hop blames (~a)" msg (explanation-task e))))
  thy)

;; --- The synthetic diamond ----------------------------------------------------

(define g
  (build-graph
   (list (make-task 'ingest 'boundary  #:outputs '(raw))
         (make-task 'left   'transform #:inputs '(raw) #:outputs '(l))
         (make-task 'right  'transform #:inputs '(raw) #:outputs '(r))
         (make-task 'join   'transform #:inputs '(l r) #:outputs '(out)))
   (list (make-artifact 'raw 'file) (make-artifact 'l 'file)
         (make-artifact 'r 'file)   (make-artifact 'out 'file))))
(define ordered '(ingest left right join))
(define (stub decisions) (lambda (name) (hash-ref decisions name)))

;; boundary at the top: everything below is stale through it, transitively
(let* ([exps (walk-explanations
              g ordered
              (stub (hash 'ingest (decision 'run 'boundary '())
                          'left   (decision 'skip 'cached '())
                          'right  (decision 'skip 'cached '())
                          'join   (decision 'skip 'cached '()))))]
       [thy (cross-check g exps "diamond under a boundary")])
  (check-equal? (datalog-blames thy 'join) (set 'ingest 'left 'right)
                "join's transitive chain reaches the boundary root")
  (check-equal? (datalog-own-reason thy 'join) #f
                "join is stale only via upstreams — no reason of its own")
  (check-equal? (datalog-own-reason thy 'ingest) 'boundary
                "the root cause carries its own reason"))

;; a --from-style suffix where one branch changed: staleness flows down only
;; the changed branch
(let* ([exps (walk-explanations
              g '(left right join)
              (stub (hash 'left  (decision 'skip 'cached '())
                          'right (decision 'run 'input-changed '(raw))
                          'join  (decision 'skip 'cached '()))))]
       [thy (cross-check g exps "one changed branch")])
  (check-false (datalog-stale? thy 'left) "the untouched branch is fresh")
  (check-equal? (datalog-blames thy 'join) (set 'right)
                "join blames exactly the changed branch")
  (check-equal? (datalog-own-reason thy 'right) 'input-changed
                "the root cause is the input change"))

;; everything cached, nothing above: nothing is stale
(let* ([exps (walk-explanations
              g '(left right join)
              (stub (hash 'left  (decision 'skip 'cached '())
                          'right (decision 'skip 'cached '())
                          'join  (decision 'skip 'cached '()))))]
       [thy (cross-check g exps "all cached")])
  (check-equal? (datalog-stale-tasks thy) (set) "an entirely fresh suffix"))

;; --- The real graph -----------------------------------------------------------

;; Decisions computed by the real cache layer (stub resolve, throwaway cache
;; dir — nothing executes), then the same invariant on all 21 beeatlas tasks.
(define-runtime-path here "provenance-test.rkt")
(let*-values ([(ordered pruned) (plan beeatlas-graph 'occurrences.db)])
  (define an-existing-file (path->string here))
  (define (resolve a)
    (case a [(occurrences.parquet taxa.csv.gz) an-existing-file] [else #f]))
  (define exps
    (walk-explanations
     beeatlas-graph ordered
     (lambda (name)
       (define t (hash-ref (graph-tasks beeatlas-graph) name))
       (task-decision beeatlas-graph name resolve "/nonexistent-cache-dir"
                      (filter values (map resolve (task-outputs t)))))))
  (void (cross-check beeatlas-graph exps "beeatlas occurrences.db plan")))
