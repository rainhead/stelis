#lang racket/base

;; The at-risk CLOSURE (st-6x9, ADR 0008 step 3) — the pure core, and the arc's
;; payoff: the ecological chain (cuckoo -> host bee -> forage plant -> "depends
;; on that plant"), computed over st-an7's TYPED edges, each derived fact
;; carrying its proof.
;;
;; WHAT MAY BE CLAIMED — the one rule everything here serves. A typed dependence
;; is ANY-OF: a cuckoo survives if any recorded host survives, an oligolege if
;; any listed plant survives. So the strict, publishable claim "imperilled if X
;; declines" is true only where every any-of node on the chain COLLAPSES:
;;
;;   plant grain  — a specialist whose plant set is a SINGLETON needs that plant.
;;   family grain — a specialist whose plants all share ONE family needs that
;;                  family (a coarser event, but strictly true: lose the family,
;;                  lose every member). A row Fowler gives without a family
;;                  ("Larrea Cav.") blocks the family claim — unknown is not
;;                  uniform.
;;   through hosts — a parasite needs X only if EVERY recorded host needs X
;;                  (any-of over the set: one surviving host that doesn't need X
;;                  keeps the parasite alive without X), and only if every host
;;                  is GROUNDED — an out-of-atlas host might not need X, and
;;                  claiming through it would publish a guess.
;;
;; Anything looser — "depends on the union of what its hosts eat" — is exactly
;; the over-claim ADR 0008 D4 forbids. The broader exposure surface is not
;; recomputed here because it is already PUBLISHED: the artifact is keyed by
;; species and every grounded host is a key in the same file, so the site can
;; walk cuckoo -> host -> forage without a derived fact vouching for more than
;; the data says.
;;
;; The 'disputed flag COMPOSES: a derived fact whose chain crosses a disputed
;; forage edge is itself disputed — the dispute travels with the proof, never
;; disappears into it.
;;
;; ON "DATALOG": ADR 0008 phrased this step as a Datalog closure, and the
;; inheritance step genuinely is one (taxon-inherit.rkt — positive reachability,
;; source bound first). This rule is NOT positive Datalog: necessity through an
;; any-of set is a FORALL over the set's members, and encoding it as
;; reachability would derive exactly the over-claiming closure D4 forbids. What
;; earned the substrate was unbounded depth + a native why (D5), not the
;; datalog library — so this is a monotone fixpoint in plain Racket, unbounded
;; depth intact (a parasite whose host is itself a parasite resolves in the
;; next round; facts only grow, so no cycle can manufacture support), with the
;; proof tree carried on every fact.

(require racket/list
         racket/set
         racket/string
         "taxon-edges.rkt")

(provide (struct-out necessity)
         base-necessities
         derived-necessities
         necessity-sentence)

;; One strict claim: `species` is imperilled if `target` declines.
;;   species  : string — canonical_name (in-atlas)
;;   grain    : 'plant | 'family — what kind of thing `target` names
;;   target   : string — the plant detail ("Fabaceae : Lupinus L.") or family
;;   flagged? : boolean — a disputed forage edge somewhere on the chain
;;   via      : (or/c #f (listof (cons string necessity))) — #f for the BASE
;;              fact (the species' own oligolecty); for a derived fact, one
;;              (host display name . that host's necessity for the same target)
;;              per recorded host — the proof tree, every branch of the forall
(struct necessity (species grain target flagged? via) #:transparent)

;; base-necessities : (listof forage-dependence) -> (listof necessity)
;; The chain's ground floor: specialists whose any-of set collapses. Plant grain
;; for a singleton set; family grain when a larger set is family-uniform (the
;; finer claim subsumes the coarser, so a singleton emits only plant grain).
(define (base-necessities forage)
  (for*/list ([f (in-list forage)]
              [plants (in-value (remove-duplicates (forage-dependence-plants f)))]
              [claim (in-value
                      (cond
                        [(null? plants) #f]
                        [(null? (cdr plants)) (cons 'plant (cdr (car plants)))]
                        [(let ([fams (remove-duplicates (map car plants))])
                           (and (null? (cdr fams)) (car fams)))
                         => (lambda (fam) (cons 'family fam))]
                        [else #f]))]
              #:when claim)
    (necessity (forage-dependence-species f)
               (car claim) (cdr claim)
               (eq? 'disputed (forage-dependence-beegap f))
               #f)))

;; derived-necessities : (listof host-dependence) (listof necessity)
;;   -> (listof necessity)
;; The fixpoint. Each round asks, for every parasite whose host set is wholly
;; grounded: which (grain . target) pairs does EVERY host need? Each shared pair
;; becomes a derived fact whose `via` carries every host's own necessity — the
;; forall, materialized as the proof. Rounds repeat because a host may itself be
;; a parasite whose facts appeared last round; facts only grow and the target
;; universe is finite, so the loop terminates without a cycle guard.
;; Deterministic output order: (species, grain, target).
(define (derived-necessities hosts base)
  ;; (cons species (cons grain target)) -> necessity, seeded with the base facts
  (define known (make-hash))
  (for ([n (in-list base)])
    (hash-set! known (cons (necessity-species n)
                           (cons (necessity-grain n) (necessity-target n)))
               n))
  (define (needs-of canonical)
    (for/list ([(k n) (in-hash known)] #:when (equal? (car k) canonical)) n))
  (let loop ()
    (define grew? #f)
    (for ([h (in-list hosts)])
      (define targets (host-dependence-targets h))
      (when (and (pair? targets) (for/and ([t (in-list targets)]) (cdr t)))
        ;; every host grounded: intersect their necessity keys
        (define per-host
          (for/list ([t (in-list targets)])
            (cons (car t) (needs-of (string-downcase (car t))))))
        (define shared
          (for/fold ([acc #f]) ([hn (in-list per-host)])
            (define keys (for/set ([n (in-list (cdr hn))])
                           (cons (necessity-grain n) (necessity-target n))))
            (if acc (set-intersect acc keys) keys)))
        (when (and shared (not (set-empty? shared)))
          (for ([key (in-set shared)])
            (define full-key (cons (host-dependence-species h) key))
            (unless (hash-has-key? known full-key)
              (define via
                (for/list ([hn (in-list per-host)])
                  (cons (car hn)
                        (findf (lambda (n) (and (eq? (necessity-grain n) (car key))
                                                (equal? (necessity-target n) (cdr key))))
                              (cdr hn)))))
              (hash-set! known full-key
                         (necessity (host-dependence-species h)
                                    (car key) (cdr key)
                                    (for/or ([v (in-list via)])
                                      (necessity-flagged? (cdr v)))
                                    via))
              (set! grew? #t))))))
    (when grew? (loop)))
  ;; derived facts are exactly those with a via — the real discriminator (a
  ;; base fact's proof is its own oligolecty, via = #f), robust where identity
  ;; filtering would silently reclassify an equal?-but-not-eq? base fact
  (sort (for/list ([(k n) (in-hash known)] #:when (necessity-via n)) n)
        (lambda (a b)
          (or (string<? (necessity-species a) (necessity-species b))
              (and (string=? (necessity-species a) (necessity-species b))
                   (string<? (format "~a ~a" (necessity-grain a) (necessity-target a))
                             (format "~a ~a" (necessity-grain b) (necessity-target b))))))))

;; necessity-sentence : necessity string -> string
;; The learner-facing line, in ADR 0008's exemplar tone ("imperilled if Clarkia
;; declines, because its host is an oligolege of Clarkia"). `display` is the
;; species' published name. The dispute is NOT restated here — it rides the
;; published flag, and the site decides how to caveat.
(define (necessity-sentence n display)
  (define what
    (case (necessity-grain n)
      [(plant) (necessity-target n)]
      [else (format "the ~a" (necessity-target n))]))
  (cond
    [(not (necessity-via n))
     (format "~a is imperilled if ~a declines: it collects pollen only from ~a."
             display what
             (if (eq? 'plant (necessity-grain n)) "that plant" "that family"))]
    [else
     (define hosts (map car (necessity-via n)))
     (format "~a is imperilled if ~a declines, because ~a — and a cuckoo goes only where its hosts go."
             display what
             (if (null? (cdr hosts))
                 (format "its recorded host, ~a, depends on it" (car hosts))
                 (format "every recorded host (~a) depends on it"
                         (string-join hosts ", "))))]))
