#lang racket/base

;; CLI entry point.
;;
;;   racket src/main.rkt occurrences.db                    ; print the plan
;;   racket src/main.rkt --commands occurrences.db         ; dry-run: print commands
;;   racket src/main.rkt --run generate-sqlite             ; execute one TASK
;;   racket src/main.rkt --build occurrences.db            ; execute the whole plan
;;   racket src/main.rkt --build --from dbt-build occurrences.db   ; ...a suffix

(require racket/cmdline
         racket/set
         racket/list
         racket/file
         racket/string
         "model.rkt"
         "beeatlas.rkt"
         "exec.rkt"
         "determinism.rkt")

(define mode (make-parameter 'plan))      ; 'plan | 'commands | 'run | 'build | 'verify
(define from-task (make-parameter #f))    ; with --build/--verify: bound to a suffix

(define name
  (command-line
   #:program "stelis"
   #:once-any
   [("--commands") "dry-run: print the exact hermetic command per task (runs nothing)"
                   (mode 'commands)]
   [("--run") "execute the named TASK as a subprocess (output to a scratch dir)"
              (mode 'run)]
   [("--build") "execute the plan for TARGET in dependency order (partial success)"
                (mode 'build)]
   [("--verify") "build TARGET twice and compare hashes (determinism harness)"
                 (mode 'verify)]
   #:once-each
   [("--from") ft "with --build: run only the plan suffix beginning at task FT"
               (from-task (string->symbol ft))]
   #:args (name)
   (string->symbol name)))

;; a stelis-controlled output destination (explicit, no hidden copies)
(define (scratch-out)
  (define out (build-path (find-system-path 'temp-dir) "stelis-out"))
  (make-directory* out)
  out)

(cond
  ;; --- execute a single task ---------------------------------------------
  [(eq? (mode) 'run)
   (define out (scratch-out))
   (printf "Running ~a  (EXPORT_DIR=~a)\n" name out)
   (define code (run-task beeatlas-graph name beeatlas-runtimes
                          #:env (list (cons "EXPORT_DIR" (path->string out)))))
   (printf "\n~a ~a — exit ~a\n" (if (zero? code) "✓" "✗") name code)
   (define db (build-path out "occurrences.db"))
   (when (and (eq? name 'generate-sqlite) (file-exists? db))
     (printf "  wrote ~a (~a bytes)\n" db (file-size db)))
   (exit code)]

  ;; --- execute an ordered plan (partial success) -------------------------
  [(eq? (mode) 'build)
   (define-values (ordered pruned) (plan beeatlas-graph name))
   (define to-run
     (cond
       [(from-task)
        (or (member (from-task) ordered)
            (error 'stelis "--from ~a is not in the plan for ~a" (from-task) name))]
       [else ordered]))
   (define out (scratch-out))
   (printf "Building ~a — ~a task(s)~a  (EXPORT_DIR=~a)\n"
           name (length to-run)
           (if (from-task) (format ", from ~a" (from-task)) "")
           out)
   (define status (run-plan beeatlas-graph to-run beeatlas-runtimes
                            #:env (list (cons "EXPORT_DIR" (path->string out)))
                            #:resolve beeatlas-path
                            #:export-dir out
                            #:cache-dir (build-path ".stelis" "cache")))
   (define (tally s) (for/sum ([v (in-hash-values status)] #:when (eq? v s)) 1))
   (printf "\n— ~a ok · ~a cached · ~a failed · ~a skipped —\n"
           (tally 'ok) (tally 'cached) (tally 'failed) (tally 'skipped))
   (define db (build-path out "occurrences.db"))
   (when (file-exists? db) (printf "  ~a (~a bytes)\n" db (file-size db)))
   (exit (if (for/or ([v (in-hash-values status)]) (memq v '(failed skipped))) 1 0))]

  ;; --- determinism: build twice, compare hashes --------------------------
  [(eq? (mode) 'verify)
   (exit (if (verify-determinism beeatlas-graph name beeatlas-runtimes
                                 #:from (from-task))
             0 1))]

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
