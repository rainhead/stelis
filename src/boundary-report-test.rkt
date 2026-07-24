#lang racket/base

;; A 'boundary loader's source report (st-8bj), end to end over real subprocesses.
;; A boundary task can probe its external source and short-circuit without
;; re-ingesting; when it does, it writes what it concluded to the receipt path
;; Stelis hands it in STELIS_BOUNDARY_RECEIPT. run-plan reads that back onto the
;; trace record, so --explain/--why can say WHY the boundary didn't re-ingest.
;;
;; Three boundaries pin the three cases: a loader that reports (valid receipt), one
;; that stays silent (no receipt — re-ingested, or not a probing loader), and one
;; that writes garbage (unparseable → treated as silent, never an error). Then the
;; rendering + the prospective, history-flavored boundary line.

(require rackunit
         racket/file
         racket/port
         "model.rkt"
         "cache.rkt"
         "exec.rkt"
         "trace.rkt"
         "explain.rkt"
         "history.rkt"
         "delta-explain.rkt")

(define tmp (make-temporary-file "stelis-boundary-test-~a" 'directory))
(define good-out   (build-path tmp "good.txt"))
(define silent-out (build-path tmp "silent.txt"))
(define bad-out    (build-path tmp "bad.txt"))
(define noflag-out (build-path tmp "noflag.txt"))

(define runtimes (hash 'sh (runtime 'sh '("/bin/sh" "-c") "sh")))
(define (sh fmt . args) (recipe 'sh (list (apply format fmt args))))

;; each boundary writes its output; `good' and `bad' also touch the receipt
(define g
  (build-graph
   (list (make-task 'good 'boundary #:outputs '(good-a)
                    #:invoke (sh "echo x > ~a; printf '%s' '{\"unchanged\": true, \"records\": 0, \"since\": \"2026-07-20\"}' > \"$STELIS_BOUNDARY_RECEIPT\"" good-out))
         (make-task 'silent 'boundary #:outputs '(silent-a)
                    #:invoke (sh "echo x > ~a" silent-out))
         (make-task 'bad 'boundary #:outputs '(bad-a)
                    #:invoke (sh "echo x > ~a; printf 'not json' > \"$STELIS_BOUNDARY_RECEIPT\"" bad-out))
         ;; a receipt that omits the required `unchanged' key: valid JSON, but not a
         ;; valid report → #f (not read as a changed-source report by default)
         (make-task 'noflag 'boundary #:outputs '(noflag-a)
                    #:invoke (sh "echo x > ~a; printf '%s' '{\"records\": 5}' > \"$STELIS_BOUNDARY_RECEIPT\"" noflag-out)))
   (list (make-artifact 'good-a 'file) (make-artifact 'silent-a 'file)
         (make-artifact 'bad-a 'file) (make-artifact 'noflag-a 'file))))

(define benv
  (make-build-env (lambda (a _dir)
                    (case a [(good-a) good-out] [(silent-a) silent-out]
                            [(bad-a) bad-out] [(noflag-a) noflag-out] [else #f]))
                  tmp (build-path tmp "cache")))

(define state (build-path tmp ".stelis"))

(define (build!)
  (parameterize ([current-output-port (open-output-nowhere)])
    (define-values (status records)
      (run-plan g '(good silent bad noflag) runtimes #:context benv #:state-dir state))
    records))
(define (record-of recs name)
  (findf (lambda (r) (eq? name (trace-record-task r))) recs))

;; --- the capture: a reporting boundary lands its report on the trace -----------

(define recs (build!))

(check-equal? (trace-record-source-report (record-of recs 'good))
              (source-report #t 0 "2026-07-20")
              "the loader's receipt is read back onto the trace record")

(check-false (trace-record-source-report (record-of recs 'silent))
             "a boundary that writes no receipt reports nothing (#f)")

(check-false (trace-record-source-report (record-of recs 'bad))
             "an unparseable receipt is treated as silent, not an error")

(check-false (trace-record-source-report (record-of recs 'noflag))
             "valid JSON missing the required `unchanged' key is not a report")

;; a stale receipt from a prior run must not be misread as this run's: `silent'
;; never writes one, so even after `good'/`bad' wrote theirs it stays #f across a
;; second build (each task's receipt is cleared before it runs).
(check-false (trace-record-source-report (record-of (build!) 'silent))
             "the receipt is per-task and cleared each run — no cross-contamination")

;; --- rendering (pure) ----------------------------------------------------------

(check-equal? (source-report->string (source-report #t 0 "2026-07-20"))
              "source unchanged — ingestion skipped, 0 new records since 2026-07-20")
(check-equal? (source-report->string (source-report #t #f #f))
              "source unchanged — ingestion skipped"
              "records/since are shown only when the loader gave them")
(check-equal? (source-report->string (source-report #f 12 #f))
              "source changed — re-ingested, 12 new records")

;; --- prospective, history-flavored boundary line -------------------------------
;; persist the build (run-plan returns records; main.rkt is what appends them to
;; history — mirror that here) so the report has a home to be read back from.
;; make-reason->string should then flavor a boundary decision for `good' with it,
;; and leave `silent' (no report) plain.

(void (history-append! state 'all g "0" recs))

(define reason->string (make-reason->string g benv state))
(define bdec (decision 'run 'boundary '()))

(check-true (regexp-match? #rx"last run: source unchanged" (reason->string 'good bdec))
            "the prospective boundary line reads the task's last recorded report")
(check-false (regexp-match? #rx"last run" (reason->string 'silent bdec))
             "a boundary that never reported gets the plain line")
(check-false (regexp-match? #rx"last run" (reason->string 'never-built bdec))
             "an unknown task gets the plain line")

;; history-last-source-report reads the last RUN's report, skipping a later build
;; where the task was blocked/skipped (wrote no receipt) — that must not mask the
;; genuinely-last report. Hand-build two states: an older build where `probe' ran
;; with a report, then a newer build where it was 'skipped (outcome, report #f).
(define hstate (build-path tmp ".stelis-h"))
(define hg (build-graph (list (make-task 'probe 'boundary #:outputs '(p-a)))
                        (list (make-artifact 'p-a 'file))))
(void (history-append! hstate 'all hg "0"
                       (list (trace-record 'probe (decision 'run 'boundary '()) #f
                                           'ok '() #f '() '() '()
                                           (source-report #t 0 "2026-07-01")))))
(void (history-append! hstate 'all hg "1"
                       (list (trace-record 'probe (decision 'run 'boundary '()) #f
                                           'skipped '(up) #f '() '() '() #f))))
(check-equal? (history-last-source-report hstate 'probe)
              (source-report #t 0 "2026-07-01")
              "a later skipped build doesn't mask the last actual run's report")

(delete-directory/files tmp)
