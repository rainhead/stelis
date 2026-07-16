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
         "trace.rkt"
         "history.rkt"
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
  (define env
    (make-build-env (lambda (a _export-dir)
                      (case a [(occurrences.parquet taxa.csv.gz) an-existing-file] [else #f]))
                    #f
                    "/nonexistent-cache-dir"))
  (define exps (plan-explanations beeatlas-graph ordered env))
  (void (cross-check beeatlas-graph exps "beeatlas occurrences.db plan")))

;; --- History projection (st-sds) ----------------------------------------------

;; The history-as-facts projection: observations, basis edges, and runs come
;; back exactly as recorded — the raw material for the delta substrate (st-066),
;; with no freshness rule consuming the build sequence.
(let ()
  (define (rec in-h out-h)
    (trace-record 'derive (decision 'run 'input-changed '(raw))
                  (snapshot "recipe" (hash 'raw in-h))
                  'ok '() #f (list (cons 'mid out-h)) '() '()))
  (define b1 (build-record 'mid "g" "1000" (list (rec "r0" "m0"))))
  ;; a cached build re-observes nothing (empty output-hashes) — no timeline point
  (define b2 (build-record 'mid "g" "2000"
                           (list (trace-record 'derive (decision 'skip 'cached '())
                                               #f 'cached '() #f '() '() '()))))
  (define b3 (build-record 'mid "g" "3000" (list (rec "r1" "m1"))))
  (define thy (history->theory (list b1 b2 b3)))
  (check-equal? (sort (datalog-observations thy 'mid) < #:key car)
                '((1 . "m0") (3 . "m1"))
                "mid observed only at the builds that (re)produced it")
  (check-equal? (datalog-derived-from thy 'mid) (set 'raw)
                "mid's basis edge: derived from raw")
  (check-equal? (datalog-observations thy 'raw) '()
                "an unproduced input has no observations"))

;; the per-key refinement (st-6dv): observed-key/4 facts for fan-out members
(let ()
  (define (rec-maps b keys)
    (build-record 'species-maps "g" (number->string b)
                  (list (trace-record 'maps (decision 'run 'input-changed '(taxa))
                                      (snapshot "r" (hash 'taxa "t")) 'ok '() #f
                                      '((species-maps . "d"))
                                      (list (cons 'species-maps keys))
                                      '()))))
  (define thy (history->theory
               (list (rec-maps 1 '(("genus/Bombus.svg" . "b0")))
                     (rec-maps 2 '(("genus/Bombus.svg" . "b1"))))))
  (check-equal? (sort (datalog-key-observations thy 'species-maps) < #:key car)
                '((1 "genus/Bombus.svg" "b0") (2 "genus/Bombus.svg" "b1"))
                "one per-key observation per producing build, keyed by path")
  (check-equal? (datalog-key-observations thy 'nope) '()
                "an artifact with no fan-out layer has no observed-key facts"))
