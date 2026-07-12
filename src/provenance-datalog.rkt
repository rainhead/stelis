#lang racket/base

;; Provenance as Datalog (st-yg7.3) — the third application of the Datalog
;; metadata layer, after reachability (plan-datalog.rkt) and its cross-check.
;;
;; The cache layer's decision records become facts; staleness becomes rules:
;;
;;   stale(T)            :- must-run(T, R).            ; a reason of T's own
;;   stale(T)            :- depends(T, U), stale(U).   ; ...or a stale upstream
;;   stale-because(T, U) :- depends(T, U), stale(U).   ; the edge that carries it
;;   blames(T, U)        :- stale-because(T, U).       ; transitive closure:
;;   blames(T, V)        :- stale-because(T, U), blames(U, V).
;;
;; so "why is X stale?" is the query blames(X, U) — the full transitive chain,
;; where --explain (slice 2) only reports one hop. `depends' edges are asserted
;; within the plan only, mirroring walk-explanations' in-plan frontier (and
;; --from suffix scoping). Datalog reasons ABOUT the build, per the Horizon 0
;; commitment; nothing here touches the transformations themselves.
;;
;; The theory answers STRUCTURE (stale? whom to blame); prose details (which
;; input changed, which paths are missing) stay on the decision records — use
;; the two together, as main.rkt's --why does.

(require datalog
         racket/dict
         racket/set
         "model.rkt"
         "cache.rkt"
         "explain.rkt")

(provide explanations->theory
         datalog-stale-tasks
         datalog-stale?
         datalog-direct-blames
         datalog-blames
         datalog-own-reason)

;; explanations->theory : graph (listof explanation?) -> theory
;; Facts: must-run(T,R) / cached(T) from each task's own decision;
;; changed-input(T,A) naming each changed input; depends(T,U) for in-plan
;; producer edges. Plus the staleness rules above.
(define (explanations->theory g exps)
  (define thy (make-theory))
  (define in-plan (for/set ([e (in-list exps)]) (explanation-task e)))
  (for ([e (in-list exps)])
    (define name (explanation-task e))
    (define d (explanation-decision e))
    (case (decision-verdict d)
      [(run)
       (assert-must-run! thy name (decision-reason d))
       (when (eq? 'input-changed (decision-reason d))
         (for ([a (in-list (decision-details d))])
           (assert-changed-input! thy name a)))]
      [(skip) (assert-cached! thy name)])
    (define t (hash-ref (graph-tasks g) name))
    (for* ([in (in-list (task-inputs t))]
           [p (in-value (producer-of g in))]
           #:when (and p (set-member? in-plan p)))
      (assert-depends! thy name p)))
  (datalog thy
           (! (:- (stale T)            (must-run T R)))
           (! (:- (stale T)            (depends T U) (stale U)))
           (! (:- (stale-because T U)  (depends T U) (stale U)))
           (! (:- (blames T U)         (stale-because T U)))
           (! (:- (blames T V)         (stale-because T U) (blames U V))))
  thy)

;; --- Queries ------------------------------------------------------------------

;; All stale tasks. Must equal the plain-Racket frontier — every task whose
;; explanation runs or is conditional (the cross-check in provenance-test.rkt).
(define (datalog-stale-tasks thy)
  (for/set ([s (in-list (datalog thy (? (stale T))))]) (dict-ref s 'T)))

(define (datalog-stale? thy t)
  (pair? (datalog thy (? (stale #,t)))))

;; The one-hop culprits: stale upstreams T directly depends on.
(define (datalog-direct-blames thy t)
  (for/set ([s (in-list (datalog thy (? (stale-because #,t U))))]) (dict-ref s 'U)))

;; The transitive chain: every upstream whose state reaches T.
(define (datalog-blames thy t)
  (for/set ([s (in-list (datalog thy (? (blames #,t U))))]) (dict-ref s 'U)))

;; T's own must-run reason, or #f if T is cached (stale only via upstreams, if
;; at all). Root causes of T = tasks in (blames T) ∪ {T} with an own reason.
(define (datalog-own-reason thy t)
  (define subst (datalog thy (? (must-run #,t R))))
  (and (pair? subst) (dict-ref (car subst) 'R)))

;; --- Fact assertion helpers (runtime symbols spliced as constants) -------------

(define (assert-must-run! thy t r)      (datalog thy (! (must-run #,t #,r)))      (void))
(define (assert-cached! thy t)          (datalog thy (! (cached #,t)))            (void))
(define (assert-changed-input! thy t a) (datalog thy (! (changed-input #,t #,a))) (void))
(define (assert-depends! thy t u)       (datalog thy (! (depends #,t #,u)))       (void))
