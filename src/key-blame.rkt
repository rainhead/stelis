#lang racket/base

;; PER-KEY BLAME (st-nbu, Horizon 2) — provenance that reaches a KEY, not just a
;; node. `--history notes:'bombus mixtus.json'` asks a question no existing surface
;; could: not "would this artifact rebuild?" but "why does THIS member of it look
;; the way it does?".
;;
;; IT LIVES UNDER --history BECAUSE TENSE IS WHAT DIVIDES THE TWO FAMILIES.
;; --why / --explain are PROSPECTIVE: they fingerprint the world now and report what
;; WOULD run; the prospective per-key question is already answered one hop deep by
;; delta-explain.rkt ("these keys of a changed input are about to move"). --history
;; is RETROSPECTIVE: it reads what was recorded. What has never been answerable is
;; the backward question — a file exists, it was published, why does it say what it
;; says? That is only answerable from the observation history, and it is the half a
;; renderer structurally cannot do for itself, which is why st-hdm names it as the
;; reason that could reclaim the render. So the progression is one flag deep to
;; shallow: `--history` / `--history A` / `--history A:K`.
;;
;; NOTHING NEW IS OBSERVED. Every fact the chain needs is already recorded:
;;   - a keyed artifact's (key -> hash) map at each build that produced it
;;     (history.rkt's key-observation timeline, st-6dv/st-2k9);
;;   - the producing task's DECISION at that build, carried on the same
;;     trace-record — so the recorded reason is READ, never re-derived. Asking
;;     "why did it move?" of a past build must report what that build actually
;;     decided, not what today's fingerprints would decide.
;;
;; THE CHAIN. Key K of artifact A moved at build B. A's producer recorded a
;; decision at B; when that decision is `input-changed` it names the inputs. For
;; each named input with a per-key timeline of its own, delta.rkt's build-key-delta
;; AT B names which of ITS keys moved — and each of those recurses, asking its own
;; question at B rather than at the latest build. An input with no per-key layer
;; ends that branch by naming the whole artifact, which is exactly today's --why
;; granularity: the chain degrades to what we already had rather than inventing a
;; key.
;;
;; NO KEY CORRESPONDENCE ACROSS ARTIFACTS, deliberately. Nothing here maps a
;; `notes/` key onto a page, or a `species-maps/` key onto a species — beeatlas
;; ADR 0017 settled that teaching the engine those names "would put a beeatlas
;; naming convention inside the build engine". So the chain FANS OUT: it says your
;; key moved in a build where these upstream keys moved. That is exact in the case
;; that matters most (one note write, one scoped render, one key each side) and
;; honest rather than invented when a nightly moves many. The narrowing, when it is
;; earned, has a hook already in the graph and declared for another reason —
;; fan-out-key's manifest arm IS a key correspondence (it exists for set
;; completeness). Reaching for it here would be premature.
;;
;; A KEY IT CANNOT EXPLAIN IS NAMED, NEVER DROPPED (history.rkt's rule, applied to
;; the walk): an upstream key that build-key-delta reports as moved but whose own
;; timeline yields no transition is recorded as `unresolved` rather than filtered
;; out of the children. A chain that quietly loses a branch reads as a shorter,
;; more confident answer than the history supports.
;;
;; PURE, with the history handed in. Same split as delta.rkt / delta-explain.rkt:
;; the walk takes a `kobs-of` lookup (symbol -> (listof key-observation)) so the
;; core is testable against literals, and history-key-observations is the only IO
;; seam — supplied by main.rkt.

(require racket/list
         racket/string
         "trace.rkt"     ; trace-record-task, trace-record-decision
         "cache.rkt"     ; decision accessors
         "explain.rkt"   ; decision->string — the SAME prose the prospective --why prints
         "history.rkt"   ; key-observation accessors
         "delta.rkt")    ; build-key-delta, key-delta accessors

(provide (struct-out key-move)
         (struct-out blame-node)
         last-key-move
         key-move-kind
         key-blame-tree
         key-move->string
         print-key-blame)

;; --- When did one key move? -----------------------------------------------------

;; One key's transition at one build — the atom the chain is built from.
;;   artifact  : symbol
;;   key       : string — a 'dir member's relative path, or a keyed store's key
;;   build     : exact-positive-integer — 1-based position in the history
;;   from-hash : (or/c string #f) — the value before; #f when the key was ADDED
;;   to-hash   : (or/c string #f) — the value at `build`; #f when it was REMOVED
;;   record    : trace-record — the producing task's record AT that build, which
;;               carries the decision the build actually made. A removal is
;;               recorded by the build that re-produced the artifact WITHOUT the
;;               key, so that build's record is the one that explains it.
;; from-hash and to-hash are never both #f: that is not a transition.
(struct key-move (artifact key build from-hash to-hash record) #:transparent)

;; key-move-kind : key-move -> (or/c 'added 'changed 'removed)
(define (key-move-kind m)
  (cond [(not (key-move-from-hash m)) 'added]
        [(not (key-move-to-hash m))   'removed]
        [else                         'changed]))

;; last-key-move : symbol string (listof key-observation)
;;                 [#:at-or-before (or/c exact-positive-integer #f)]
;;                 -> (or/c key-move 'no-timeline 'unknown-key 'never-moved)
;; The most recent build, at or before `at-or-before` (default: the whole
;; timeline), at which KEY of ARTIFACT transitioned — changed value, was added to a
;; set that already existed, or was removed from one.
;;
;; The `at-or-before` bound is what makes the recursive walk truthful. A child key
;; is asked about at the build that moved its CONSUMER, not at the latest build:
;; an upstream key that moved at build 22 and again at 25 explains a downstream
;; move at 22 with its move at 22. Unbounded, every branch of the chain would drift
;; forward to the newest thing that ever happened to it.
;;
;; The three non-move answers are distinct because they are three different
;; instructions to whoever asked:
;;   'no-timeline — no per-key layer at all (a plain 'file, a token, a typo, or a
;;                  name never built). There is no per-key question to ask here;
;;                  ask the whole-artifact one.
;;   'unknown-key — the artifact IS keyed and its timeline never carried this key
;;                  within the bound. A typo'd path, or a key added later. Refusing
;;                  matters: "never moved" about a key that does not exist reads as
;;                  "it is up to date".
;;   'never-moved — present since the artifact's first observation in range, same
;;                  value throughout. There is no move to explain, which is an
;;                  ANSWER, not a failure.
(define (last-key-move artifact key kobs #:at-or-before [bound #f])
  (define points
    (if bound
        (filter (lambda (o) (<= (key-observation-build o) bound)) kobs)
        kobs))
  (cond
    [(null? points) 'no-timeline]
    [(not (for/or ([o (in-list points)]) (assoc key (key-observation-keys o))))
     'unknown-key]
    [else
     ;; Walk adjacent pairs newest-first. The first pair that differs is the last
     ;; transition. Absence at BOTH ends is not a transition, so the walk steps
     ;; over the stretch after a removal and reports the removal itself.
     (let loop ([ps (reverse points)])
       (cond
         [(or (null? ps) (null? (cdr ps))) 'never-moved]
         [else
          (define cur (car ps))
          (define prev (cadr ps))
          (define here  (assoc key (key-observation-keys cur)))
          (define there (assoc key (key-observation-keys prev)))
          (cond
            [(and (not here) (not there)) (loop (cdr ps))]
            [(and here there (equal? (cdr here) (cdr there))) (loop (cdr ps))]
            [else
             (key-move artifact key
                       (key-observation-build cur)
                       (and there (cdr there))
                       (and here (cdr here))
                       (key-observation-record cur))])]))]))

;; --- The chain ------------------------------------------------------------------

;; One node of the blame tree.
;;   move       : key-move — what moved, and where
;;   task       : symbol — the task that produced the artifact at that build
;;   reason     : (or/c symbol #f) — the reason the build RECORDED, not a fresh one
;;   origin     : (or/c 'produced 'consumed) — whether this build OBSERVED the
;;                artifact as a task's output or as a keyed STORE input it read.
;;                'consumed is a LEAF: nothing in the graph produces the notes
;;                store, so the build cannot explain why it changed — a CRUD write
;;                outside the build did. The record attached to a consumed
;;                observation belongs to the CONSUMER, and its decision explains
;;                why the consumer ran, not why the store moved; descending into it
;;                walks straight back into the same artifact. (Found by running the
;;                chain on a real notes build, not by a test: it recursed
;;                notes-store.db into itself and stopped only on the diamond guard.)
;;   opaque     : (listof (cons symbol symbol)) — (input . why) for inputs the
;;                decision named that the chain cannot descend into: 'no-key-layer
;;                (no per-key timeline — today's --why granularity, kept rather
;;                than faked), 'unmoved (a per-key timeline that records no
;;                production at this build, so it did not move THEN — still named,
;;                because the build's own reason named it), or 'depth-capped.
;;   unresolved : (listof (cons symbol string)) — upstream (artifact . key) pairs
;;                reported as moved whose own timeline yields no transition. Named,
;;                never dropped.
;;   children   : (listof blame-node)
;;   elided     : boolean — this (artifact . key) already appeared above; its
;;                subtree is suppressed, as print-why-tree does for diamonds.
(struct blame-node (move task origin reason opaque unresolved children elided)
  #:transparent)

;; key-blame-tree : symbol string (symbol -> (listof key-observation))
;;                  [#:max-depth exact-positive-integer]
;;                  -> (or/c blame-node 'no-timeline 'unknown-key 'never-moved)
;; The recursive walk. last-key-move's non-move answers pass straight through at
;; the root, so a caller distinguishes "no such key" from "nothing to explain".
;;
;; The depth cap is a backstop, not a policy: the graph is acyclic and the
;; already-shown set collapses diamonds, so a real chain terminates on its own. It
;; exists because this walks PERSISTED data, which a graph edit can outlive.
(define (key-blame-tree artifact key kobs-of #:max-depth [max-depth 12])
  (define seen (make-hash))
  (let walk ([artifact artifact] [key key] [bound #f] [depth 0])
    (define m (last-key-move artifact key (kobs-of artifact) #:at-or-before bound))
    (cond
      [(symbol? m) m]
      [else
       (define id (cons artifact key))
       (define rec (key-move-record m))
       (define task (and rec (trace-record-task rec)))
       ;; observed as a keyed STORE input rather than as an output? Then it is an
       ;; authoritative leaf, and the record beside it belongs to its READER.
       (define origin
         (if (and rec (assq artifact (trace-record-input-key-hashes rec)))
             'consumed 'produced))
       (cond
         [(hash-ref seen id #f)
          (blame-node m task origin #f '() '() '() #t)]
         [else
          (hash-set! seen id #t)
          (define d (and rec (trace-record-decision rec)))
          (define reason (and d (decision-reason d)))
          ;; Only `input-changed` names inputs. Any other reason (code-changed,
          ;; recipe-changed, boundary, missing-output …) is a complete explanation
          ;; on its own, with no keyed upstream to descend into.
          ;; A consumed leaf explains nothing further: the change came from outside
          ;; the build. Only a PRODUCED artifact's decision names upstreams to walk.
          (define inputs (if (and (eq? origin 'produced) (eq? reason 'input-changed))
                             (decision-details d)
                             '()))
          (define at (key-move-build m))
          (define opaque '())
          (define unresolved '())
          (define children '())
          (for ([in (in-list inputs)])
            (define delta (build-key-delta in (kobs-of in) at))
            (cond
              [(eq? delta 'no-basis)
               (set! opaque (cons (cons in 'no-key-layer) opaque))]
              [(eq? delta 'not-produced)
               (set! opaque (cons (cons in 'unmoved) opaque))]
              [(>= depth max-depth)
               (set! opaque (cons (cons in 'depth-capped) opaque))]
              [else
               (for ([k (in-list (key-delta-moved delta))])
                 (define child (walk in k at (add1 depth)))
                 (if (blame-node? child)
                     (set! children (cons child children))
                     (set! unresolved (cons (cons in k) unresolved))))]))
          (blame-node m task origin reason
                      (reverse opaque) (reverse unresolved) (reverse children)
                      #f)])])))

;; --- Rendering -------------------------------------------------------------------
;; Placed here for the same reason print-why-tree lives beside the staleness rules:
;; the structure and the prose that reads it belong together, and main.rkt stays a
;; CLI. The walk above is unaffected — nothing here is consulted by it.

;; key-move->string : key-move (string -> string) -> string
;; One transition as prose. `abbrev` shortens a hash for display (main.rkt's
;; short-hash), passed in so this module owns no display policy.
(define (key-move->string m abbrev)
  (case (key-move-kind m)
    [(added)   (format "added at build ~a (~a)"
                       (key-move-build m) (abbrev (key-move-to-hash m)))]
    [(removed) (format "removed at build ~a (was ~a)"
                       (key-move-build m) (abbrev (key-move-from-hash m)))]
    [else      (format "changed at build ~a (~a → ~a)"
                       (key-move-build m)
                       (abbrev (key-move-from-hash m))
                       (abbrev (key-move-to-hash m)))]))

;; why-opaque->string : symbol -> string — why a named input ends its branch.
(define (why-opaque->string why)
  (case why
    [(no-key-layer) "no per-key timeline — ask --why for the whole artifact"]
    [(unmoved)      "keyed, but not re-produced at this build — it did not move then"]
    [(depth-capped) "chain truncated at the depth cap"]
    [else           (symbol->string why)]))

;; print-key-blame : blame-node (string -> string) -> void
;; The chain as a tree, indented like print-why-tree, one key per line. Each node
;; states the transition, the task that made it, and the reason THAT BUILD recorded
;; — rendered by explain.rkt's decision->string, so a retrospective answer reads in
;; the same vocabulary as the prospective one.
(define (print-key-blame node abbrev)
  (let loop ([n node] [depth 0])
    (define m (blame-node-move n))
    (define pad (make-string (* 2 depth) #\space))
    (printf "~a~a~a:~a — ~a\n"
            pad (if (zero? depth) "" "⤷ ")
            (key-move-artifact m) (key-move-key m)
            (key-move->string m abbrev))
    (cond
      [(blame-node-elided n)
       (printf "~a    (shown above)\n" pad)]
      [else
       (define rec (key-move-record m))
       (cond
         ;; An authoritative leaf. Saying "by <task> — inputs changed: <itself>"
         ;; here would be false twice over: that decision explains why the READER
         ;; ran, and nothing in the graph produces this artifact at all. The chain
         ;; ends at the ingestion boundary, which is where provenance genuinely
         ;; stops — past it is a CRUD write, not a build.
         [(eq? (blame-node-origin n) 'consumed)
          (printf "~a    authoritative input — no producer in the graph; it changed outside the build\n" pad)
          (printf "~a    (read by ~a at that build)\n" pad (or (blame-node-task n) "?"))]
         [else
          (printf "~a    by ~a~a\n" pad (or (blame-node-task n) "?")
                  (let ([d (and rec (trace-record-decision rec))])
                    (if d (format " — ~a" (decision->string d)) "")))])
       (for ([o (in-list (blame-node-opaque n))])
         (printf "~a      · ~a: ~a\n" pad (car o) (why-opaque->string (cdr o))))
       (for ([u (in-list (blame-node-unresolved n))])
         (printf "~a      · ~a:~a moved here, but its own timeline records no transition\n"
                 pad (car u) (cdr u)))
       (for ([c (in-list (blame-node-children n))])
         (loop c (add1 depth)))])))
