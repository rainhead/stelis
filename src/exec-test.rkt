#lang racket/base

;; End-to-end early cutoff (st-8ig), over a synthetic two-task chain with real
;; subprocesses:   raw (external file) -> derive -> mid -> pack -> out
;;
;; `derive' copies only raw's FIRST byte into mid, so a change to raw's tail
;; reruns derive but rebuilds mid to identical content — and pack, deciding
;; AFTER derive ran, sees unchanged inputs and cache-skips. That is the whole
;; cutoff mechanism; these tests pin it, plus the receipts (output deltas) that
;; land on the trace records.

(require rackunit
         racket/file
         racket/port
         "model.rkt"
         "cache.rkt"
         "exec.rkt"
         "trace.rkt")

(define tmp (make-temporary-file "stelis-exec-test-~a" 'directory))
(define raw-path (build-path tmp "raw.txt"))
(define mid-path (build-path tmp "mid.txt"))
(define out-path (build-path tmp "out.txt"))

(define runtimes (hash 'sh (runtime 'sh '("/bin/sh" "-c") "sh")))
(define (sh fmt . args) (recipe 'sh (list (apply format fmt args))))

(define g
  (build-graph
   (list (make-task 'derive 'transform #:inputs '(raw) #:outputs '(mid)
                    #:invoke (sh "head -c 1 ~a > ~a" raw-path mid-path))
         (make-task 'pack   'transform #:inputs '(mid) #:outputs '(out)
                    #:invoke (sh "cat ~a ~a > ~a" mid-path mid-path out-path)))
   (list (make-artifact 'raw 'file) (make-artifact 'mid 'file)
         (make-artifact 'out 'file))))

(define benv
  (build-env (lambda (a export-dir)
               (case a [(raw) raw-path] [(mid) mid-path] [(out) out-path] [else #f]))
             tmp
             (build-path tmp "cache")))

;; run-plan narrates to stdout; the tests only want the returned facts
(define (build!)
  (parameterize ([current-output-port (open-output-nowhere)])
    (define-values (status records) (run-plan g '(derive pack) runtimes #:context benv))
    (cons status records)))
(define (status-of r name) (hash-ref (car r) name))
(define (record-of r name)
  (findf (lambda (rec) (eq? name (trace-record-task rec))) (cdr r)))

;; --- first build: everything runs; no prior entries, so no deltas -------------

(display-to-file "AB" raw-path)
(define b1 (build!))
(check-equal? (status-of b1 'derive) 'ok "first build: derive runs")
(check-equal? (status-of b1 'pack)   'ok "first build: pack runs")
(check-false (trace-record-delta (record-of b1 'derive))
             "no previous build — nothing to compare outputs against")

;; --- nothing changed: plain input-addressed skips, no cutoff needed -----------

(define b2 (build!))
(check-equal? (status-of b2 'derive) 'cached "unchanged inputs skip")
(check-equal? (status-of b2 'pack)   'cached "unchanged inputs skip")

;; --- the acceptance case: raw changes, derive rebuilds mid IDENTICALLY --------

(display-to-file "AC" raw-path #:exists 'replace) ; first byte — mid's content — unchanged
(define b3 (build!))
(check-equal? (trace-record-decision (record-of b3 'derive))
              (decision 'run 'input-changed '(raw))
              "the changed input forces derive to rerun")
(check-equal? (status-of b3 'derive) 'ok "derive reran")
(check-equal? (trace-record-delta (record-of b3 'derive))
              (output-delta 'identical '(mid))
              "…and the receipt says it rebuilt mid to identical content")
(check-equal? (status-of b3 'pack) 'cached
              "EARLY CUTOFF: downstream saw unchanged inputs and skipped")
(check-equal? (trace-record-decision (record-of b3 'pack))
              (decision 'skip 'cached '())
              "pack's own record says why")

;; --- a change that really propagates is not cut off ---------------------------

(display-to-file "ZC" raw-path #:exists 'replace) ; now the first byte differs
(define b4 (build!))
(check-equal? (trace-record-delta (record-of b4 'derive))
              (output-delta 'changed '(mid))
              "a real content change is named in the delta")
(check-equal? (status-of b4 'pack) 'ok "…and propagation resumes downstream")
(check-equal? (trace-record-delta (record-of b4 'pack))
              (output-delta 'changed '(out))
              "the downstream rebuild changed its output too")

(delete-directory/files tmp)
