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
         "explain.rkt"      ; decision->string (the pure base this decorates)
         "history.rkt"      ; history-key-observations
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

;; input-key-deltas : graph decision? build-env? path-string -> (listof key-delta)
;; The changed keyed inputs of a task about to run, each as a prospective
;; key-delta. '() unless the decision is a 'run for 'input-changed — the only
;; verdict that names changed inputs. For each named input that has both a live
;; key map and a prior recorded observation, diff the two; inputs without a
;; per-key layer, or never observed before, drop out (nothing to name yet).
(define (input-key-deltas g d env state-dir)
  (cond
    [(and (eq? (decision-verdict d) 'run)
          (eq? (decision-reason d) 'input-changed))
     (filter values
             (for/list ([a (in-list (decision-details d))])
               (define live (live-key-map g a env))
               (and live
                    (prospective-delta
                     a (history-key-observations state-dir a) live))))]
    [else '()]))

;; make-reason->string : graph build-env? path-string -> (decision? -> string)
;; The decorated reason renderer both printers accept as #:reason->string. Returns
;; decision->string's prose, then — for an 'input-changed run — one indented line
;; per changed keyed input naming the moved subset, e.g.
;;   inputs changed: occurrence_places
;;       occurrence_places → 2 of 214 keys: +olympia ~seattle
;; Closes over the env + state dir so the printers stay pure (decision -> string).
(define (make-reason->string g env state-dir)
  (lambda (d)
    (define base (decision->string d))
    (define deltas (input-key-deltas g d env state-dir))
    (if (null? deltas)
        base
        (string-append
         base
         (apply string-append
                (for/list ([kd (in-list deltas)])
                  (format "\n       ~a → ~a"
                          (key-delta-artifact kd) (key-delta->string kd))))))))
