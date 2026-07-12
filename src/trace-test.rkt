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
  (list (trace-record 'ingest (decision 'run 'boundary '()) #f 'ok '()
                      (output-delta 'identical '(raw)))
        (trace-record 'xform  (decision 'run 'input-changed '(raw))
                      (snapshot "r1" (hash 'raw "abc123")) 'failed '()
                      (output-delta 'changed '(out)))
        (trace-record 'load   (decision 'skip 'cached '()) #f 'skipped '(xform) #f)
        (trace-record 'no-cache #f #f 'ok '() #f)))

(trace-store! tmp 'occurrences.db some-records)
(check-equal? (trace-load tmp) (cons 'occurrences.db some-records)
              "records round-trip: decisions, snapshots, and #f alike")

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
(display-to-file "a,b\n" raw-path)
(display-to-file "bytes" out-path)
(define benv
  (make-build-env (lambda (a export-dir)
                    (case a [(raw) raw-path] [(out) out-path] [else #f]))
                  tmp
                  (build-path tmp "cache")))

(define-values (status1 records1)
  (run-plan g '(ingest noop) runtimes #:context benv))
(check-equal? status1 (make-hash '((ingest . ok) (noop . ok)))
              "first build: both tasks run and succeed")
(check-equal? (map trace-record-decision records1)
              (list (decision 'run 'boundary '()) (decision 'run 'no-cache-entry '()))
              "first build's records: the boundary and a first-sight miss")
(check-false (trace-record-snapshot (car records1))
              "a boundary task has no snapshot to record")
(check-pred snapshot? (trace-record-snapshot (cadr records1))
            "a content-addressable task's fingerprints ride in its record")

(define-values (status2 records2)
  (run-plan g '(ingest noop) runtimes #:context benv))
(check-equal? (hash-ref status2 'noop) 'cached
              "second build: unchanged inputs skip as cached")
(check-equal? (trace-record-decision (cadr records2))
              (decision 'skip 'cached '())
              "and the record says why")
(check-equal? (trace-record-delta (car records2))
              (output-delta 'identical '(raw))
              "a boundary rerun to identical content still gets a cutoff receipt")

;; the records persist and reload as stored — snapshots included
(trace-store! tmp 'out records2)
(let ([tr (trace-load tmp)])
  (check-equal? (car tr) 'out "the trace names its target")
  (check-equal? (map trace-record-outcome (cdr tr)) '(ok cached)
                "outcomes survive the round trip")
  (check-equal? (trace-record-snapshot (cadr (cdr tr)))
                (trace-record-snapshot (cadr records2))
                "fingerprints survive the round trip"))

(delete-directory/files tmp)
