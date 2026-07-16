#lang racket/base

;; The integrity gate's logic (data-quality.rkt, st-0vz): the pure verdict across
;; its branches, the row-count extraction, and the end-to-end rule body reading a
;; baseline from a real history.

(require rackunit
         racket/file
         "model.rkt"
         "cache.rkt"
         "trace.rkt"
         "history.rkt"
         "exec.rkt"
         "data-quality.rkt")

;; --- parts->rowcount ----------------------------------------------------------

(check-equal? (parts->rowcount '(("s.t.*" . "100")
                                 ("s.t.k" . "abc:100")
                                 ("s.t.v" . "def:90")))
              100 "sums the .* row-count parts, ignores column parts")
(check-equal? (parts->rowcount '(("a.b.*" . "3") ("c.d.*" . "4")))
              7 "a multi-table relation totals its per-table row counts")
(check-false (parts->rowcount '(("s.t.k" . "abc:100")))
             "no .* part -> #f (no rowcount layer)")

;; --- integrity-verdict (pure) -------------------------------------------------

(define-syntax-rule (ok? e) (let-values ([(o _n) e]) o))
(check-true  (ok? (integrity-verdict 'r 100 #f  0.5)) "no baseline -> pass")
(check-true  (ok? (integrity-verdict 'r 100 0   0.5)) "baseline was 0 -> pass")
(check-true  (ok? (integrity-verdict 'r 140 100 0.5)) "40% growth within 50% -> pass")
(check-true  (ok? (integrity-verdict 'r 60  100 0.5)) "40% drop within 50% -> pass")
(check-false (ok? (integrity-verdict 'r 40  100 0.5)) "60% drop exceeds 50% -> FAIL")
(check-false (ok? (integrity-verdict 'r 200 100 0.5)) "100% growth exceeds 50% -> FAIL")
(check-true  (ok? (integrity-verdict 'r #f  100 0.5)) "unreadable current count -> pass (not checked, don't halt on infra)")
;; the note names the drama
(let-values ([(o note) (integrity-verdict 'inat_obs 40 100 0.5)])
  (check-true (regexp-match? #rx"100 → 40" note) "the failure note shows prev → cur"))

;; --- make-integrity-check end to end, over a real history ---------------------

(define tmp (make-temporary-file "stelis-dq-~a" 'directory))
;; a build that observed relation R at 100 rows (via its .* row-count part)
(define g (build-graph
           (list (make-task 'load 'boundary #:outputs '(R)))
           (list (make-artifact 'R 'db-relation))))
(define rec
  (trace-record 'load (decision 'run 'boundary '()) #f 'ok '() #f
                '((R . "digest"))
                '((R . (("s.R.*" . "100"))))))
(void (history-append! tmp 'R g "1000" (list rec)))

;; a check-context carrying that state-dir (graph/task/env unused by this rule)
(define ctx (check-context g 'check #f tmp))

(define (run-with current)
  (ok? ((make-integrity-check 'R (lambda () current) 0.5) ctx)))

(check-true  (run-with 60) "current 60 vs baseline 100 (40% drop) -> pass")
(check-false (run-with 40) "current 40 vs baseline 100 (60% drop) -> FAIL, block")
(check-true  (run-with 150) "current 150 vs baseline 100 (50% growth, == threshold) -> pass")

(check-equal? (previous-count tmp 'R) 100 "previous-count reads the baseline from history")
(check-false (previous-count tmp 'unseen) "an unobserved relation has no baseline")

(delete-directory/files tmp)
