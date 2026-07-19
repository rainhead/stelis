#lang racket/base

;; The build-trace RECORD shape (st-yg7.4): what a real --build actually decided
;; and did, per task.
;;
;; Slices 1–3 explain a HYPOTHETICAL build ("what would run right now?"); a
;; trace records the last actual one, so "--explain --last" can answer "why DID
;; that rebuild?" without re-fingerprinting a world that has since moved on.
;;
;; The STORAGE has moved on: st-yg7.4 kept one `last-build.rktd`; st-sds retires
;; that single file into an append-only HISTORY (history.rkt), which is now the
;; sole home of build records — "the last build" is just history's tail. This
;; module keeps only what both stories share: the record STRUCT and its
;; serialization (history.rkt asked to adopt the shape, not reinvent it). The
;; record now carries `output-hashes` — each produced artifact's observed hash —
;; so history can project an observation timeline, not just a decision log.

(require "cache.rkt")

(provide (struct-out trace-record)
         outcome-glyph
         trace-record->datum
         datum->trace-record)

;; One task's actual fate in a build.
;;   task          : symbol
;;   decision      : (or/c decision? #f) — the pre-run decision; #f when caching
;;                   was off
;;   snapshot      : (or/c snapshot? #f) — the fingerprints behind it (this run's
;;                   BASIS: recipe + input hashes); #f when the task wasn't
;;                   content-addressable (or caching was off)
;;   outcome       : 'ok | 'cached | 'failed | 'skipped
;;   blockers      : (listof symbol) — for 'skipped: the failed/skipped producers
;;   delta         : (or/c output-delta? #f) — for 'ok: how the rebuilt outputs
;;                   compare to the previous build's; #f when there was no basis
;;   output-hashes : (listof (cons symbol string)) — the OBSERVATION: each derived
;;                   output artifact's content hash after this run (from
;;                   output-snapshot), sorted; '() when nothing was (re)produced
;;                   (cached/skipped/failed, or a task with no hashable outputs)
;;   output-key-hashes : (listof (cons symbol (listof (cons string string)))) —
;;                   the finer, PER-KEY observation (st-6dv): for each 'dir output,
;;                   its sorted (relative-path -> hash) pairs, so history can time
;;                   which fan-out members changed, not only that the set did. '()
;;                   for a build that produced no 'dir output; empties naturally
;;                   whenever output-hashes does.
;;   input-key-hashes : (listof (cons symbol (listof (cons string string)))) — the
;;                   ingestion-boundary CRUD-snapshot (st-2k9): the per-key map of
;;                   each KEYED STORE input this task consumed (the notes store,
;;                   keyed by canonical_name). Unlike a 'dir/db-relation input —
;;                   whose PRODUCER records its per-key observation as an output — a
;;                   store is a producerless authoritative leaf, so nothing else
;;                   would ever observe it; recording it here gives its per-key
;;                   timeline (and the delta a `from' basis). '() for a task with no
;;                   keyed-store input.
(struct trace-record
  (task decision snapshot outcome blockers delta
   output-hashes output-key-hashes input-key-hashes)
  #:transparent)

;; outcome-glyph : symbol -> string — the one legend for actual outcomes.
(define (outcome-glyph o)
  (case o [(ok) "✓"] [(cached) "≡"] [(failed) "✗"] [(skipped) "⊘"]))

;; --- Record serialization -----------------------------------------------------
;; decisions, snapshots, and deltas are transparent structs — they don't `read'
;; back, so each converts to/from a plain list. Shared by history.rkt, which
;; wraps a build's records in its own versioned envelope; the record datum
;; itself carries no version (the envelope's does).

(define (decision->datum d)
  (and d (list (decision-verdict d) (decision-reason d) (decision-details d))))
(define (datum->decision v)
  (and (list? v) (= 3 (length v)) (decision (car v) (cadr v) (caddr v))))

(define (snapshot->datum s)
  (and s (list (snapshot-recipe-hash s)
               (sort (hash->list (snapshot-input-hashes s)) symbol<? #:key car)
               (sort (hash->list (snapshot-code-hashes s)) string<? #:key car))))
(define (datum->snapshot v)
  (cond
    [(and (list? v) (= 3 (length v)))
     (snapshot (car v) (make-immutable-hash (cadr v))
               (make-immutable-hash (caddr v)))]
    ;; pre-st-top record: no code layer — read it as an empty one, so old
    ;; history builds keep their snapshots (and their derived-from facts)
    [(and (list? v) (= 2 (length v)))
     (snapshot (car v) (make-immutable-hash (cadr v)))]
    [else #f]))

(define (delta->datum d)
  (and d (list (output-delta-status d) (output-delta-details d))))
(define (datum->delta v)
  (and (list? v) (= 2 (length v)) (output-delta (car v) (cadr v))))

;; trace-record->datum : trace-record -> list
;; A record as a plain, `read'-able list — the on-disk shape history persists.
(define (trace-record->datum r)
  (list (trace-record-task r)
        (decision->datum (trace-record-decision r))
        (snapshot->datum (trace-record-snapshot r))
        (trace-record-outcome r)
        (trace-record-blockers r)
        (delta->datum (trace-record-delta r))
        (trace-record-output-hashes r)
        (trace-record-output-key-hashes r)
        (trace-record-input-key-hashes r)))

;; datum->trace-record : any -> trace-record
;; Inverse of trace-record->datum. Assumes a well-formed datum (the caller —
;; history-load — reads inside a handler that drops a malformed build whole).
(define (datum->trace-record r)
  (trace-record (car r)
                (datum->decision (cadr r))
                (datum->snapshot (caddr r))
                (cadddr r)
                (list-ref r 4)
                (datum->delta (list-ref r 5))
                (list-ref r 6)
                (list-ref r 7)
                (list-ref r 8)))
