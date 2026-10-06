#lang racket/base

;; The IMPURE adapter (st-2hh) that refines a pure 'input-changed decision into a
;; NAMED per-key delta for a PENDING build — the "engine sees the delta" surface
;; of --why / --explain.
;;
;; WHY A SEPARATE MODULE. explain.rkt and cache.rkt's decision->string stay pure:
;; they answer "which INPUT changed?" from fingerprints alone, never touching disk
;; or history. Naming WHICH KEYS of that input are about to move needs IO — read
;; the input's LIVE on-disk key map and diff it against its last recorded
;; key-observation. That IO lives here, once, so both CLI branches (--explain via
;; print-explanations, --why via print-why-tree) share one decorator instead of
;; duplicating it. The pure printers take this as an optional #:reason->string, so
;; their default behaviour is unchanged and this module is the only impure seam.
;;
;; RETROSPECTIVE vs PROSPECTIVE. --history already names what moved at the LAST
;; build (delta.rkt observations->delta, over two history points). This decorates
;; a PENDING build: history's tail is the `from`, the live on-disk map is the
;; `to` (delta.rkt prospective-delta). Same diff core, different `to` source.

(require racket/list
         "model.rkt"
         "cache.rkt"        ; decision accessors, artifact-key-parts (the kind dispatch)
         "explain.rkt"      ; decision->string, source-report->string (the pure bases)
         "history.rkt"      ; history-key-observation-at, history-last-source-report
         "delta.rkt")

(provide input-key-deltas
         make-reason->string)

;; live-key-map : graph symbol build-env? -> (or/c (listof (cons string string)) #f)
;; A keyed artifact's CURRENT per-key map, read live — the same layer the history
;; records, via the shared kind dispatch (cache.rkt artifact-key-parts, st-lg0). #f
;; for anything without a per-key layer (a plain 'file, a token, an absent path).
(define (live-key-map g a env)
  (define art (hash-ref (graph-artifacts g) a #f))
  (and art (artifact-key-parts a (artifact-kind art) env)))

;; input-key-deltas : graph symbol decision? build-env? path-string -> (listof key-delta)
;; The changed keyed inputs of task `name' about to run, each as a prospective
;; key-delta. '() unless the decision is a 'run for 'input-changed — the only
;; verdict that names changed inputs. For each named input that has a live key map
;; and a recorded map at the digest the task LAST CONSUMED, diff the two; inputs
;; without a per-key layer, or without such a basis, drop out (nothing to name).
;;
;; THE BASIS IS WHAT THE TASK CONSUMED, NOT THE INPUT'S NEWEST MAP (st-6d2.2). The
;; task's cache entry names, per input, the digest its last clean run read; the
;; history is asked for the map at that digest (history-key-observation-at). The
;; newest recorded map is the wrong basis whenever the producer ran and this task
;; then failed: its entry still names the older digest, and a delta from the newer
;; map would miss the keys that moved in between — rebuilding too few, green over
;; stale files. No entry (never run clean), or no recorded map at that digest
;; (pruned), is no basis, and the caller rebuilds whole.
(define (input-key-deltas g name d env state-dir)
  (cond
    [(and (eq? (decision-verdict d) 'run)
          (eq? (decision-reason d) 'input-changed))
     (define entry (read-cache-entry (build-env-cache-dir env) name))
     (define consumed (make-immutable-hash (if entry (hash-ref entry 'input-hashes '()) '())))
     (filter values
             (for/list ([a (in-list (decision-details d))])
               (define live (live-key-map g a env))
               (define digest (hash-ref consumed a #f))
               (define basis (and live digest (history-key-observation-at state-dir a digest)))
               (and basis (prospective-delta a (list basis) live))))]
    [else '()]))

;; make-reason->string : graph build-env? path-string -> (symbol decision? -> string)
;; The decorated reason renderer both printers accept as #:reason->string. Returns
;; decision->string's prose, then EITHER:
;;   - for an 'input-changed run — one indented line per changed keyed input naming
;;     the moved subset, e.g.
;;       inputs changed: occurrence_places
;;           occurrence_places → 2 of 214 keys: +olympia ~seattle
;;   - for a 'boundary run — the task's last recorded source report (st-8bj), so the
;;     PROSPECTIVE plan is history-flavored, e.g.
;;       boundary — ingestion; never content-skipped; last run: source unchanged …
;; Closes over the env + state dir so the printers stay pure (task decision -> string).
;; It takes the TASK (not the decision alone) because a boundary decision carries no
;; name to look its history up by — unlike 'input-changed, whose details name inputs.
(define (make-reason->string g env state-dir)
  (lambda (task d)
    (define base (decision->string d))
    (cond
      [(eq? (decision-reason d) 'boundary)
       (define sr (history-last-source-report state-dir task))
       (if sr
           (format "~a; last run: ~a" base (source-report->string sr))
           base)]
      [else
       (define deltas (input-key-deltas g task d env state-dir))
       (if (null? deltas)
           base
           (string-append
            base
            (apply string-append
                   (for/list ([kd (in-list deltas)])
                     (format "\n       ~a → ~a"
                             (key-delta-artifact kd) (key-delta->string kd))))))])))
