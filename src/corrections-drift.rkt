#lang racket/base

;; Correction drift detection (st-t4t) — the operator half of the correction
;; overlay, and the reason the overlay is allowed to override a cited source.
;;
;; A correction says "upstream says X here, and X is wrong; publish Y instead".
;; Written naively that override is permanent and unexamined: if the upstream
;; source later fixes the record, or changes it to something else entirely, the
;; correction keeps firing and nobody revisits it. Silently rotting override
;; tables are the standard failure mode of this pattern.
;;
;; So each correction records the value it was written AGAINST
;; (`expected_upstream`), and this gate fails the build when upstream stops
;; matching it. That is content-addressing applied to a correction: it is pinned
;; to what it was correcting, not merely to the key it corrects.
;;
;; The split follows what was agreed for st-t4t: beeatlas owns the FIX (a dbt seed
;; and a precedence arm — a per-record override is a bounded join and by ADR
;; 0008's standing gate earns no substrate), Stelis owns the ALARM. This is
;; ADR 0006's operator-gate modality — it blocks publish, unlike an editorial flag.
;;
;; Reads both CSVs through the shared DuckDB CLI rather than hand-parsing: the
;; seeds are quoted CSV with commas and em-dashes inside the reason prose, and a
;; naive split would mis-parse exactly the rows that matter.

(require racket/list
         racket/string
         racket/format
         "duckdb.rkt"
         "exec.rkt")   ; check-context accessors — the rule-node interface

(provide (struct-out drift)
         read-drift-rows
         drift-verdict
         make-corrections-drift-check)

;; One correction whose upstream value no longer matches what it was written for.
;;   key      : string — the corrected record (a canonical_name here)
;;   trait    : string — which column it corrects
;;   expected : string — what upstream said when the correction was written
;;   actual   : string — what upstream says now ("" when the row is gone entirely)
(struct drift (key trait expected actual) #:transparent)

;; read-drift-rows : path-string path-string -> (or/c (listof drift) #f)
;; Every correction whose `expected_upstream` disagrees with the upstream seed.
;; #f — not an empty list — when either file cannot be read, so the caller can
;; tell "nothing has drifted" from "the check could not run".
;;
;; The LEFT JOIN is what catches the case the SQL side cannot: a correction naming
;; a species with no upstream row at all yields actual = "", which drifts against
;; any non-empty expectation. Such a correction silently drops out of
;; species_traits (nothing to override), so without this it would be invisible.
(define (read-drift-rows corrections-path upstream-path)
  (define sql
    (string-append
     "SELECT c.canonical_name, c.trait, coalesce(c.expected_upstream,''),"
     " coalesce(CASE c.trait"
     "   WHEN 'nesting' THEN b.nesting"
     "   WHEN 'sociality' THEN b.sociality"
     "   WHEN 'native' THEN b.native"
     "   WHEN 'foraging' THEN b.foraging END, '')"
     " FROM read_csv_auto('" (~a corrections-path) "') c"
     " LEFT JOIN read_csv_auto('" (~a upstream-path) "') b"
     "   ON b.canonical_name = c.canonical_name"
     " ORDER BY c.canonical_name, c.trait"))
  (define out (duckdb-query #f sql))
  (and out
       (for*/list ([line (in-list (string-split out "\n"))]
                   [tup (in-value (string-split line "|" #:trim? #f))]
                   #:when (and (= 4 (length tup)) (not (string=? (first tup) "")))
                   #:unless (string=? (third tup) (fourth tup)))
         (drift (first tup) (second tup) (third tup) (fourth tup)))))

;; drift-verdict : (or/c (listof drift) #f) -> (values boolean string)
;; The pure rule. PASS when nothing drifted, and pass WITH A WARNING when the
;; check could not run at all (#f) — the codebase's standing choice for an
;; unreadable between-tasks read (duckdb.rkt's #f-on-absence, the integrity
;; gate's unreadable-count arm): degrade rather than halt a pipeline on what is
;; almost always missing infrastructure. FAIL only on real, named drift.
;;
;; A drifted correction is genuinely blocking rather than advisory: if upstream
;; has been fixed, continuing to override it can REINTRODUCE an error, and the
;; published value would then be wrong in the name of correctness.
(define (drift-verdict rows)
  (cond
    [(not rows)
     (values #t "corrections: seeds unreadable — drift NOT checked")]
    [(null? rows)
     (values #t "corrections: every correction still matches its upstream value")]
    [else
     (values #f
             (format "STALE CORRECTION~a: ~a. Upstream no longer says what these corrections were written against — re-check the source and either drop the correction or update expected_upstream."
                     (if (= 1 (length rows)) "" "S")
                     (string-join
                      (for/list ([d (in-list (take rows (min 5 (length rows))))])
                        (format "~a.~a expected ~s, upstream now ~s"
                                (drift-key d) (drift-trait d)
                                (drift-expected d)
                                (if (string=? (drift-actual d) "") "<no row>" (drift-actual d))))
                      "; ")))]))

;; make-corrections-drift-check : path-string path-string
;;                                -> (check-context -> (values boolean string))
;; The `rule-check` body, given the two seed paths. Reads at gate time, not at
;; graph-authoring time, so a seed edited between builds is seen.
(define (make-corrections-drift-check corrections-path upstream-path)
  (lambda (_ctx)
    (drift-verdict (read-drift-rows corrections-path upstream-path))))
