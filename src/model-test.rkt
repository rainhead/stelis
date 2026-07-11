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

;; guard: a cycle -> topo-sort raises (required-tasks still terminates via `seen')
(define cyclic
  (build-graph
   (list (make-task 'x 'transform #:inputs '(b) #:outputs '(a))
         (make-task 'y 'transform #:inputs '(a) #:outputs '(b)))
   (list (make-artifact 'a 'file) (make-artifact 'b 'file))))
(check-exn #rx"cycle" (lambda () (topo-sort cyclic (set 'x 'y))))
