#lang racket/base

;; Unit tests for the pure core (model.rkt) over small synthetic graphs — the
;; guards and corner cases the beeatlas integration suite (plan-test.rkt) never
;; exercises: the two-producer and cycle errors, the diamond (shared upstream
;; counted once), and external-leaf stopping.

(require rackunit
         racket/set
         "model.rkt")

;; A small diamond with an external leaf and a sibling:
;;   ingest              -> raw
;;   left  (raw, config) -> l      ; config is an external leaf (no producer)
;;   right (raw)         -> r
;;   join  (l, r)        -> out     ; diamond: raw reaches join via left AND right
;;   sibling (raw)       -> sib     ; not upstream of out
(define g
  (build-graph
   (list (make-task 'ingest  'boundary  #:outputs '(raw))
         (make-task 'left    'transform #:inputs '(raw config) #:outputs '(l))
         (make-task 'right   'transform #:inputs '(raw)        #:outputs '(r))
         (make-task 'join    'transform #:inputs '(l r)        #:outputs '(out))
         (make-task 'sibling 'transform #:inputs '(raw)        #:outputs '(sib)))
   (list (make-artifact 'raw 'db-relation) (make-artifact 'l 'file)
         (make-artifact 'r 'file)          (make-artifact 'out 'file)
         (make-artifact 'sib 'file)        (make-artifact 'config 'external))))

;; producer-of: a real producer, an external leaf, an unknown name
(check-equal? (producer-of g 'raw) 'ingest "producer-of finds the producing task")
(check-false  (producer-of g 'config)       "external leaf has no producer")
(check-false  (producer-of g 'nope)         "unknown artifact has no producer")

;; required-tasks: the diamond counts shared upstream once; a leaf stops the walk
(check-equal? (required-tasks g 'out)
              (set 'ingest 'left 'right 'join)
              "diamond: ingest counted once despite two paths to it")
(check-equal? (required-tasks g 'config) (set)
              "an external-leaf target requires no tasks")
(check-equal? (required-tasks g 'raw) (set 'ingest)
              "a target one step from a boundary")

;; topo-sort: every producer precedes its consumers
(let* ([ordered (topo-sort g (required-tasks g 'out))]
       [pos (for/hash ([n (in-list ordered)] [i (in-naturals)]) (values n i))])
  (check-true (< (hash-ref pos 'ingest) (hash-ref pos 'left))  "ingest before left")
  (check-true (< (hash-ref pos 'ingest) (hash-ref pos 'right)) "ingest before right")
  (check-true (< (hash-ref pos 'left)   (hash-ref pos 'join))  "left before join")
  (check-true (< (hash-ref pos 'right)  (hash-ref pos 'join))  "right before join"))

;; plan: required set in order, plus the pruned siblings
(let-values ([(ordered pruned) (plan g 'out)])
  (check-equal? (list->set ordered) (set 'ingest 'left 'right 'join) "plan's required set")
  (check-equal? pruned (set 'sibling) "plan prunes the sibling"))

;; guard: two tasks producing one artifact -> build-graph raises
(check-exn #rx"produced by both"
           (lambda ()
             (build-graph
              (list (make-task 'a 'transform #:outputs '(x))
                    (make-task 'b 'transform #:outputs '(x)))
              (list (make-artifact 'x 'file)))))

;; guard: an edge naming an undeclared artifact -> build-graph raises (st-5e6).
;; Both directions matter. A typo'd INPUT leaves the name producerless, which the
;; planner reads as a leaf, so the edge vanishes and the task stops being
;; invalidated by it. A typo'd OUTPUT registers a producer for an artifact nobody
;; declared while the real one keeps none — and the two-producer guard above
;; cannot catch that, because the names differ.
(check-exn #rx"declares input beens, which is not a declared artifact"
           (lambda ()
             (build-graph
              (list (make-task 'brew 'transform #:inputs '(beens) #:outputs '(coffee)))
              (list (make-artifact 'beans 'file #:provenance 'upstream)
                    (make-artifact 'coffee 'file)))))
(check-exn #rx"declares output cofee, which is not a declared artifact"
           (lambda ()
             (build-graph
              (list (make-task 'brew 'transform #:inputs '(beans) #:outputs '(cofee)))
              (list (make-artifact 'beans 'file #:provenance 'upstream)
                    (make-artifact 'coffee 'file)))))

;; ...but an `imports' edge naming an artifact outside the graph stays LEGAL —
;; code-closure keeps it without traversing it (see the closure tests below), so
;; the check is scoped to task edges deliberately, not by oversight.
(check-not-exn
 (lambda ()
   (build-graph (list (make-task 'use 'transform #:inputs '(a.py) #:outputs '(out)))
                (list (make-artifact 'out 'file)
                      (make-artifact 'a.py 'code #:imports '(ghost.py))))))

;; --- leaf declarations (st-zb9) ----------------------------------------------
;; "No producer" is how a genuine leaf and a forgotten producer look identical, so
;; the declaration is checked against the topology in BOTH directions.

(check-not-exn (lambda () (check-graph-leaves g))
               "the diamond is consistent: only 'config is a leaf, declared 'external")

(check-exn #rx"beans has no producer and nothing declares it a leaf"
           (lambda ()
             (check-graph-leaves
              (build-graph
               (list (make-task 'brew 'transform #:inputs '(beans) #:outputs '(coffee)))
               (list (make-artifact 'beans 'file)          ; 'derived by default
                     (make-artifact 'coffee 'file))))))

(check-exn #rx"beans is declared a leaf .* but task grow produces it"
           (lambda ()
             (check-graph-leaves
              (build-graph
               (list (make-task 'grow 'transform #:outputs '(beans)))
               (list (make-artifact 'beans 'file #:provenance 'upstream))))))

;; guard: the vocabularies are closed, and checked at construction. A typo'd
;; provenance on a PRODUCED artifact is otherwise the worst kind of silent — it is
;; not a leaf and it has a producer, so check-graph-leaves finds it consistent,
;; while every cache.rkt filter is `(eq? 'derived ...)' and so drops the output
;; from observation entirely: early cutoff off, no error, green build.
(check-exn #rx"unknown provenance derivd"
           (lambda () (make-artifact 'coffee 'file #:provenance 'derivd)))
(check-exn #rx"unknown kind fyle"
           (lambda () (make-artifact 'coffee 'fyle)))
(check-not-exn
 (lambda () (for* ([k (in-list '(file dir db-relation external token code))]
                   [p (in-list '(derived authoritative upstream))])
              (make-artifact 'x k #:provenance p)))
 "every documented kind x provenance pair constructs")

;; every accepted way to be a leaf, and the one way not to be
(check-equal? (leaf-expectation (make-artifact 'x 'code)) 'leaf
              "'code is a leaf by kind")
(check-equal? (leaf-expectation (make-artifact 'x 'external)) 'leaf
              "'external is a leaf by kind")
(check-equal? (leaf-expectation (make-artifact 'x 'file #:provenance 'upstream)) 'leaf
              "'upstream is a leaf by origin — not ours to produce")
(check-equal? (leaf-expectation (make-artifact 'x 'file)) 'produced
              "'derived must be produced")
(check-equal? (leaf-expectation (make-artifact 'x 'db-relation)) 'produced
              "kind alone does not excuse it")
(check-equal? (leaf-expectation (make-artifact 'x 'file #:provenance 'authoritative)) 'either
              "'authoritative says nothing about the producer — see below")

;; ...and that last one is not squeamishness. Forward-only state is legitimately
;; written by a task INSIDE the graph — which is the case cache.rkt's
;; provenance filter exists for — as well as by a writer outside it. Both shapes
;; must construct.
(check-not-exn
 (lambda ()
   (build-graph (list (make-task 'writes 'transform #:inputs '(in) #:outputs '(state)))
                (list (make-artifact 'in 'file #:provenance 'upstream)
                      (make-artifact 'state 'file #:provenance 'authoritative))))
 "a task may write forward-only state")
(check-not-exn
 (lambda ()
   (build-graph (list (make-task 'reads 'transform #:inputs '(state) #:outputs '(out)))
                (list (make-artifact 'state 'file #:provenance 'authoritative)
                      (make-artifact 'out 'file))))
 "...and forward-only state written outside the graph is equally legal")

;; all disagreements are reported at once, so annotating a graph is one pass
(check-exn #rx"2 artifact\\(s\\) disagree"
           (lambda ()
             (check-graph-leaves
              (build-graph
               (list (make-task 'brew 'transform #:inputs '(beans water) #:outputs '(coffee)))
               (list (make-artifact 'beans 'file) (make-artifact 'water 'file)
                     (make-artifact 'coffee 'file))))))

;; guard: a cycle -> topo-sort raises (required-tasks still terminates via `seen')
(define cyclic
  (build-graph
   (list (make-task 'x 'transform #:inputs '(b) #:outputs '(a))
         (make-task 'y 'transform #:inputs '(a) #:outputs '(b)))
   (list (make-artifact 'a 'file) (make-artifact 'b 'file))))
(check-exn #rx"cycle" (lambda () (topo-sort cyclic (set 'x 'y))))

;; --- code-closure: the imports-edge walk (st-whi) -----------------------------
;; A chain with a diamond and a dangling edge:
;;   a.py -> b.py -> d.py
;;   a.py -> c.py -> d.py    ; diamond: d reached twice, counted once
;;   c.py -> ghost.py        ; named but not in the graph: kept, not traversed
(define gcode
  (build-graph
   (list (make-task 'use 'transform #:inputs '(raw a.py) #:outputs '(out)))
   (list (make-artifact 'raw 'file #:provenance 'upstream) (make-artifact 'out 'file)
         (make-artifact 'a.py 'code #:imports '(b.py c.py))
         (make-artifact 'b.py 'code #:imports '(d.py))
         (make-artifact 'c.py 'code #:imports '(d.py ghost.py))
         (make-artifact 'd.py 'code))))
(check-equal? (code-closure gcode '(a.py))
              '(a.py b.py c.py d.py ghost.py)
              "seeds included, diamond counted once, dangling name kept")
(check-equal? (code-closure gcode '(d.py)) '(d.py)
              "a leaf helper closes over itself alone")
(check-equal? (code-closure gcode '()) '() "no seeds, no closure")
;; a cycle among helpers terminates (each node visited once)
(define gcyc
  (build-graph
   '()
   (list (make-artifact 'p.py 'code #:imports '(q.py))
         (make-artifact 'q.py 'code #:imports '(p.py)))))
(check-equal? (code-closure gcyc '(p.py)) '(p.py q.py)
              "a helper-import cycle terminates")

;; graph->datum (v2): imports edges are topology — they appear in the datum and
;; therefore move the graph digest; a graph without them records '() per artifact.
(check-not-false (member '(a.py code derived (b.py c.py))
                         (caddr (graph->datum gcode)))
                 "a code artifact's imports ride in the topology snapshot")
(let* ([imports-of (lambda (g name)
                     (for/first ([e (in-list (caddr (graph->datum g)))]
                                 #:when (eq? (car e) name))
                       (cadddr e)))])
  (check-equal? (imports-of g 'raw) '() "a data artifact records no imports"))
(check-not-equal?
 (graph-digest gcode)
 (graph-digest
  (build-graph
   (list (make-task 'use 'transform #:inputs '(raw a.py) #:outputs '(out)))
   (list (make-artifact 'raw 'file #:provenance 'upstream) (make-artifact 'out 'file)
         (make-artifact 'a.py 'code #:imports '(b.py))   ; c.py edge dropped
         (make-artifact 'b.py 'code #:imports '(d.py))
         (make-artifact 'c.py 'code #:imports '(d.py ghost.py))
         (make-artifact 'd.py 'code))))
 "changing only an imports edge changes the graph digest")
