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

(define-values (ok-drift note-drift)
  (drift-verdict (list (drift "bombus vosnesenskii" "sociality" "Parasitic" "Solitary"))))
(check-false ok-drift
             "real drift FAILS: continuing to override a fixed record would reintroduce the error")
(check-true (and (string-contains? note-drift "bombus vosnesenskii")
                 (string-contains? note-drift "Parasitic")
                 (string-contains? note-drift "Solitary"))
            "…naming the record and both values, so the operator can judge it")

(define-values (_ok note-gone)
  (drift-verdict (list (drift "bombus nonesuch" "nesting" "Host Nest" ""))))
(check-true (string-contains? note-gone "<no row>")
            "an upstream row that vanished reads as such, not as an empty string")

;; --- the reader, against real CSVs ---------------------------------------------------

(cond
  [(not (find-executable-path "duckdb"))
   (printf "corrections-drift-test: reader SKIPPED — needs duckdb\n")]
  [else
   (define tmp (make-temporary-file "stelis-drift-~a" 'directory))
   (define upstream (build-path tmp "upstream.csv"))
   (define corrections (build-path tmp "corrections.csv"))
   (display-to-file
    (string-join
     '("canonical_name,native,nesting,sociality,foraging"
       "\"bombus vosnesenskii\",\"native\",\"Host Nest\",\"Parasitic\",\"Generalist\""
       "\"osmia lignaria\",\"native\",\"Cavity\",\"Solitary\",\"Generalist\"") "\n")
    upstream #:exists 'replace)

   (define (corrections! . rows)
     (display-to-file
      (string-join (cons "canonical_name,trait,action,expected_upstream,corrected_value,reason" rows) "\n")
      corrections #:exists 'replace))

   ;; matching expectation: no drift
   (corrections! "\"bombus vosnesenskii\",\"sociality\",\"replace\",\"Parasitic\",\"Primitively Eusocial\",\"why\"")
   (check-equal? (read-drift-rows corrections upstream) '()
                 "a correction whose expected value still matches upstream is not drift")

   ;; the reason prose contains commas and an em dash — the parse must survive it
   (corrections! "\"bombus vosnesenskii\",\"sociality\",\"replace\",\"Parasitic\",\"Primitively Eusocial\",\"Wrong upstream, confirmed at source — not a cuckoo, and not close.\"")
   (check-equal? (read-drift-rows corrections upstream) '()
                 "quoted prose with commas and dashes does not derail the comparison")

   ;; upstream changed underneath the correction
   (corrections! "\"bombus vosnesenskii\",\"sociality\",\"replace\",\"Solitary\",\"Primitively Eusocial\",\"why\"")
   (define moved (read-drift-rows corrections upstream))
   (check-equal? (length moved) 1)
   (check-equal? (drift-expected (car moved)) "Solitary")
   (check-equal? (drift-actual (car moved)) "Parasitic"
                 "drift reports what upstream says NOW")

   ;; THE CASE THE SQL SIDE CANNOT SEE: a correction for a species with no upstream
   ;; row silently drops out of species_traits — nothing to override — so only this
   ;; gate can notice it.
   (corrections! "\"bombus nonesuch\",\"nesting\",\"retract\",\"Host Nest\",\"\",\"typo in the key\"")
   (define orphan (read-drift-rows corrections upstream))
   (check-equal? (length orphan) 1)
   (check-equal? (drift-actual (car orphan)) ""
                 "a correction naming a nonexistent upstream row is drift, not silence")

   ;; a trait column the gate does not know about compares as "" and surfaces rather
   ;; than passing quietly
   (corrections! "\"osmia lignaria\",\"wingspan\",\"replace\",\"12mm\",\"11mm\",\"why\"")
   (check-equal? (length (read-drift-rows corrections upstream)) 1
                 "an unrecognized trait column drifts rather than silently passing")

   (check-false (read-drift-rows (build-path tmp "absent.csv") upstream)
                "an unreadable seed yields #f — distinguishable from 'nothing drifted'")

   (delete-directory/files tmp)])
