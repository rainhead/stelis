#lang racket/base

;; taxon-edges.rkt (st-an7): the typing core is pure, so these run on fixtures.
;; What is pinned: the host-SET grouping (D3 — one dependence per parasite,
;; never one per host row); the two proof flavors staying distinct; grounding
;; marks (D4 — kept, marked, never dropped); the three beegap flags on forage
;; edges (D2 — flags, not gates); atlas scoping (national-only species produce
;; nothing); and deterministic ordering.

(require rackunit
         racket/set
         "taxon-inherit.rkt"
         "taxon-edges.rkt")

(define atlas (set "bombus ashtoni" "bombus affinis" "stelis montana"
                   "andrena prunorum" "epeolus minimus"))

;; nesting facts as the closure would derive them: ashtoni characterized via an
;; ancestor, montana directly; epeolus deliberately ABSENT (the 'recorded arm)
(define nesting
  (hash "bombus ashtoni"
        (inherited (make-taxon-key 'species "bombus ashtoni")
                   'nesting 'cleptoparasitic
                   (make-taxon-key 'subgenus "Psithyrus") 'subgenus "Psithyrus")
        "stelis montana"
        (inherited (make-taxon-key 'species "stelis montana")
                   'nesting 'cleptoparasitic
                   (make-taxon-key 'genus "Stelis") 'genus "Stelis")))

(define host-edges
  ;; ashtoni: two hosts, one local, one not; duplicate row collapses.
  ;; epeolus: uncharacterized parasite (source-proof arm).
  ;; nomada texana: NOT in the atlas — must produce nothing.
  (list (cons "bombus ashtoni" "Bombus affinis")
        (cons "bombus ashtoni" "Bombus terricola")
        (cons "bombus ashtoni" "Bombus affinis")
        (cons "epeolus minimus" "Colletes kincaidii")
        (cons "nomada texana" "Melissodes communis")))

(define hd (host-dependencies host-edges nesting atlas))

(check-equal? (map host-dependence-species hd)
              '("bombus ashtoni" "epeolus minimus")
              "one dependence PER PARASITE, atlas-scoped, sorted — never per row")

(define ashtoni (car hd))
(check-equal? (host-dependence-proof ashtoni) 'characterized)
(check-equal? (host-dependence-source-rank ashtoni) 'subgenus)
(check-equal? (host-dependence-source-name ashtoni) "Psithyrus"
              "the proof is the inheritance chain, not the edge row")
(check-equal? (host-dependence-targets ashtoni)
              '(("Bombus affinis" . #t) ("Bombus terricola" . #f))
              "the host SET: deduplicated, sorted, each marked in-atlas or not — the ungrounded host is KEPT")

(define epeolus (cadr hd))
(check-equal? (host-dependence-proof epeolus) 'recorded
              "a parasite no assertion reaches keeps the source-level proof")
(check-false (host-dependence-source-rank epeolus))

;; forage: membership is the claim; diet_breadth only sets the flag
(define forage-rows
  (list (list "andrena prunorum" "Rosaceae" "Rosaceae : Prunus L.")
        (list "andrena prunorum" #f "Larrea Cav.")
        (list "epeolus minimus" "Asteraceae" "Asteraceae : Solidago L.")
        (list "stelis montana" "Fabaceae" "Fabaceae : Lupinus L.")
        (list "megachile fortis" "Asteraceae" "Asteraceae : Helianthus L.")))
(define diet (hash "andrena prunorum" "specialist"
                   "epeolus minimus"  "generalist"))

(define fd (forage-dependencies forage-rows diet atlas))
(check-equal? (map forage-dependence-species fd)
              '("andrena prunorum" "epeolus minimus" "stelis montana")
              "atlas-scoped (megachile fortis dropped), sorted")
(check-equal? (forage-dependence-beegap (car fd)) 'agrees)
(check-equal? (forage-dependence-beegap (cadr fd)) 'disputed
              "Bee-Gap 'generalist' beside a Fowler row = the flag, nothing fails")
(check-equal? (forage-dependence-beegap (caddr fd)) 'no-value
              "no diet_breadth = the coverage-win arm, distinct from dispute")
(check-equal? (forage-dependence-plants (car fd))
              '((#f . "Larrea Cav.") ("Rosaceae" . "Rosaceae : Prunus L."))
              "family-less rows survive as (#f . detail), sorted by detail")

;; determinism: same inputs, same value (the artifact must be byte-stable)
(check-equal? hd (host-dependencies host-edges nesting atlas))
(check-equal? fd (forage-dependencies forage-rows diet atlas))
