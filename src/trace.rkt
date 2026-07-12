#lang racket/base

;; The build trace (st-yg7.4): what a real --build actually decided and did.
;;
;; Slices 1–3 explain a HYPOTHETICAL build ("what would run right now?"); the
;; trace records the last actual one, so "--explain --last" can answer "why DID
;; that rebuild?" without re-fingerprinting a world that has since moved on.
;;
;; Same rules as the cache sidecars: DERIVED, DISPOSABLE state under .stelis/,
;; format-VERSIONED — an unreadable or other-version trace loads as #f (no
;; trace), never an error. This is deliberately the thin end of Horizon 1
;; trace/graph persistence: one file, the last build only; the fuller
;; persistence work (st-sds) should adopt the record shape, not replace it.

(require racket/file
         "cache.rkt")

(provide (struct-out trace-record)
         trace-store!
         trace-load)

(define TRACE-VERSION 1)

;; One task's actual fate in a build.
;;   task     : symbol
;;   decision : (or/c decision? #f) — the pre-run decision; #f when caching was off
;;   outcome  : 'ok | 'cached | 'failed | 'skipped
;;   blockers : (listof symbol) — for 'skipped: the failed/skipped producers
(struct trace-record (task decision outcome blockers) #:transparent)

;; decisions serialize as plain lists — transparent structs don't `read' back
(define (decision->datum d)
  (and d (list (decision-verdict d) (decision-reason d) (decision-details d))))
(define (datum->decision v)
  (and (list? v) (= 3 (length v)) (decision (car v) (cadr v) (caddr v))))

(define (trace-file state-dir) (build-path state-dir "last-build.rktd"))

;; trace-store! : path-string symbol (listof trace-record?) -> void
(define (trace-store! state-dir target records)
  (make-directory* state-dir)
  (call-with-output-file (trace-file state-dir) #:exists 'replace
    (lambda (o)
      (write (hash 'version TRACE-VERSION
                   'target target
                   'records (for/list ([r (in-list records)])
                              (list (trace-record-task r)
                                    (decision->datum (trace-record-decision r))
                                    (trace-record-outcome r)
                                    (trace-record-blockers r))))
             o))))

;; trace-load : path-string -> (or/c (cons symbol (listof trace-record?)) #f)
;; The recorded target and its records in build order; #f when there is no
;; usable trace (missing, unparseable, or other-version — all alike).
(define (trace-load state-dir)
  (define f (trace-file state-dir))
  (and (file-exists? f)
       (let ([e (with-handlers ([exn:fail? (lambda (_) #f)])
                  (call-with-input-file f read))])
         (and (hash? e)
              (equal? (hash-ref e 'version #f) TRACE-VERSION)
              (list? (hash-ref e 'records #f))
              (with-handlers ([exn:fail? (lambda (_) #f)])
                (cons (hash-ref e 'target)
                      (for/list ([r (in-list (hash-ref e 'records))])
                        (trace-record (car r) (datum->decision (cadr r))
                                      (caddr r) (cadddr r)))))))))
