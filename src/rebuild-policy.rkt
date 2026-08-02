#lang racket/base

;; WHAT A DELTA ARM MEANS TO THE TASK THAT CONSUMES IT (st-qxq).
;;
;; delta.rkt keeps a key-delta's three arms — added / changed / removed —
;; deliberately distinct, because "which keys moved" is one question and "what
;; should I do about each" is a different one. This module answers the second, and
;; it answers it PER TASK, because the honest answer differs:
;;
;;   notes-harvest's output keyspace IS its input keyspace (one notes/<name>.json
;;   per key of the notes store). A removed note means that file must VANISH, so
;;   the engine deletes it — the exporter, told only "rebuild keys X", cannot know
;;   key Z disappeared.
;;
;;   the site render's output keys are PAGE PATHS, not note keys. A removed note
;;   means the page must be RE-RENDERED so that it loses its notes section, and
;;   must NOT vanish — the species still exists.
;;
;; beeatlas ADR 0017 states this directly: "the render's key set unions added +
;; changed + REMOVED, whereas the harvest's own targeted rebuild treats a removal
;; as prune-not-rebuild. The two consumers want different partitions of the same
;; delta." Before this module the partition was hardcoded for the first consumer,
;; so the second would have DROPPED every removal on both sides at once — not
;; rebuilt (removed was excluded) and not pruned (its path does not exist in a page
;; tree, and prune-keys! guards with file-exists?). Green build, stale page, no
;; report. That is the failure this module makes structurally impossible.
;;
;; THE POLICY IS READ, NOT DECLARED AGAIN. The distinction above is already in the
;; graph: `notes' is (store-keyed 'notes-store.db "{}.json"), and store-keyed means
;; exactly "my output keyspace IS this input's keyspace, via this template" — the
;; correspondence AND the filename transform, as data. Adding an #:on-removed slot
;; to make-task would create a second source of truth that can contradict it (a
;; task declaring 'rebuild over a store-keyed output is a bug no type would catch),
;; and would restate the ".json" that template-fill already knows. store-keyed
;; exists precisely so there is ONE definition of the store's keyset; this reads it
;; rather than adding a rival.
;;
;; THREE ARMS, and the third is a refusal:
;;   IDENTITY — an output of this task is store-keyed on the changed input.
;;              rebuild = added ∪ changed; prune = the removed keys, filled into
;;              the declared template.
;;   READER   — nothing this task outputs is keyed by that input; it merely reads
;;              it. rebuild = added ∪ changed ∪ removed; prune = nothing. This is
;;              key-delta-moved's documented semantics ("a removed key is as much
;;              a reason to redo as an added one — the artifact that consumed it
;;              must now be rebuilt WITHOUT it").
;;   ERROR    — the shape cannot express a safe answer. Raised at PRE-BUILD
;;              VALIDATION (check-partial-tasks), never at delta time, so it fires
;;              while someone is editing the graph rather than in production on the
;;              rare build where a key happens to disappear.
;;
;; Every removal therefore ends up either pruned or rebuilt, and any shape where we
;; could not tell is rejected before a task runs. Refusing beats quietly publishing
;; stale output — the same stance as delta.rkt's 'no-basis and history.rkt's rule
;; that a fact it cannot read is one it must not invent.
;;
;; PRUNING IS RESERVED TO store-keyed IDENTITY, deliberately (Peter, 2026-08-01).
;; A `fan-out' output is a FILTERED subset of its input relation — place-maps
;; writes a map only for places that actually have occurrences — so a key can leave
;; the output in two ways: it vanishes from the relation (a removal, which pruning
;; would catch) or it merely drops out of the filter while the key remains (which
;; pruning would NOT catch, leaving a stale file). Pruning a filtered output is
;; half an answer, and nothing needs the other half today. A fan-out-keyed output
;; therefore takes the READER arm.

(require racket/list
         "model.rkt"
         "delta.rkt"
         "fan-out-key.rkt")   ; store-keyed accessors + template-fill

(provide removal-policy
         deltas->rebuild+prune
         check-partial-tasks)

;; --- Which arm? -----------------------------------------------------------------

;; removal-policy : graph symbol symbol -> (or/c (cons 'prune string) 'rebuild)
;; What a REMOVED key of input `a` means to task `name`: prune it from the output
;; (with the template that names its file), or re-derive without it.
;;
;; Identity holds when some 'dir output of the task declares itself store-keyed on
;; exactly this input. Anything else — a fan-out-keyed output, a manifest-keyed
;; one, an unkeyed 'dir, no 'dir at all — is a reader of `a`.
(define (removal-policy g name a)
  (define t (hash-ref (graph-tasks g) name #f))
  (or (for/or ([out (in-list (if t (task-outputs t) '()))])
        (define art (hash-ref (graph-artifacts g) out #f))
        (define k (and art (artifact-keyed-by art)))
        (and (store-keyed? k)
             (eq? a (store-keyed-input k))
             (cons 'prune (store-keyed-template k))))
      'rebuild))

;; --- The fold -------------------------------------------------------------------

;; deltas->rebuild+prune : graph symbol (listof key-delta)
;;                         -> (cons (listof string) (listof string))
;; The (rebuild-keys . removed-relpaths) pair run-plan's #:rebuild-keys-of wants,
;; folded over one task's changed keyed inputs — each arm resolved by that input's
;; own policy, so a task reading two inputs with different correspondences gets
;; each treated on its own terms.
;;
;; ORDER IS PART OF THE CONTRACT, not incidental: rebuild keys are appended
;; added-then-changed per delta, in delta order, because they are joined with "\n"
;; into STELIS_REBUILD_KEYS and a reordering would change what the exporter is
;; handed. Both sides are de-duplicated, since two inputs may name the same key.
(define (deltas->rebuild+prune g name deltas)
  (define-values (rebuild prune)
    (for/fold ([rebuild '()] [prune '()]) ([d (in-list deltas)])
      (define policy (removal-policy g name (key-delta-artifact d)))
      (define moved (append (key-delta-added d) (key-delta-changed d)))
      (cond
        [(pair? policy)
         ;; identity: the removed keys name files to delete, via the template
         (values (append rebuild moved)
                 (append prune
                         (for/list ([k (in-list (key-delta-removed d))])
                           (template-fill (cdr policy) (list k)))))]
        [else
         ;; reader: a removal is a reason to re-derive, and deletes nothing
         (values (append rebuild moved (key-delta-removed d)) prune)])))
  (cons (remove-duplicates rebuild) (remove-duplicates prune)))

;; --- The refusal ------------------------------------------------------------------

;; check-partial-tasks : graph (listof symbol) -> void
;; Raise unless every partial-capable task has a shape whose removals have a safe
;; answer. Called once before a build, beside check-output-paths-resolvable — the
;; same st-6qc precedent: a graph-authoring mistake should fail while the graph is
;; being authored, not on the rare build where it finally matters.
;;
;; Two rejections:
;;   NO 'dir OUTPUT — a partial rebuild merges into, and prunes from, a keyed
;;     directory. A task with none cannot be run partially at all, so declaring it
;;     partial-capable is a mistake that would otherwise sit inert until a delta
;;     appeared and silently did nothing.
;;   store-keyed ALONGSIDE ANOTHER 'dir — run-plan prunes ONE relpath list from
;;     EVERY keyed 'dir output of a task (exec.rkt), so the identity arm's deletes
;;     would also be attempted against the other tree. Harmless while the names
;;     miss and a real deletion when they collide. Expressing this properly needs a
;;     per-output prune contract (st-1v6); until something needs that shape,
;;     refusing it is the whole fix.
(define (check-partial-tasks g partial-tasks)
  (for ([name (in-list partial-tasks)])
    (define t (hash-ref (graph-tasks g) name #f))
    (unless t
      (error 'check-partial-tasks
             "~a is declared partial-capable but is not a task in the graph" name))
    (define dirs
      (for/list ([out (in-list (task-outputs t))]
                 #:when (let ([a (hash-ref (graph-artifacts g) out #f)])
                          (and a (eq? 'dir (artifact-kind a)))))
        out))
    (when (null? dirs)
      (error 'check-partial-tasks
             (string-append
              "~a is declared partial-capable but has no 'dir output.\n"
              "  A partial rebuild merges into a keyed directory; there is nothing to merge into.")
             name))
    (define store-keyed-dirs
      (for/list ([out (in-list dirs)]
                 #:when (store-keyed? (artifact-keyed-by
                                       (hash-ref (graph-artifacts g) out))))
        out))
    (when (and (pair? store-keyed-dirs) (> (length dirs) 1))
      (error 'check-partial-tasks
             (string-append
              "~a has a store-keyed 'dir output (~a) alongside ~a other 'dir output(s): ~a.\n"
              "  Pruning applies ONE relative-path list to EVERY keyed 'dir output of a task,\n"
              "  so the removals meant for ~a would also be attempted against the others —\n"
              "  a no-op while the names miss, a real deletion when they collide.\n"
              "  Expressing this needs a per-output prune contract (st-1v6).")
             name (car store-keyed-dirs) (sub1 (length dirs))
             (remove (car store-keyed-dirs) dirs)
             (car store-keyed-dirs)))))
