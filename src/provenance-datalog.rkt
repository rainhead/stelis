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
         "trace.rkt"
         "history.rkt"
         "explain.rkt")

(provide explanations->theory
         datalog-stale-tasks
         datalog-stale?
         datalog-direct-blames
         datalog-blames
         datalog-own-reason
         print-why-tree
         history->theory
         datalog-observations
         datalog-key-observations
         datalog-derived-from)

;; explanations->theory : graph (listof explanation?) -> theory
;; Facts: must-run(T,R) from each task's own 'run decision, and depends(T,U)
;; for in-plan producer edges — the minimum the staleness rules consume.
;; (Finer-grained facts — cached(T), changed-input(T,A) — return when a rule
;; actually needs them; prose details stay on the decision records.)
(define (explanations->theory g exps)
  (define thy (make-theory))
  (define in-plan (for/set ([e (in-list exps)]) (explanation-task e)))
  (for ([e (in-list exps)])
    (define name (explanation-task e))
    (define d (explanation-decision e))
    (when (eq? 'run (decision-verdict d))
      (assert-must-run! thy name (decision-reason d)))
    (for ([p (in-list (producers-of-inputs
                       g name (lambda (p) (set-member? in-plan p))))])
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

;; --- History projection (st-sds) ------------------------------------------------
;; The build history (history.rkt) as facts — the fourth application of the
;; Datalog layer, now over PERSISTED observations rather than one live plan:
;;
;;   observed(B, A, H)      artifact A had content hash H at build B
;;   observed-key(B, A, K, H)  A's fan-out member K (a relative path) had hash H
;;                          at build B — the per-key refinement (st-6dv)
;;   ran(B, T)              task T actually ran (outcome 'ok) at build B
;;   derived-from(B, A, I)  A's producer consumed input I at build B — the BASIS
;;
;; B is the 1-based build position. It is SEQUENCE metadata: it lets timeline
;; queries walk the history in order, but the freshness rules that would consult
;; it don't exist — and won't here. The delta substrate (st-066) is what will add
;; "O is stale iff an input's current hash != the hash in O's basis"; per DESIGN,
;; that stays a content compare, and B never arbitrates currency. So this is a
;; fact projection with no derivation rules: the raw material, not the verdict.
(define (history->theory builds)
  (define thy (make-theory))
  (for ([b (in-list builds)] [i (in-naturals 1)])
    (for ([r (in-list (build-record-records b))])
      (define task (trace-record-task r))
      (when (eq? 'ok (trace-record-outcome r))
        (assert-ran! thy i task))
      (define snap (trace-record-snapshot r))
      (define inputs
        (if snap (hash-keys (snapshot-input-hashes snap)) '()))
      (for ([pair (in-list (trace-record-output-hashes r))])
        (assert-observed! thy i (car pair) (cdr pair))
        (for ([in (in-list inputs)])
          (assert-derived-from! thy i (car pair) in)))
      ;; the per-key refinement: one fact per fan-out member of each 'dir output
      (for* ([entry (in-list (trace-record-output-key-hashes r))]
             [kp (in-list (cdr entry))])
        (assert-observed-key! thy i (car entry) (car kp) (cdr kp)))))
  thy)

;; datalog-observations : theory symbol -> (listof (cons build hash))
;; Every (build . hash) at which artifact A was observed. Unordered — sort by
;; build to get the timeline (the sequence is the caller's to walk).
(define (datalog-observations thy a)
  (for/list ([s (in-list (datalog thy (? (observed B #,a H))))])
    (cons (dict-ref s 'B) (dict-ref s 'H))))

;; datalog-key-observations : theory symbol -> (listof (list build key hash))
;; Every (build, key, hash) at which a fan-out member of 'dir artifact A was
;; observed. Unordered; sort by build for the per-key timeline. The seam H2
;; propagation reads to rebuild one key rather than the whole set.
(define (datalog-key-observations thy a)
  (for/list ([s (in-list (datalog thy (? (observed-key B #,a K H))))])
    (list (dict-ref s 'B) (dict-ref s 'K) (dict-ref s 'H))))

;; datalog-derived-from : theory symbol -> (setof symbol)
;; The inputs A was ever derived from, unioned across the history — A's basis
;; edges, the seam st-066 will read to attribute a change to a specific input.
(define (datalog-derived-from thy a)
  (for/set ([s (in-list (datalog thy (? (derived-from B #,a I))))])
    (dict-ref s 'I)))

;; --- Rendering ------------------------------------------------------------------

;; print-why-tree : theory symbol (symbol -> decision?) [(decision? -> string)]
;;                  -> void
;; The transitive chain as a tree over the stale-because edges; a node reached
;; twice (diamonds) is elided after its first showing. The theory supplies the
;; structure; the decision records supply the prose. reason->string decorates a
;; node's own reason (default = decision->string); delta-explain.rkt passes an
;; impure renderer that names the changed KEY subset for an 'input-changed node.
(define (print-why-tree thy root dec-of [reason->string decision->string])
  (define shown (mutable-set))
  (let loop ([t root] [depth 0])
    (define first-time? (not (set-member? shown t)))
    (set-add! shown t)
    (define blames
      (if first-time?
          (sort (set->list (datalog-direct-blames thy t)) symbol<?)
          '()))
    (define d (dec-of t))
    (printf "~a~a~a — ~a\n"
            (make-string (* 2 depth) #\space)
            (if (zero? depth) "" "⤷ ")
            t
            (cond
              [(not first-time?) "(shown above)"]
              ;; own inputs are fine; the staleness is inherited — say so
              ;; instead of the misleading bare "cached"
              [(and (eq? 'skip (decision-verdict d)) (pair? blames))
               "inputs unchanged, but stale through upstreams ↓"]
              [else (reason->string d)]))
    (for ([u (in-list blames)])
      (loop u (add1 depth)))))

;; --- Fact assertion helpers (runtime symbols spliced as constants) -------------

(define (assert-must-run! thy t r) (datalog thy (! (must-run #,t #,r))) (void))
(define (assert-depends! thy t u)  (datalog thy (! (depends #,t #,u)))  (void))
(define (assert-ran! thy b t)      (datalog thy (! (ran #,b #,t)))      (void))
(define (assert-observed! thy b a h)
  (datalog thy (! (observed #,b #,a #,h))) (void))
(define (assert-observed-key! thy b a k h)
  (datalog thy (! (observed-key #,b #,a #,k #,h))) (void))
(define (assert-derived-from! thy b a i)
  (datalog thy (! (derived-from #,b #,a #,i))) (void))
