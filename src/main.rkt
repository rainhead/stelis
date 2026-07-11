#lang racket/base

;; CLI entry point: print the minimal upstream plan for a target artifact.
;;
;;   racket src/main.rkt occurrences.db

(require racket/cmdline
         racket/set
         racket/list
         "model.rkt"
         "beeatlas.rkt")

(define target
  (command-line
   #:program "stelis"
   #:args (target-name)
   (string->symbol target-name)))

(define-values (ordered pruned) (plan beeatlas-graph target))

(printf "Target: ~a\n\n" target)
(printf "Minimal upstream — ~a task(s), in build order:\n" (length ordered))
(for ([name (in-list ordered)] [i (in-naturals 1)])
  (define t (hash-ref (graph-tasks beeatlas-graph) name))
  (printf "  ~a. ~a  [~a]\n" i name (task-kind t)))

(printf "\nPruned — ~a task(s) not upstream of ~a:\n  ~a\n"
        (set-count pruned)
        target
        (sort (set->list pruned) symbol<?))
