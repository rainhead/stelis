#lang racket/base

;; Slice 1b (st-d44.1.2): the SAME minimal-upstream computation as model.rkt's
;; `required-tasks', but expressed as a Datalog reachability rule set instead of
;; hand-written recursion. Realizes the Horizon 0 commitment "Datalog as a
;; metadata language about the build" (reachability is the canonical bottom-up
;; Datalog program). Kept alongside 1a as a consistency check (plan-test.rkt).
;;
;; The whole computation is three rules:
;;
;;   needed-artifact(A) :- goal(A).
;;   needed-task(T)     :- needed-artifact(A), produces(T, A).
;;   needed-artifact(A) :- needed-task(T), consumes(T, A).
;;
;; i.e. the target is needed; the task producing a needed artifact is needed;
;; anything a needed task consumes is needed. The bottom-up closure of that IS
;; the minimal upstream — no traversal code, no visited-set bookkeeping.

(require datalog
         racket/dict
         racket/set
         "model.rkt")

(provide datalog-required-tasks)

;; datalog-required-tasks : graph symbol -> (setof symbol)
;; Must equal model.rkt's `required-tasks' for the same inputs (the 1b cross-check).
(define (datalog-required-tasks g target)
  (define thy (graph->theory g target))
  (for/set ([subst (in-list (datalog thy (? (needed-task T))))])
    (dict-ref subst 'T)))

;; Load the graph's edges as `produces'/`consumes' facts, the target as a `goal'
;; fact, and the three reachability rules; return the theory.
(define (graph->theory g target)
  (define thy (make-theory))
  (for ([t (in-list (hash-values (graph-tasks g)))])
    (define name (task-name t))
    (for ([a (in-list (task-outputs t))]) (assert-produces! thy name a))
    (for ([a (in-list (task-inputs t))])  (assert-consumes! thy name a)))
  (assert-goal! thy target)
  (datalog thy
           (! (:- (needed-artifact A) (goal A)))
           (! (:- (needed-task T)     (needed-artifact A) (produces T A)))
           (! (:- (needed-artifact A) (needed-task T)     (consumes T A))))
  thy)

;; One-edge assertion helpers. Each splices runtime symbols (`#,') in as Datalog
;; constants — the mechanism the probe confirmed.
(define (assert-produces! thy t a) (datalog thy (! (produces #,t #,a))) (void))
(define (assert-consumes! thy t a) (datalog thy (! (consumes #,t #,a))) (void))
(define (assert-goal!     thy a)   (datalog thy (! (goal #,a)))         (void))
