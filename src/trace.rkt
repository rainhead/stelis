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
         outcome-glyph
         trace-store!
         trace-load)

;; v3: records carry the post-run output delta (st-8ig), so the trace can name
;; the cutoff point — "reran, outputs identical, downstream skipped".
(define TRACE-VERSION 3)

;; One task's actual fate in a build.
;;   task     : symbol
;;   decision : (or/c decision? #f) — the pre-run decision; #f when caching was off
;;   snapshot : (or/c snapshot? #f) — the fingerprints behind it; #f when the
;;              task wasn't content-addressable (or caching was off)
;;   outcome  : 'ok | 'cached | 'failed | 'skipped
;;   blockers : (listof symbol) — for 'skipped: the failed/skipped producers
;;   delta    : (or/c output-delta? #f) — for 'ok: how the rebuilt outputs
;;              compare to the previous build's; #f when there was no basis
(struct trace-record (task decision snapshot outcome blockers delta) #:transparent)

;; outcome-glyph : symbol -> string — the one legend for actual outcomes.
(define (outcome-glyph o)
  (case o [(ok) "✓"] [(cached) "≡"] [(failed) "✗"] [(skipped) "⊘"]))

;; decisions and snapshots serialize as plain lists — transparent structs
;; don't `read' back
(define (decision->datum d)
  (and d (list (decision-verdict d) (decision-reason d) (decision-details d))))
(define (datum->decision v)
  (and (list? v) (= 3 (length v)) (decision (car v) (cadr v) (caddr v))))

(define (snapshot->datum s)
  (and s (list (snapshot-recipe-hash s)
               (sort (hash->list (snapshot-input-hashes s)) symbol<? #:key car))))
(define (datum->snapshot v)
  (and (list? v) (= 2 (length v))
       (snapshot (car v) (make-immutable-hash (cadr v)))))

(define (delta->datum d)
  (and d (list (output-delta-status d) (output-delta-details d))))
(define (datum->delta v)
  (and (list? v) (= 2 (length v)) (output-delta (car v) (cadr v))))

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
                                    (snapshot->datum (trace-record-snapshot r))
                                    (trace-record-outcome r)
                                    (trace-record-blockers r)
                                    (delta->datum (trace-record-delta r)))))
             o))))

;; trace-load : path-string -> (or/c (cons symbol (listof trace-record?)) #f)
;; The recorded target and its records in build order; #f when there is no
;; usable trace (missing, unparseable, or other-version — all alike).
(define (trace-load state-dir)
  (define e (read-versioned (trace-file state-dir) TRACE-VERSION))
  (and e
       (list? (hash-ref e 'records #f))
       (with-handlers ([exn:fail? (lambda (_) #f)])
         (cons (hash-ref e 'target)
               (for/list ([r (in-list (hash-ref e 'records))])
                 (trace-record (car r)
                               (datum->decision (cadr r))
                               (datum->snapshot (caddr r))
                               (cadddr r)
                               (list-ref r 4)
                               (datum->delta (list-ref r 5))))))))
