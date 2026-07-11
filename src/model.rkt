#lang racket/base

;; The build-graph model and the minimal-upstream plan computation.
;; See docs/adr/0001-build-graph-model.md for the design and its reasons.
;;
;; The graph is bipartite: task nodes consume and produce artifact nodes.
;; A single source of truth for producer edges: a task's `outputs' list. An
;; artifact with no producing task is an external/ingestion leaf.

(require racket/list
         racket/set)

(provide (struct-out artifact)
         (struct-out task)
         (struct-out graph)
         make-artifact
         make-task
         build-graph
         producer-of
         required-tasks
         topo-sort
         plan)

;; --- Node types -------------------------------------------------------------

;; An artifact node: a logical dataset.
;;   name        : symbol
;;   kind        : 'file | 'db-relation | 'external | 'token
;;   fingerprint : reserved for slice 4 (skip-if-current); #f until then
(struct artifact (name kind fingerprint) #:transparent)

;; A task node.
;;   name    : symbol  (matches the run.py step name)
;;   kind    : 'transform | 'gate | 'boundary
;;   inputs  : (listof symbol)  artifact names it consumes
;;   outputs : (listof symbol)  artifact names it produces
;;   invoke  : reserved for slice 2 (execution); #f until then
(struct task (name kind inputs outputs invoke) #:transparent)

;; Keyword smart-constructors so the reserved slots default to #f and the
;; authored graph reads cleanly.
(define (make-artifact name kind #:fingerprint [fingerprint #f])
  (artifact name kind fingerprint))

(define (make-task name kind
                   #:inputs [inputs '()]
                   #:outputs [outputs '()]
                   #:invoke [invoke #f])
  (task name kind inputs outputs invoke))

;; --- The graph --------------------------------------------------------------

;; A graph bundles the nodes plus a derived producer index.
;;   tasks       : hash  symbol -> task
;;   artifacts   : hash  symbol -> artifact
;;   producer-of : hash  artifact-name -> task-name   (derived from task outputs)
(struct graph (tasks artifacts producer-index) #:transparent)

;; build-graph : (listof task) (listof artifact) -> graph
;; Derives the producer index from task outputs (the single source of truth),
;; and checks that no two tasks claim the same output.
(define (build-graph tasks artifacts)
  (define task-table
    (for/hash ([t (in-list tasks)]) (values (task-name t) t)))
  (define artifact-table
    (for/hash ([a (in-list artifacts)]) (values (artifact-name a) a)))
  (define producer-index
    (for*/fold ([acc (hash)]) ([t (in-list tasks)]
                               [out (in-list (task-outputs t))])
      (when (hash-has-key? acc out)
        (error 'build-graph
               "artifact ~a is produced by both ~a and ~a"
               out (hash-ref acc out) (task-name t)))
      (hash-set acc out (task-name t))))
  (graph task-table artifact-table producer-index))

;; producer-of : graph symbol -> (or/c symbol #f)
;; The task that produces artifact `a', or #f if it is an external leaf.
(define (producer-of g a)
  (hash-ref (graph-producer-index g) a #f))

;; --- Plan: minimal upstream + topological order -----------------------------

;; required-tasks : graph symbol -> (setof symbol)
;; The set of task names that must run to produce `target' (an artifact name).
;; Walks backward: to make an artifact, run its producer task; that task needs
;; its input artifacts; recurse. External leaves (no producer) stop the walk.
(define (required-tasks g target)
  (let loop ([artifact-name target] [seen (set)])
    (define producer (producer-of g artifact-name))
    (cond
      [(not producer) seen]                 ; external leaf: nothing to run
      [(set-member? seen producer) seen]    ; already accounted for
      [else
       (define t (hash-ref (graph-tasks g) producer))
       (for/fold ([seen (set-add seen producer)])
                 ([in (in-list (task-inputs t))])
         (loop in seen))])))

;; topo-sort : graph (setof symbol) -> (listof symbol)
;; Orders the given task names so every task follows the tasks producing its
;; inputs. Kahn's algorithm over the task-level dependency graph induced by the
;; artifact edges. Errors on a cycle (the build graph must be a DAG).
(define (topo-sort g task-names)
  ;; task-level deps: T depends on the producers of T's inputs that are also
  ;; in the required set.
  (define (deps-of name)
    (define t (hash-ref (graph-tasks g) name))
    (for*/set ([in (in-list (task-inputs t))]
               [p (in-value (producer-of g in))]
               #:when (and p (set-member? task-names p)))
      p))
  (define deps (for/hash ([n (in-set task-names)]) (values n (deps-of n))))
  (let loop ([deps deps] [order '()])
    (cond
      [(zero? (hash-count deps)) (reverse order)]
      [else
       (define ready
         (sort (for/list ([(n ds) (in-hash deps)] #:when (set-empty? ds)) n)
               symbol<?))                    ; sort ready set for stable output
       (when (null? ready)
         (error 'topo-sort "dependency cycle among: ~a" (hash-keys deps)))
       (define done (list->set ready))
       (define deps*
         (for/hash ([(n ds) (in-hash deps)] #:unless (set-member? done n))
           (values n (set-subtract ds done))))
       (loop deps* (append (reverse ready) order))])))

;; plan : graph symbol -> (values (listof symbol) (setof symbol))
;; Returns the required tasks in topological order, and the set of tasks in the
;; graph that were pruned (not upstream of the target) — the pruning is the
;; whole point, so we surface it.
(define (plan g target)
  (define required (required-tasks g target))
  (define ordered (topo-sort g required))
  (define all-tasks (list->set (hash-keys (graph-tasks g))))
  (values ordered (set-subtract all-tasks required)))
