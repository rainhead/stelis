#lang racket/base

;; Tests for the build trace (trace.rkt, st-yg7.4): the store/load round trip
;; and its graceful-degradation contract, then an end-to-end run-plan over a
;; synthetic graph with a no-op runtime — real subprocesses, real cache — whose
;; records land in the trace exactly as the build behaved.

(require rackunit
         racket/file
         "model.rkt"
         "cache.rkt"
         "exec.rkt"
         "trace.rkt")

(define tmp (make-temporary-file "stelis-trace-test-~a" 'directory))

;; --- round trip and degradation ----------------------------------------------

(define some-records
  (list (trace-record 'ingest (decision 'run 'boundary '()) 'ok '())
        (trace-record 'xform  (decision 'run 'input-changed '(raw)) 'failed '())
        (trace-record 'load   (decision 'skip 'cached '()) 'skipped '(xform))
        (trace-record 'no-cache #f 'ok '())))

(trace-store! tmp 'occurrences.db some-records)
(check-equal? (trace-load tmp) (cons 'occurrences.db some-records)
              "records round-trip, decisions and #f alike")

(display-to-file "not a hash" (build-path tmp "last-build.rktd") #:exists 'replace)
(check-false (trace-load tmp) "an unparseable trace loads as no-trace")
(call-with-output-file (build-path tmp "last-build.rktd") #:exists 'replace
  (lambda (o) (write (hash 'version 999 'target 'x 'records '()) o)))
(check-false (trace-load tmp) "an other-version trace loads as no-trace")
(check-false (trace-load (build-path tmp "nowhere")) "a missing trace is no-trace")

;; --- run-plan produces the records --------------------------------------------

;; ingest(boundary) -> raw -> noop -> out, with `true' as the hermetic command:
;; a real subprocess that does nothing. `out' is pre-created so the second run
;; can be a genuine cache hit.
(define g
  (build-graph
   (list (make-task 'ingest 'boundary  #:outputs '(raw)
                    #:invoke (recipe 'sh '()))
         (make-task 'noop   'transform #:inputs '(raw) #:outputs '(out)
                    #:invoke (recipe 'sh '())))
   (list (make-artifact 'raw 'file) (make-artifact 'out 'file))))
(define runtimes (hash 'sh (runtime 'sh '("true") "sh")))

(define raw-path (build-path tmp "raw.csv"))
(define out-path (build-path tmp "out.db"))
(define cache-dir (build-path tmp "cache"))
(display-to-file "a,b\n" raw-path)
(display-to-file "bytes" out-path)
(define (resolve a export-dir) (case a [(raw) raw-path] [(out) out-path] [else #f]))

(define-values (status1 records1)
  (run-plan g '(ingest noop) runtimes
            #:resolve resolve #:export-dir tmp #:cache-dir cache-dir))
(check-equal? status1 (make-hash '((ingest . ok) (noop . ok)))
              "first build: both tasks run and succeed")
(check-equal? (map (lambda (r) (apply trace-record r)) records1)
              (list (trace-record 'ingest (decision 'run 'boundary '()) 'ok '())
                    (trace-record 'noop (decision 'run 'no-cache-entry '()) 'ok '()))
              "first build's records: the boundary and a first-sight miss")

(define-values (status2 records2)
  (run-plan g '(ingest noop) runtimes
            #:resolve resolve #:export-dir tmp #:cache-dir cache-dir))
(check-equal? (hash-ref status2 'noop) 'cached
              "second build: unchanged inputs skip as cached")
(check-equal? (cadr (assq 'noop (map (lambda (r) (cons (car r) (cdr r))) records2)))
              (decision 'skip 'cached '())
              "and the record says why")

;; the records persist and reload as stored
(trace-store! tmp 'out (map (lambda (r) (apply trace-record r)) records2))
(let ([tr (trace-load tmp)])
  (check-equal? (car tr) 'out "the trace names its target")
  (check-equal? (map trace-record-outcome (cdr tr)) '(ok cached)
                "outcomes survive the round trip"))

(delete-directory/files tmp)
