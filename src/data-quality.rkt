#lang racket/base

;; Data-quality rules that run as in-process build nodes (st-0vz) — the operator
;; half of the roadmap's "data-quality Datalog" line. The reusable investment is
;; the rule-NODE modality (exec.rkt's `rule-check`): a rule evaluated in Racket as
;; a graph node, gating its downstream. This module supplies the FIRST rule — the
;; integrity gate.
;;
;; A note on "Datalog": the integrity check is a count-delta, which is ARITHMETIC,
;; and the `datalog' package is pure Datalog with no arithmetic — so this rule's
;; logic is plain Racket, not a Datalog theory. That's honest: the rule-node
;; mechanism is what the Datalog work needs, and the first genuinely RELATIONAL
;; rule-sets (the editorial checks, st-8v3) are what will assert into a theory.
;;
;; The flags-vs-gates split, the history-relative gate, and the Datalog/DuckDB
;; boundary are recorded in docs/adr/0006-data-quality-flags-vs-gates.md.
;;
;; INTEGRITY GATE: a build whose observed record count for a relation deviates
;; sharply from the PREVIOUS build's (history.rkt) is a pipeline-integrity alarm —
;; a source broke, a join exploded or collapsed — and should BLOCK before the data
;; is published. This is an OPERATOR concern, distinct from editorial flags (which
;; annotate records for end users and never block). It consults the build SEQUENCE
;; (this build vs. last) — legitimately, because it's an anomaly alarm, never a
;; freshness verdict (ADR 0005: freshness stays content-hash + graph, clockless).

(require racket/list
         racket/string
         "history.rkt"
         "exec.rkt")   ; check-context accessors — the rule-node interface

(provide parts->rowcount
         previous-count
         integrity-verdict
         make-integrity-check)

;; parts->rowcount : (listof (cons string string)) -> (or/c exact-nonnegative-integer #f)
;; Total rows across a relation's per-part observation: the sum of its row-count
;; ("<schema>.<table>.*") parts (relation-digest.rkt records one per table). #f
;; when there are none — the relation carries no rowcount layer.
(define (parts->rowcount parts)
  (define counts
    (for*/list ([p (in-list parts)]
                #:when (string-suffix? (car p) ".*")
                [n (in-value (string->number (cdr p)))]
                #:when (exact-nonnegative-integer? n))
      n))
  (and (pair? counts) (apply + counts)))

;; previous-count : path-string symbol -> (or/c exact-nonnegative-integer #f)
;; The relation's total row count at the most recent build that observed it, or #f
;; when the history has no observation of it yet (first build / never produced).
;; This is the gate's baseline; reading it is the second present-tense consumer of
;; the st-sds observation history.
(define (previous-count state-dir relation)
  (and state-dir   ; no state-dir (e.g. --verify's runner) -> no baseline
       (let ([obs (history-key-observations state-dir relation)])
         (and (pair? obs) (parts->rowcount (key-observation-keys (last obs)))))))

;; integrity-verdict : symbol (or/c integer #f) (or/c integer #f) real
;;                     -> (values boolean string)
;; The pure rule: given the current and previous record counts and a fractional
;; threshold (0.5 = 50%), does the relation pass? PASS (#t) when there is no
;; baseline yet (nothing to compare), when the baseline was 0 (any growth from
;; empty is fine), or when the relative change is within threshold. FAIL (#f) only
;; on a change beyond threshold. An unreadable CURRENT count passes with a warning,
;; not a block: the check has no anomaly signal, and the codebase degrades on an
;; unreadable read (duckdb.rkt's #f-on-absence) rather than halting a pipeline on
;; what is almost always transient infra (the producing loader already succeeded).
(define (integrity-verdict relation cur prev threshold)
  (cond
    [(not cur)
     (values #t (format "~a: current record count unreadable — integrity NOT checked" relation))]
    [(not prev)
     (values #t (format "~a: ~a rows (no baseline yet)" relation cur))]
    [(zero? prev)
     (values #t (format "~a: ~a rows (baseline was 0)" relation cur))]
    [else
     (define change (/ (abs (- cur prev)) prev))
     (if (> change threshold)
         (values #f (format "~a: ~a → ~a rows — ~a% change exceeds ~a% threshold"
                            relation prev cur (pct change) (pct threshold)))
         (values #t (format "~a: ~a → ~a rows (~a% change, within ~a%)"
                            relation prev cur (pct change) (pct threshold))))]))

;; make-integrity-check : symbol (-> (or/c integer #f)) real
;;                        -> (check-context -> (values boolean string))
;; Build the rule-node body for `relation': read its CURRENT count via
;; `current-count' (a thunk closing over the db, supplied by the graph author),
;; its PREVIOUS count from the history at the run's state-dir, and apply the pure
;; verdict. The result is exactly the `rule-check' `run' exec.rkt expects.
(define (make-integrity-check relation current-count threshold)
  (lambda (ctx)
    (integrity-verdict relation
                       (current-count)
                       (previous-count (check-context-state-dir ctx) relation)
                       threshold)))

;; pct : exact rational -> string — a change fraction as a rounded whole percent
(define (pct x) (number->string (round (* 100 (exact->inexact x)))))
