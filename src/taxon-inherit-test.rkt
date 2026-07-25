#lang racket/base

;; The pure taxon-inheritance core (st-ozp). Pins what ADR 0008 claims earns the
;; substrate: a trait asserted ONCE at a high rank reaches every descendant, at
;; UNBOUNDED depth, through a SPARSE lineage, carrying the proof of where it came
;; from — and reaches nothing outside that lineage.
;;
;; The fixture is the real beeatlas cuckoo taxonomy in miniature: Nomadinae (a
;; subfamily, 3–4 ranks above its species) and Psithyrus (a subgenus, 1 rank
;; above), with a non-cuckoo Bombus alongside as the negative control.

(require rackunit
         racket/list
         racket/string
         "taxon-inherit.rkt")

;; --- Fixture -------------------------------------------------------------------

;; (family subfamily tribe genus subgenus species) — #f = the rank is absent,
;; which is the common case for subgenus.
(define (lineage . names)
  (lineage->taxa (map cons RANKS names)))

(define fixture
  (merge-taxa
   (append
    ;; deep + sparse: no subgenus, so species hangs off genus, 3 ranks below Nomadinae
    (lineage "Apidae" "Nomadinae" "Nomadini" "Nomada" #f "Nomada bella")
    ;; deeper: subgenus present, 4 ranks below Nomadinae
    (lineage "Apidae" "Nomadinae" "Epeolini" "Epeolus" "Argyroselenis" "Epeolus minimus")
    ;; the shallow assertion: Psithyrus is a SUBGENUS, one rank above its species
    (lineage "Apidae" "Apinae" "Bombini" "Bombus" "Psithyrus" "Bombus insularis")
    ;; negative control: same genus, no Psithyrus — must inherit nothing
    (lineage "Apidae" "Apinae" "Bombini" "Bombus" #f "Bombus melanopygus"))))

(define assertions
  (list (assertion 'subfamily "Nomadinae" 'nesting 'cleptoparasitic
                   "ground-nesting bees, chiefly Andrena" #f)
        (assertion 'subgenus "Psithyrus" 'nesting 'cleptoparasitic
                   "other bumble bees" "The host's own workers raise her offspring.")))

(define thy (taxonomy->theory fixture assertions))
(define rows (inherited-traits thy))

(define (traits-of subject)
  (for/list ([r (in-list rows)] #:when (eq? (inherited-subject r) subject)) r))
(define (sole subject)
  (define ts (traits-of subject))
  (check-equal? (length ts) 1 (format "~a should carry exactly one derived trait" subject))
  (first ts))

;; --- Sparse lineages still form one unbroken chain -----------------------------

(define nomada-chain (lineage "Apidae" "Nomadinae" "Nomadini" "Nomada" #f "Nomada bella"))
(check-equal? (map taxon-key nomada-chain)
              '(family:Apidae subfamily:Nomadinae tribe:Nomadini
                genus:Nomada |species:Nomada bella|)
              "a missing rank contributes no node")
(check-equal? (taxon-parent (last nomada-chain)) 'genus:Nomada
              "…and the next present rank links to the NEAREST present ancestor, not a hole")

;; --- Inheritance: unbounded depth, through the gap ------------------------------

(define bella (sole '|species:Nomada bella|))
(check-equal? (inherited-value bella) 'cleptoparasitic)
(check-equal? (inherited-source bella) 'subfamily:Nomadinae
              "3 ranks up, across an absent subgenus — the closure, not a 1-level join")
(check-equal? (inherited-source-rank bella) 'subfamily
              "the asserting node's RANK rides on the derived fact (most-specific-wins, later)")
(check-equal? (inherited-source-name bella) "Nomadinae")

(check-equal? (inherited-source (sole '|species:Epeolus minimus|)) 'subfamily:Nomadinae
              "…and 4 ranks up through a present subgenus: depth is not fixed")

;; --- Inheritance from a LOW rank, and only within its lineage -------------------

(define insularis (sole '|species:Bombus insularis|))
(check-equal? (inherited-source insularis) 'subgenus:Psithyrus
              "an assertion one rank up reaches its species too")
(check-equal? (inherited-source-rank insularis) 'subgenus)

(check-equal? (traits-of '|species:Bombus melanopygus|) '()
              "a sibling species outside the asserting subgenus inherits NOTHING (closed world)")
(check-equal? (traits-of 'subfamily:Apinae) '()
              "…and the trait never travels UP: Apinae is not cleptoparasitic")

;; --- The assertion holds at its own taxon (reflexive) ---------------------------

(define nomadinae (sole 'subfamily:Nomadinae))
(check-equal? (inherited-source nomadinae) 'subfamily:Nomadinae
              "the asserting taxon carries the trait itself, sourced to itself")

;; --- Everything the two assertions reach ----------------------------------------

(check-equal? (sort (map (lambda (r) (symbol->string (inherited-subject r))) rows) string<?)
              (sort (list "species:Nomada bella" "species:Epeolus minimus"
                          "species:Bombus insularis"
                          "subfamily:Nomadinae" "tribe:Nomadini" "tribe:Epeolini"
                          "genus:Nomada" "genus:Epeolus" "subgenus:Argyroselenis"
                          "subgenus:Psithyrus")
                    string<?)
              "two assertions characterize the whole subtree beneath them — and nothing else")

;; --- Determinism (a day-one property, DESIGN) -----------------------------------

(check-equal? (inherited-traits (taxonomy->theory fixture assertions)) rows
              "same taxonomy + assertions ⇒ same derived rows, same order")
(check-equal? (inherited-traits (taxonomy->theory (reverse fixture) (reverse assertions)))
              rows
              "…independent of the order the facts were asserted in")

;; --- Homonyms are an error, not a silent mis-graft -------------------------------

(check-exn #rx"homonym: subgenus:Triepeolus"
           (lambda ()
             (merge-taxa
              (append (lineage "Apidae" "Nomadinae" "Epeolini" "Triepeolus" "Triepeolus" #f)
                      (lineage "Apidae" "Nomadinae" "Epeolini" "Epeolus" "Triepeolus" #f))))
           "the same rank+name under two parents would graft a subtree onto the wrong lineage")

;; --- Conflicts: none yet, and detected when they arrive --------------------------

(check-equal? (trait-conflicts rows) '()
              "the real cuckoo lineages are disjoint — defeasible override stays deferred")

(define conflicted
  (inherited-traits
   (taxonomy->theory fixture
                     (cons (assertion 'genus "Nomada" 'nesting 'ground #f #f)
                           assertions))))
(define cs (trait-conflicts conflicted))
(check-equal? (length cs) 2
              "a lower assertion disagreeing with a higher one conflicts at Nomada AND every taxon below it")
(check-equal? (first (first cs)) 'genus:Nomada)
(check-equal? (sort (map (lambda (r) (symbol->string (inherited-source r))) (third (first cs)))
                    string<?)
              '("genus:Nomada" "subfamily:Nomadinae")
              "…and the conflict names both claimants, so most-specific-wins can be decided on data")

;; --- Prose: the published half ---------------------------------------------------
;; The composed sentence carries only what is SPECIFIC — the proof, the hosts, any
;; particular note. What "cleptoparasitic" MEANS is deliberately absent: that lives
;; in the glossary and is rendered once per page, not restated per species.

(define ix (assertion-index assertions))
(check-equal? (explanation-string bella "Nomada bella" ix)
              (string-append "Nomada bella is cleptoparasitic, inherited from the "
                             "subfamily Nomadinae. It parasitizes ground-nesting "
                             "bees, chiefly Andrena.")
              "proof + hosts; no definition of the term")
(check-equal? (explanation-string nomadinae "Nomadinae" ix)
              "Nomadinae is cleptoparasitic. It parasitizes ground-nesting bees, chiefly Andrena."
              "a trait asserted AT a taxon is not 'inherited from' anywhere")
(check-equal? (explanation-string insularis "Bombus insularis" ix)
              (string-append "Bombus insularis is cleptoparasitic, inherited from the "
                             "subgenus Psithyrus. It parasitizes other bumble bees. "
                             "The host's own workers raise her offspring.")
              "an optional note appends only where a lineage has something particular")
(check-equal? (explanation-string bella "Nomada bella" (hash))
              "Nomada bella is cleptoparasitic, inherited from the subfamily Nomadinae."
              "…and with no assertion prose at all, the proof alone still reads as a sentence")

;; A checklist carries genus-level records as species-rank rows, so a node can
;; inherit from another node PUBLISHED UNDER THE SAME NAME. Comparing keys alone
;; produces "Stelis is cleptoparasitic, inherited from the genus Stelis."
(define stelis-fixture
  (merge-taxa (lineage "Megachilidae" "Megachilinae" "Anthidiini" "Stelis" #f "Stelis")))
(define stelis-rows
  (inherited-traits
   (taxonomy->theory stelis-fixture
                     (list (assertion 'genus "Stelis" 'nesting 'cleptoparasitic #f #f)))))
(define stelis-record
  (findf (lambda (r) (eq? 'species:Stelis (inherited-subject r))) stelis-rows))
(check-equal? (explanation-string stelis-record "Stelis" (hash))
              "Stelis is cleptoparasitic."
              "two nodes published under one name are one taxon to a reader — no self-reference")

;; --- The fact file's shape --------------------------------------------------------

(define (parse-both datum)
  (define-values (g a) (parse-fact-file datum))
  (list g a))

(define parsed
  (parse-both '(taxon-traits
                (glossary (cleptoparasitic "A cuckoo bee."))
                (traits (subfamily "Nomadinae"
                          (nesting cleptoparasitic (hosts "Andrena")))))))
(check-equal? (hash-ref (first parsed) 'cleptoparasitic) "A cuckoo bee."
              "the glossary defines a VALUE once, for every species that carries it")
(check-equal? (second parsed)
              (list (assertion 'subfamily "Nomadinae" 'nesting 'cleptoparasitic "Andrena" #f)))

(check-equal? (length (second (parse-both
                               '(taxon-traits
                                 (glossary (cleptoparasitic "x") (ground "y"))
                                 (traits (subfamily "Nomadinae"
                                           (nesting cleptoparasitic (hosts "a"))
                                           (sociality ground (note "b"))))))))
              2 "several traits may be asserted at one taxon")

;; hosts and note are both OPTIONAL and order-independent — a clause with neither
;; is legitimate (the trait alone is the claim).
(check-equal? (second (parse-both '(taxon-traits (glossary (cleptoparasitic "x"))
                                                 (traits (genus "Stelis" (nesting cleptoparasitic))))))
              (list (assertion 'genus "Stelis" 'nesting 'cleptoparasitic #f #f)))
(check-equal? (second (parse-both
                       '(taxon-traits (glossary (cleptoparasitic "x"))
                                      (traits (genus "Stelis"
                                                (nesting cleptoparasitic (note "n") (hosts "h")))))))
              (list (assertion 'genus "Stelis" 'nesting 'cleptoparasitic "h" "n")))

;; An asserted value with no glossary entry would publish a bare word — the whole
;; point of moving the definition out of the clauses is that it is said SOMEWHERE.
(check-exn #rx"no glossary entry for value cleptoparasitic"
           (lambda () (parse-fact-file
                       '(taxon-traits (traits (subfamily "Nomadinae" (nesting cleptoparasitic)))))))
(check-exn #rx"unknown rank"
           (lambda () (parse-fact-file '(taxon-traits (traits (clade "Anthophila"))))))
(check-exn #rx"expected a \\(taxon-traits" (lambda () (parse-fact-file '(traits))))
(check-exn #rx"unknown section"
           (lambda () (parse-fact-file '(taxon-traits (notes (a "b"))))))
(check-exn #rx"expected \\(hosts"
           (lambda () (parse-fact-file
                       '(taxon-traits (glossary (cleptoparasitic "x"))
                                      (traits (genus "Stelis" (nesting cleptoparasitic (why "no"))))))))

;; --- Assertions that name no local taxon are reported, never silently dropped ----

(check-equal? (map assertion-name
                   (unresolved-assertions
                    fixture
                    (cons (assertion 'subfamily "Xylocopinae" 'nesting 'wood #f #f) assertions)))
              '("Xylocopinae"))
(check-equal? (unresolved-assertions fixture assertions) '())
