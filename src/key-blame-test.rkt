#lang racket/base

;; Unit tests for per-key blame (st-nbu): the retrospective walk that answers "why
;; does THIS member of a keyed artifact look the way it does?" from the observation
;; history alone. The properties that matter — a transition is found newest-first
;; and typed (added / changed / removed); a removal is a move in its own right, not
;; the change that preceded it; the `at-or-before` bound keeps a child branch
;; pinned to the build that moved its consumer instead of drifting to the newest
;; move; the three non-move answers stay distinct; a decision that is not
;; `input-changed` is terminal; an input with no per-key layer is NAMED rather than
;; descended into or dropped; and an upstream key the timeline cannot explain lands
;; in `unresolved` rather than vanishing from the children.

(require rackunit
         "key-blame.rkt"
         "trace.rkt"
         "cache.rkt"
         "history.rkt")

;; --- fixtures -------------------------------------------------------------------

;; a trace-record carrying just what the walk reads: the task and its decision.
(define (rec task [reason #f] [details '()])
  (trace-record task
                (and reason (decision 'run reason details))
                #f 'ok '() #f '() '() '()))

;; a key-observation: build, (key -> hash) pairs, and the producing record.
(define (obs build keys [r (rec 'producer)]) (key-observation build keys r))

;; a kobs-of lookup over a literal table; an unlisted artifact has no timeline.
(define ((lookup table) a) (hash-ref table a '()))

;; --- last-key-move: finding and typing the transition ---------------------------

(let ([tl (list (obs 1 '(("a" . "h1") ("b" . "h1")))
                (obs 2 '(("a" . "h2") ("b" . "h1")))
                (obs 3 '(("a" . "h2") ("b" . "h1"))))])
  (define m (last-key-move 'A "a" tl))
  (check-pred key-move? m)
  (check-equal? (key-move-build m) 2 "the last build at which the value differed")
  (check-equal? (key-move-kind m) 'changed)
  (check-equal? (key-move-from-hash m) "h1")
  (check-equal? (key-move-to-hash m) "h2")
  (check-equal? (last-key-move 'A "b" tl) 'never-moved
                "present from the first observation, same value throughout")
  (check-equal? (last-key-move 'A "zz" tl) 'unknown-key
                "a key the timeline never carried is refused, not called unmoved")
  (check-equal? (last-key-move 'A "a" '()) 'no-timeline
                "an artifact with no per-key layer has no per-key question"))

;; a key present at the FIRST observation has no `added` transition — that is the
;; origin of the timeline, not an addition to a set that already existed.
(let ([tl (list (obs 1 '(("a" . "h1"))) (obs 2 '(("a" . "h1"))))])
  (check-equal? (last-key-move 'A "a" tl) 'never-moved))

;; a key that appears at a LATER observation is an addition.
(let* ([tl (list (obs 1 '(("a" . "h1")))
                 (obs 2 '(("a" . "h1") ("b" . "hb"))))]
       [m (last-key-move 'A "b" tl)])
  (check-equal? (key-move-kind m) 'added)
  (check-equal? (key-move-build m) 2)
  (check-false (key-move-from-hash m) "an addition has no prior value"))

;; --- a removal is a move, not the change before it -------------------------------
;; The subtle one. "b" changed at build 2 and was removed at build 3. Asking why it
;; looks the way it does must report the REMOVAL; reporting the build-2 change
;; would describe a value the artifact no longer has.
(let* ([tl (list (obs 1 '(("a" . "h1") ("b" . "hb1")))
                 (obs 2 '(("a" . "h1") ("b" . "hb2")))
                 (obs 3 '(("a" . "h1")))
                 (obs 4 '(("a" . "h1"))))]
       [m (last-key-move 'A "b" tl)])
  (check-equal? (key-move-kind m) 'removed)
  (check-equal? (key-move-build m) 3 "the build that re-produced the set without it")
  (check-equal? (key-move-from-hash m) "hb2")
  (check-false (key-move-to-hash m))
  ;; and the stretch of absence after the removal is stepped over, not mistaken
  ;; for a second transition at build 4.
  (check-equal? (key-move-build (last-key-move 'A "b" tl)) 3))

;; --- the at-or-before bound ------------------------------------------------------
(let ([tl (list (obs 1 '(("a" . "h1")))
                (obs 2 '(("a" . "h2")))
                (obs 3 '(("a" . "h3"))))])
  (check-equal? (key-move-build (last-key-move 'A "a" tl)) 3
                "unbounded, the newest transition")
  (check-equal? (key-move-build (last-key-move 'A "a" tl #:at-or-before 2)) 2
                "bounded, the newest transition at or before the bound")
  (check-equal? (last-key-move 'A "a" tl #:at-or-before 1) 'never-moved
                "bounded to the first observation, there is no pair to differ")
  (check-equal? (last-key-move 'A "a" tl #:at-or-before 0) 'no-timeline
                "a bound before every observation leaves nothing to walk"))

;; --- the chain -------------------------------------------------------------------
;; pages:index.html moved at build 2 because notes moved; notes' own key moved at
;; build 2 too, because the (unkeyed) store changed.
(define chain-table
  (hash 'pages (list (obs 1 '(("index.html" . "p1")))
                     (obs 2 '(("index.html" . "p2")) (rec 'render 'input-changed '(notes))))
        'notes (list (obs 1 '(("bombus.json" . "n1")))
                     (obs 2 '(("bombus.json" . "n2")) (rec 'harvest 'input-changed '(store))))))

(let ([node (key-blame-tree 'pages "index.html" (lookup chain-table))])
  (check-pred blame-node? node)
  (check-equal? (key-move-build (blame-node-move node)) 2)
  (check-equal? (blame-node-task node) 'render)
  (check-equal? (blame-node-reason node) 'input-changed)
  (check-equal? (length (blame-node-children node)) 1 "one moved key of the one changed input")
  (define kid (car (blame-node-children node)))
  (check-equal? (key-move-artifact (blame-node-move kid)) 'notes)
  (check-equal? (key-move-key (blame-node-move kid)) "bombus.json")
  (check-equal? (blame-node-task kid) 'harvest)
  ;; `store` has no per-key timeline, so the chain ends by NAMING it — the
  ;; granularity today's --why already has, kept rather than faked into a key.
  (check-equal? (blame-node-opaque kid) '((store . no-key-layer)))
  (check-equal? (blame-node-children kid) '()))

;; a decision that is not `input-changed` is terminal: it explains itself and names
;; no inputs to descend into.
(let* ([table (hash 'pages (list (obs 1 '(("index.html" . "p1")))
                                 (obs 2 '(("index.html" . "p2")) (rec 'render 'code-changed '(tpl.njk)))))]
       [node (key-blame-tree 'pages "index.html" (lookup table))])
  (check-equal? (blame-node-reason node) 'code-changed)
  (check-equal? (blame-node-children node) '())
  (check-equal? (blame-node-opaque node) '())
  (check-equal? (blame-node-unresolved node) '()))

;; an input the decision named that HAS a per-key timeline but recorded no
;; production at this build did not move then — named as 'unmoved, because the
;; build's own reason named it and dropping it would narrow the recorded answer.
(let* ([table (hash 'pages (list (obs 1 '(("i.html" . "p1")))
                                 (obs 3 '(("i.html" . "p2")) (rec 'render 'input-changed '(notes))))
                    'notes (list (obs 1 '(("a.json" . "n1")))
                                 (obs 2 '(("a.json" . "n2")))))]
       [node (key-blame-tree 'pages "i.html" (lookup table))])
  (check-equal? (blame-node-opaque node) '((notes . unmoved)))
  (check-equal? (blame-node-children node) '()))

;; the bound in the chain: notes' key moved at build 2 AND again at 3, but pages
;; moved at 2 — so the child must report build 2, not the newer move.
(let* ([table (hash 'pages (list (obs 1 '(("i.html" . "p1")))
                                 (obs 2 '(("i.html" . "p2")) (rec 'render 'input-changed '(notes))))
                    'notes (list (obs 1 '(("a.json" . "n1")))
                                 (obs 2 '(("a.json" . "n2")))
                                 (obs 3 '(("a.json" . "n3")))))]
       [node (key-blame-tree 'pages "i.html" (lookup table))]
       [kid (car (blame-node-children node))])
  (check-equal? (key-move-build (blame-node-move kid)) 2
                "the child is asked about at its consumer's build, not the latest")
  (check-equal? (key-move-to-hash (blame-node-move kid)) "n2"))

;; an upstream key reported as moved whose own timeline yields no transition is
;; NAMED in `unresolved`, never filtered out of the children. Here `notes` records
;; a first-ever production at build 2 (nothing before it to diff), so the delta
;; sees an added key while last-key-move sees only an origin.
(let* ([table (hash 'pages (list (obs 1 '(("i.html" . "p1")))
                                 (obs 2 '(("i.html" . "p2")) (rec 'render 'input-changed '(notes))))
                    'notes (list (obs 2 '(("a.json" . "n1")))))]
       [node (key-blame-tree 'pages "i.html" (lookup table))])
  (check-equal? (blame-node-children node) '())
  (check-equal? (blame-node-opaque node) '((notes . no-key-layer))
                "a first-ever production is no basis for a delta — refused, and named"))

;; diamonds: a key reached twice is elided after its first showing, as
;; print-why-tree does for tasks.
(let* ([table (hash 'top (list (obs 1 '(("t" . "a1")))
                               (obs 2 '(("t" . "a2")) (rec 'joiner 'input-changed '(left right))))
                    'left (list (obs 1 '(("k" . "l1")))
                                (obs 2 '(("k" . "l2")) (rec 'l 'input-changed '(shared))))
                    'right (list (obs 1 '(("k" . "r1")))
                                 (obs 2 '(("k" . "r2")) (rec 'r 'input-changed '(shared))))
                    'shared (list (obs 1 '(("s" . "s1")))
                                  (obs 2 '(("s" . "s2")) (rec 's))))]
       [node (key-blame-tree 'top "t" (lookup table))]
       [kids (blame-node-children node)])
  (check-equal? (length kids) 2 "one key each from left and right")
  (define shared-nodes
    (for*/list ([k (in-list kids)] [g (in-list (blame-node-children k))]) g))
  (check-equal? (length shared-nodes) 2)
  (check-false (blame-node-elided (car shared-nodes)) "first showing is full")
  (check-true  (blame-node-elided (cadr shared-nodes)) "the second is elided"))

;; the depth cap stops the walk by NAMING the input rather than recursing.
(let* ([table (hash 'a (list (obs 1 '(("k" . "a1")))
                             (obs 2 '(("k" . "a2")) (rec 'ta 'input-changed '(b))))
                    'b (list (obs 1 '(("k" . "b1")))
                             (obs 2 '(("k" . "b2")) (rec 'tb 'input-changed '(c))))
                    'c (list (obs 1 '(("k" . "c1")))
                             (obs 2 '(("k" . "c2")) (rec 'tc))))]
       [node (key-blame-tree 'a "k" (lookup table) #:max-depth 1)]
       [kid (car (blame-node-children node))])
  (check-equal? (blame-node-opaque kid) '((c . depth-capped)))
  (check-equal? (blame-node-children kid) '()))

;; root passthrough: the non-move answers reach the caller unchanged, so it can
;; tell "no such key" from "nothing to explain".
(check-equal? (key-blame-tree 'pages "nope" (lookup chain-table)) 'unknown-key)
(check-equal? (key-blame-tree 'gone "k" (lookup chain-table)) 'no-timeline)
