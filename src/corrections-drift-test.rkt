#lang racket/base

;; The correction drift gate (st-t4t). A correction overrides a CITED source, so
;; the thing that makes it legitimate is that it cannot silently outlive the error
;; it fixes. This pins that: the pure verdict, and the reader that finds drift in
;; real CSVs — including the case the dbt side structurally cannot see, a
;; correction whose upstream row is gone entirely.

(require rackunit
         racket/file
         racket/string
         "corrections-drift.rkt")

;; --- the pure verdict --------------------------------------------------------------

(define-values (ok-clean note-clean) (drift-verdict '()))
(check-true ok-clean "nothing drifted ⇒ pass")
(check-true (string-contains? note-clean "still matches") "…and says so")

(define-values (ok-unknown note-unknown) (drift-verdict #f))
(check-true ok-unknown
            "an unreadable seed DEGRADES to pass, like every other between-tasks read")
(check-true (string-contains? note-unknown "NOT checked")
            "…but never claims it verified anything")

;; --- classification: the class picks the modality (st-kfu) ---------------------------

;; CONTESTED — the seed moved to a third value nobody has judged. Whether that
;; BLOCKS depends on the source's cadence, which is the whole point: a correction
;; is an assertion that outranks a source, not a patch that rots when the source
;; moves, and a frozen source cannot move except by a reviewed commit.
(define contested
  (drift "bombus vosnesenskii" "sociality" "replace" "Parasitic" "Primitively Eusocial"
         "Solitary" #t))
(check-equal? (drift-class contested) 'contested)
(check-equal? (trait-cadence "sociality") 'frozen
              "Bee-Gap 2017 is a one-time publication, ingested as a checked-in seed")
(check-false (drift-blocking? contested)
             "a frozen seed only moves by commit, so the report belongs in that diff")

(define-values (ok-frozen note-frozen) (drift-verdict (list contested)))
(check-true ok-frozen "…and the nightly publish is not held hostage to it")
(check-true (and (string-contains? note-frozen "bombus vosnesenskii")
                 (string-contains? note-frozen "Parasitic")
                 (string-contains? note-frozen "Solitary")
                 (string-contains? note-frozen "still hold"))
            "…but it is reported, naming both values and asking the real question")

;; …and the live case, exercised before a live source exists so the blocking branch
;; is not the branch nothing has ever run.
(parameterize ([current-live-traits '("sociality")])
  (check-equal? (trait-cadence "sociality") 'live)
  (check-true (drift-blocking? contested)
              "against a LIVE source the value moved unattended — that still blocks")
  (define-values (ok-live note-live) (drift-verdict (list contested)))
  (check-false ok-live)
  (check-true (string-contains? note-live "UNVERIFIED CORRECTION")))

;; RESOLVED — upstream now says exactly what we corrected it to. This is the gate
;; SUCCEEDING; blocking here would take the build down over good news.
(define resolved-replace
  (drift "bombus vosnesenskii" "sociality" "replace" "Parasitic" "Primitively Eusocial"
         "Primitively Eusocial" #t))
(check-equal? (drift-class resolved-replace) 'resolved)
(define-values (ok-res note-res) (drift-verdict (list resolved-replace)))
(check-true ok-res "upstream adopting our correction does not block the build")
(check-true (and (string-contains? note-res "not blocking")
                 (string-contains? note-res "delete the row"))
            "…it asks for the maintenance instead, and names the action")
(check-false (string-contains? note-res "no longer needed")
             "the advisory set mixes dead weight with judgement calls — do not tell
              the reader to delete all of them")

;; RESOLVED (retraction) — an empty upstream value here is upstream WITHDRAWING the
;; assertion we objected to, which is the opposite of a failure.
(define resolved-retract
  (drift "nomada bella" "host_bees" "retract" "Andrena" "" "" #t))
(check-equal? (drift-class resolved-retract) 'resolved)
(check-false (drift-blocking? resolved-retract))

;; …but the SAME empty value under a key upstream has never heard of is a mistyped
;; correction, and the advice inverts: do not just delete it, because the species
;; actually meant is still publishing the error.
(define orphaned-retract
  (drift "bombus nonesuch" "nesting" "retract" "Host Nest" "" "" #f))
(check-equal? (drift-class orphaned-retract) 'orphaned
              "key presence, not the value, separates a withdrawal from a typo")
(define-values (_ok-orph note-orph) (drift-verdict (list orphaned-retract)))
(check-true (and (string-contains? note-orph "typo")
                 (string-contains? note-orph "still publishing the error"))
            "an orphan warns about the key, not about upstream")

;; UNCHECKED — no upstream arm for the trait, so nothing was compared. Blocks
;; REGARDLESS of cadence: this is not news about a source, it is this module's own
;; coverage lapsing, and the seed then looks guarded while one row is not.
(define unchecked (drift "osmia lignaria" "wingspan" "replace" "12mm" "11mm" "" #t))
(check-equal? (drift-class unchecked) 'unchecked)
(check-true (drift-blocking? unchecked)
            "…and a frozen source does not excuse it, unlike a contested row")
(check-false (known-trait? "wingspan"))
(check-true (known-trait? "host_bees") "the aggregate trait counts as covered")

;; An unreadable ACTION is treated as contested rather than guessed at.
(check-equal? (drift-class (drift "a" "nesting" "" "Ground" "Cavity" "Wood" #t)) 'contested)

;; A blocking verdict still enumerates the advisory rows: maintenance should not be
;; discovered one build at a time, and whoever clears the blocker is best placed to
;; clear the rest. With frozen sources the contested row lands on the advisory side
;; too, so all three are reported and only the unchecked one holds the build.
(define-values (ok-mixed note-mixed)
  (drift-verdict (list unchecked contested resolved-replace orphaned-retract)))
(check-false ok-mixed)
(check-true (string-contains? note-mixed "3 want attention (not blocking)")
            "…counted and labelled, so the two kinds are not confused")
(check-true (string-contains? note-mixed "wingspan")
            "…and the blocker is named first, not buried in the advisory list")

;; --- the reader, against real CSVs ---------------------------------------------------

(cond
  [(not (find-executable-path "duckdb"))
   (printf "corrections-drift-test: reader SKIPPED — needs duckdb\n")]
  [else
   (define tmp (make-temporary-file "stelis-drift-~a" 'directory))
   (define upstream (build-path tmp "upstream.csv"))
   (define parasites (build-path tmp "parasites.csv"))
   (define corrections (build-path tmp "corrections.csv"))
   (display-to-file
    (string-join
     '("canonical_name,native,nesting,sociality,foraging"
       "\"bombus vosnesenskii\",\"native\",\"Host Nest\",\"Parasitic\",\"Generalist\""
       "\"osmia lignaria\",\"native\",\"Cavity\",\"Solitary\",\"Generalist\"") "\n")
    upstream #:exists 'replace)

   ;; the SECOND upstream source: host-bee assertions live in their own seed, so a
   ;; host_bees correction must be compared against THAT, aggregated exactly as
   ;; species_traits.sql aggregates it.
   (display-to-file
    (string-join
     '("parasite,host_genus,host_species,host_taxon"
       "\"nomada bella\",\"andrena\",\"\",\"Andrena\""
       "\"nomada bella\",\"andrena\",\"imitatrix\",\"Andrena imitatrix\"") "\n")
    parasites #:exists 'replace)

   (define (corrections! . rows)
     (display-to-file
      (string-join (cons "canonical_name,trait,action,expected_upstream,corrected_value,reason" rows) "\n")
      corrections #:exists 'replace))

   ;; matching expectation: no drift
   (corrections! "\"bombus vosnesenskii\",\"sociality\",\"replace\",\"Parasitic\",\"Primitively Eusocial\",\"why\"")
   (check-equal? (read-drift-rows corrections upstream parasites) '()
                 "a correction whose expected value still matches upstream is not drift")

   ;; the reason prose contains commas and an em dash — the parse must survive it
   (corrections! "\"bombus vosnesenskii\",\"sociality\",\"replace\",\"Parasitic\",\"Primitively Eusocial\",\"Wrong upstream, confirmed at source — not a cuckoo, and not close.\"")
   (check-equal? (read-drift-rows corrections upstream parasites) '()
                 "quoted prose with commas and dashes does not derail the comparison")

   ;; upstream changed underneath the correction
   (corrections! "\"bombus vosnesenskii\",\"sociality\",\"replace\",\"Solitary\",\"Primitively Eusocial\",\"why\"")
   (define moved (read-drift-rows corrections upstream parasites))
   (check-equal? (length moved) 1)
   (check-equal? (drift-expected (car moved)) "Solitary")
   (check-equal? (drift-actual (car moved)) "Parasitic"
                 "drift reports what upstream says NOW")
   (check-equal? (drift-class (car moved)) 'contested)

   ;; upstream ADOPTED the correction: it now says exactly what we publish. Read as
   ;; resolved off real CSVs, not just in the pure classifier.
   (corrections! "\"osmia lignaria\",\"sociality\",\"replace\",\"Parasitic\",\"Solitary\",\"why\"")
   (define adopted (read-drift-rows corrections upstream parasites))
   (check-equal? (length adopted) 1)
   (check-equal? (drift-class (car adopted)) 'resolved)
   (check-false (drift-blocking? (car adopted))
                "the build does not stop because a correction came true")

   ;; THE CASE THE SQL SIDE CANNOT SEE: a correction for a species with no upstream
   ;; row silently drops out of species_traits — nothing to override — so only this
   ;; gate can notice it. Upstream knows no such species, so it reads as ORPHANED
   ;; (check the key) rather than as upstream having withdrawn the assertion.
   (corrections! "\"bombus nonesuch\",\"nesting\",\"retract\",\"Host Nest\",\"\",\"typo in the key\"")
   (define orphan (read-drift-rows corrections upstream parasites))
   (check-equal? (length orphan) 1)
   (check-equal? (drift-actual (car orphan)) ""
                 "a correction naming a nonexistent upstream row is drift, not silence")
   (check-false (drift-key-known (car orphan))
                "…and the key-presence join is what says so")
   (check-equal? (drift-class (car orphan)) 'orphaned)

   ;; a trait column the gate does not know about compares as "" and surfaces rather
   ;; than passing quietly — as UNCHECKED, which blocks: nothing verified it.
   (corrections! "\"osmia lignaria\",\"wingspan\",\"replace\",\"12mm\",\"11mm\",\"why\"")
   (define unknown-trait (read-drift-rows corrections upstream parasites))
   (check-equal? (length unknown-trait) 1
                 "an unrecognized trait column drifts rather than silently passing")
   (check-true (drift-blocking? (car unknown-trait)))

   ;; …and it surfaces even when the expectation compares EQUAL, since "equal" there
   ;; is only the gate agreeing with itself about a column it never read.
   (corrections! "\"osmia lignaria\",\"wingspan\",\"replace\",\"\",\"11mm\",\"why\"")
   (check-equal? (map drift-class (read-drift-rows corrections upstream parasites))
                 '(unchecked)
                 "an empty expectation on an unknown trait must not pass as agreement")

   ;; host_bees resolves against the PARASITE seed, aggregated exactly as
   ;; species_traits.sql aggregates it — a second upstream source, so the
   ;; comparison cannot just look at one file.
   (corrections! "\"nomada bella\",\"host_bees\",\"retract\",\"Andrena, Andrena imitatrix\",\"\",\"why\"")
   (check-equal? (read-drift-rows corrections upstream parasites) '()
                 "a host_bees expectation matches the aggregated parasite seed, not the trait seed")

   (corrections! "\"nomada bella\",\"host_bees\",\"retract\",\"Andrena\",\"\",\"why\"")
   (check-equal? (length (read-drift-rows corrections upstream parasites)) 1
                 "…and a partial expectation drifts: the AGGREGATE is what the mart publishes")

   (check-false (read-drift-rows (build-path tmp "absent.csv") upstream parasites)
                "an unreadable seed yields #f — distinguishable from 'nothing drifted'")

   (delete-directory/files tmp)])
