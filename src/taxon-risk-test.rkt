#lang racket/base

;; taxon-risk.rkt (st-6x9): the closure is pure, so the FORALL semantics are
;; pinned on fixtures. What is pinned: the collapse rules (singleton -> plant
;; grain, family-uniform -> family grain, family-less rows blocking the family
;; claim); necessity through hosts only when EVERY grounded host needs the same
;; target (any-of: one host that doesn't need it keeps the parasite alive);
;; ungrounded hosts blocking derivation entirely; the disputed flag composing
;; up the chain; unbounded depth (a host that is itself a parasite); and
;; deterministic output.

(require rackunit
         racket/list
         "taxon-edges.rkt"
         "taxon-risk.rkt")

;; --- base collapses -----------------------------------------------------------

(define forage
  (list
   ;; singleton -> plant-grain necessity
   (forage-dependence "andrena astragali" 'agrees
                      '(("Asphodelaceae" . "Toxicoscordion")))
   ;; two plants, one family -> family-grain necessity
   (forage-dependence "andrena prunorum" 'no-value
                      '(("Rosaceae" . "Prunus L.") ("Rosaceae" . "Rosa L.")))
   ;; two families -> nothing collapses
   (forage-dependence "megachile fortis" 'agrees
                      '(("Asteraceae" . "Helianthus L.") ("Fabaceae" . "Lupinus L.")))
   ;; family-less row blocks the family claim even though the named one agrees
   (forage-dependence "anthophora pacifica" 'agrees
                      '(("Ericaceae" . "Arctostaphylos") (#f . "Larrea Cav.")))
   ;; disputed singleton -> the base fact itself is flagged
   (forage-dependence "dufourea calochorti" 'disputed
                      '(("Liliaceae" . "Calochortus")))
   ;; a second family-uniform Rosaceae specialist, for the multi-host forall
   (forage-dependence "panurginus rosae" 'agrees
                      '(("Rosaceae" . "Crataegus L.") ("Rosaceae" . "Rosa L.")))))

(define base (base-necessities forage))

(check-equal? (for/list ([n (in-list base)])
                (list (necessity-species n) (necessity-grain n) (necessity-target n)))
              '(("andrena astragali" plant "Toxicoscordion")
                ("andrena prunorum" family "Rosaceae")
                ("dufourea calochorti" plant "Calochortus")
                ("panurginus rosae" family "Rosaceae"))
              "only collapsed any-of sets yield claims; grain follows the collapse")
(check-false (necessity-flagged? (first base)))
(check-true (necessity-flagged? (third base))
            "a disputed forage edge flags its own base fact")
(check-false (necessity-via (first base)) "base facts carry no via — the proof is the oligolecty")

;; --- derivation through hosts -------------------------------------------------

(define (dep parasite . hosts)
  (host-dependence parasite 'characterized 'subfamily "Nomadinae"
                   (for/list ([h (in-list hosts)])
                     (if (pair? h) h (cons h #t)))))

(define hosts
  (list
   ;; single grounded host with a singleton chain -> derives
   (dep "nomada one" "Andrena astragali")
   ;; two hosts BOTH needing Rosaceae... only one does -> no derivation
   (dep "nomada two" "Andrena prunorum" "Megachile fortis")
   ;; host with an ungrounded sibling -> no derivation, even though the
   ;; grounded one has a necessity
   (dep "nomada three" "Andrena astragali" (cons "Andrena caerulea" #f))
   ;; disputed chain -> the derived fact is flagged
   (dep "nomada four" "Dufourea calochorti")
   ;; DEPTH: a cuckoo of a cuckoo — nomada five's host is nomada one, whose own
   ;; necessity only exists after round one
   (dep "nomada five" "Nomada one")
   ;; the POSITIVE multi-host forall (the load-bearing branch): two grounded
   ;; hosts, different plants, ONE shared family-grain target. Replacing the
   ;; intersection with a union — the exact D4 over-claim — is what this pins.
   (dep "nomada six" "Andrena prunorum" "Panurginus rosae")))

(define derived (derived-necessities hosts base))

(check-equal? (for/list ([n (in-list derived)])
                (list (necessity-species n) (necessity-grain n) (necessity-target n)))
              '(("nomada five" plant "Toxicoscordion")
                ("nomada four" plant "Calochortus")
                ("nomada one" plant "Toxicoscordion")
                ("nomada six" family "Rosaceae"))
              "derivation demands the forall: shared-by-all targets only, grounded sets only — and depth is unbounded (nomada five, via nomada one)")

(define n1 (findf (lambda (n) (equal? (necessity-species n) "nomada one")) derived))
(check-equal? (map car (necessity-via n1)) '("Andrena astragali")
              "the via carries each host by its display name")
(check-equal? (necessity-species (cdr (car (necessity-via n1)))) "andrena astragali"
              "…paired with that host's own necessity — the proof tree, not a bare pointer")
(check-false (necessity-flagged? n1))

(define n4 (findf (lambda (n) (equal? (necessity-species n) "nomada four")) derived))
(check-true (necessity-flagged? n4)
            "the dispute composes: a flagged link anywhere flags the derived fact")

(define n5 (findf (lambda (n) (equal? (necessity-species n) "nomada five")) derived))
(check-equal? (necessity-species (cdr (car (necessity-via n5)))) "nomada one"
              "the depth-2 proof nests the intermediate cuckoo's derived fact")
(check-pred pair? (necessity-via (cdr (car (necessity-via n5))))
            "…which itself carries ITS host — the chain bottoms out at the oligolecty")

(define n6 (findf (lambda (n) (equal? (necessity-species n) "nomada six")) derived))
(check-equal? (map car (necessity-via n6)) '("Andrena prunorum" "Panurginus rosae")
              "the multi-host forall carries one via PER host — every branch of the proof")
(check-equal? (for/list ([v (in-list (necessity-via n6))])
                (necessity-target (cdr v)))
              '("Rosaceae" "Rosaceae")
              "…each host's own necessity names the SAME shared target — intersection, never union")

;; --- sentences ------------------------------------------------------------------

(check-equal? (necessity-sentence (first base) "Andrena astragali")
              "Andrena astragali is imperilled if Toxicoscordion declines: it collects pollen only from that plant.")
(check-equal? (necessity-sentence n1 "Nomada one")
              "Nomada one is imperilled if Toxicoscordion declines, because its recorded host, Andrena astragali, depends on it — and a cuckoo goes only where its hosts go.")
(check-equal? (necessity-sentence (second base) "Andrena prunorum")
              "Andrena prunorum is imperilled if the Rosaceae declines: it collects pollen only from that family.")
(check-equal? (necessity-sentence n6 "Nomada six")
              "Nomada six is imperilled if the Rosaceae declines, because every recorded host (Andrena prunorum, Panurginus rosae) depends on it — and a cuckoo goes only where its hosts go.")

;; --- determinism ----------------------------------------------------------------

(check-equal? derived (derived-necessities hosts base)
              "same inputs, same facts in the same order")
