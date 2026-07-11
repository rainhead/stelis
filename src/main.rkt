#lang racket/base

;; CLI entry point.
;;
;;   racket src/main.rkt occurrences.db              ; print the plan (task list)
;;   racket src/main.rkt --commands occurrences.db   ; dry-run: print exact commands
;;   racket src/main.rkt --run generate-sqlite       ; execute one TASK (into scratch)

(require racket/cmdline
         racket/set
         racket/list
         racket/file
         "model.rkt"
         "beeatlas.rkt"
         "exec.rkt")

(define mode (make-parameter 'plan)) ; 'plan | 'commands | 'run

(define name
  (command-line
   #:program "stelis"
   #:once-any
   [("--commands") "dry-run: print the exact hermetic command per task (runs nothing)"
                   (mode 'commands)]
   [("--run") "execute the named TASK as a subprocess (output steered to a scratch dir)"
              (mode 'run)]
   #:args (name)
   (string->symbol name)))

(cond
  ;; --- execute a single task ---------------------------------------------
  [(eq? (mode) 'run)
   (define out (build-path (find-system-path 'temp-dir) "stelis-out"))
   (make-directory* out)
   (printf "Running ~a  (EXPORT_DIR=~a)\n\n" name out)
   (define code (run-task beeatlas-graph name beeatlas-runtimes
                          #:env (list (cons "EXPORT_DIR" (path->string out)))))
   (printf "\n~a ~a — exit ~a\n" (if (zero? code) "✓" "✗") name code)
   ;; generate-sqlite is the only task that writes into EXPORT_DIR; report it.
   (define db (build-path out "occurrences.db"))
   (when (and (eq? name 'generate-sqlite) (file-exists? db))
     (printf "  wrote ~a (~a bytes)\n" db (file-size db)))
   (exit code)]

  ;; --- plan / dry-run for a target artifact ------------------------------
  [else
   (define-values (ordered pruned) (plan beeatlas-graph name))
   (printf "Target: ~a\n\n" name)
   (cond
     [(eq? (mode) 'commands)
      (printf "Dry run — ~a command(s), in build order (nothing executed):\n\n"
              (length ordered))
      (print-plan-commands beeatlas-graph ordered beeatlas-runtimes)]
     [else
      (printf "Minimal upstream — ~a task(s), in build order:\n" (length ordered))
      (for ([t (in-list ordered)] [i (in-naturals 1)])
        (printf "  ~a. ~a  [~a]\n" i t (task-kind (hash-ref (graph-tasks beeatlas-graph) t))))])
   (printf "\nPruned — ~a task(s) not upstream of ~a:\n  ~a\n"
           (set-count pruned) name (sort (set->list pruned) symbol<?))])
