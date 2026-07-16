#lang racket/base

;; Tests for the build-trace RECORD shape (trace.rkt, st-yg7.4/st-sds): the
;; datum round trip history.rkt persists through, then an end-to-end run-plan
;; over a synthetic graph with a no-op runtime — real subprocesses, real cache —
;; whose records carry the decisions, deltas, and output observations the build
;; actually produced. (Storage moved to history.rkt; see history-test.rkt.)

(require rackunit
         racket/file
         "model.rkt"
         "cache.rkt"
         "exec.rkt"
         "trace.rkt")

(define tmp (make-temporary-file "stelis-trace-test-~a" 'directory))

;; --- record datum round trip -------------------------------------------------

(define some-records
  (list (trace-record 'ingest (decision 'run 'boundary '()) #f 'ok '()
                      (output-delta 'identical '(raw)) '((raw . "r0")) '())
        (trace-record 'xform  (decision 'run 'input-changed '(raw))
                      (snapshot "r1" (hash 'raw "abc123")) 'failed '()
                      (output-delta 'changed '(out)) '() '())
        ;; a 'dir-producing record carries its per-key layer alongside the digest
        (trace-record 'maps   (decision 'run 'input-changed '(taxa))
                      (snapshot "r2" (hash 'taxa "t0")) 'ok '() #f
                      '((species-maps . "d0"))
                      '((species-maps . (("genus/Bombus.svg" . "h1")
                                         ("genus/Apis.svg"   . "h2")))))
        (trace-record 'load   (decision 'skip 'cached '()) #f 'skipped '(xform) #f '() '())
        (trace-record 'no-cache #f #f 'ok '() #f '((out . "o9")) '())))

;; datum->trace-record ∘ trace-record->datum = identity, across every field
;; shape (decisions, snapshots, deltas, and #f alike, plus the observations)
(for ([r (in-list some-records)])
  (check-equal? (datum->trace-record (trace-record->datum r)) r
                "a record survives serialization unchanged"))

;; and the datum is genuinely `read'-able (the property history relies on to
;; store one build per line)
(let ([r (car some-records)])
  (check-equal? (datum->trace-record
                 (read (open-input-string
                        (let ([o (open-output-string)])
                          (write (trace-record->datum r) o)
                          (get-output-string o)))))
                r
                "the datum round-trips through write/read"))

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

;; the observation: a task that ran records its derived outputs' hashes
(check-equal? (map car (trace-record-output-hashes (cadr records1))) '(out)
              "the noop task observed its `out' output")
(check-equal? (trace-record-output-key-hashes (cadr records1)) '()
              "a file-only task has no per-key layer")

(define-values (status2 records2)
  (run-plan g '(ingest noop) runtimes #:context benv))
(check-equal? (hash-ref status2 'noop) 'cached
              "second build: unchanged inputs skip as cached")
(check-equal? (trace-record-decision (cadr records2))
              (decision 'skip 'cached '())
              "and the record says why")
(check-equal? (trace-record-output-hashes (cadr records2)) '()
              "a cached task re-observes nothing — no new timeline point")
(check-equal? (trace-record-delta (car records2))
              (output-delta 'identical '(raw))
              "a boundary rerun to identical content still gets a cutoff receipt")

(delete-directory/files tmp)
