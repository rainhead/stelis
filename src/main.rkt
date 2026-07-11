#lang racket/base

;; CLI entry point.
;;
;;   racket src/main.rkt occurrences.db              ; print the plan (task list)
;;   racket src/main.rkt --commands occurrences.db   ; dry-run: print exact commands

(require racket/cmdline
         racket/set
         racket/list
         "model.rkt"
         "beeatlas.rkt"
         "exec.rkt")

(define show-commands? (make-parameter #f))

(define target
  (command-line
   #:program "stelis"
   #:once-each
   [("--commands") "print the exact hermetic command per task (dry run; runs nothing)"
                   (show-commands? #t)]
   #:args (target-name)
   (string->symbol target-name)))

(define-values (ordered pruned) (plan beeatlas-graph target))

(printf "Target: ~a\n\n" target)

(cond
  [(show-commands?)
   (printf "Dry run — ~a command(s), in build order (nothing executed):\n\n"
           (length ordered))
   (print-plan-commands beeatlas-graph ordered beeatlas-runtimes)]
  [else
   (printf "Minimal upstream — ~a task(s), in build order:\n" (length ordered))
   (for ([name (in-list ordered)] [i (in-naturals 1)])
     (define t (hash-ref (graph-tasks beeatlas-graph) name))
     (printf "  ~a. ~a  [~a]\n" i name (task-kind t)))])

(printf "\nPruned — ~a task(s) not upstream of ~a:\n  ~a\n"
        (set-count pruned)
        target
        (sort (set->list pruned) symbol<?))
