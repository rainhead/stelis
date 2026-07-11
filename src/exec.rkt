#lang racket/base

;; Execution recipes and hermetic runtimes (slice 2 / st-d44.2).
;;
;; A task's reserved `invoke' slot (model.rkt) holds a `recipe': which hermetic
;; runtime to launch it in, plus the task-specific argv tail. The runtime itself
;; (the interpreter/env pin) is declared once and referenced by name, so the
;; dual-interpreter split (uv/3.14 vs uvx/3.13) is explicit metadata rather than
;; buried in a command string.
;;
;; 2a resolves recipes to commands and PRINTs them (a dry run); 2b (`run-task',
;; below) executes a recipe as a subprocess.

(require racket/list
         racket/string
         racket/system
         "model.rkt"
         "cache.rkt")

(provide (struct-out runtime)
         (struct-out recipe)
         recipe->argv
         shell-quote
         print-plan-commands
         run-task
         blockers-of
         run-plan)

;; shell-quote : string -> string
;; POSIX single-quote an argv element so the printed dry-run command is
;; copy-paste runnable. (Execution in 2b uses argv directly and needs no quoting;
;; this is for honest display only.)
(define (shell-quote s)
  (if (regexp-match? #px"^[A-Za-z0-9_./:=-]+$" s)
      s
      (string-append "'" (string-replace s "'" "'\\''") "'")))

;; A hermetic runtime: how to launch a task in a pinned interpreter/env.
;;   name   : symbol
;;   launch : (listof string)  argv prefix, e.g. '("uv" "run" "--directory" D "python")
;;   label  : string           short display tag, e.g. "uv/3.14"
(struct runtime (name launch label) #:transparent)

;; A task's invocation: a runtime (by name) + the task-specific argv tail.
;;   runtime : symbol
;;   args    : (listof string)
(struct recipe (runtime args) #:transparent)

;; recipe->argv : recipe (hash symbol->runtime) -> (listof string)
;; The full command: the runtime's launch prefix followed by the recipe's args.
(define (recipe->argv rec runtimes)
  (define rt (hash-ref runtimes (recipe-runtime rec)
                       (lambda ()
                         (error 'recipe->argv "unknown runtime: ~a" (recipe-runtime rec)))))
  (append (runtime-launch rt) (recipe-args rec)))

;; print-plan-commands : graph (listof symbol) (hash symbol->runtime) -> void
;; Dry run: print the exact ordered shell commands a plan would execute.
;; Executes nothing.
(define (print-plan-commands g ordered runtimes)
  (for ([name (in-list ordered)] [i (in-naturals 1)])
    (define rec (task-invoke (hash-ref (graph-tasks g) name)))
    (cond
      [rec
       (define rt (hash-ref runtimes (recipe-runtime rec)))
       (printf "~a. ~a  [~a]\n     ~a\n"
               (~i i) name (runtime-label rt)
               (string-join (map shell-quote (recipe->argv rec runtimes)) " "))]
      [else
       (printf "~a. ~a  [no recipe]\n" (~i i) name)])))

;; right-pad a small index for tidy columns
(define (~i i) (let ([s (number->string i)]) (if (< i 10) (string-append " " s) s)))

;; run-task : graph symbol (hash symbol->runtime)
;;            #:env (listof (cons string string)) -> exact-integer
;; Execute a single task's recipe as a subprocess, inheriting stdio (basic
;; streaming; a proper streaming layer is st-d44.5). Returns the exit code.
;;
;; Extra env vars are injected into a COPY of the environment, so Stelis's own
;; environment is never mutated — the subprocess is the only thing that sees them.
;; (This is where secret injection will hook in later; for now it carries things
;; like EXPORT_DIR to steer output to an explicit destination.)
(define (run-task g name runtimes #:env [extra-env '()])
  (define rec (task-invoke (hash-ref (graph-tasks g) name)))
  (unless rec (error 'run-task "task ~a has no recipe" name))
  (define argv (recipe->argv rec runtimes))
  (define exe (or (find-executable-path (car argv))
                  (error 'run-task "executable not found on PATH: ~a" (car argv))))
  (flush-output) ; our buffered banner must land before the child's direct fd writes
  (parameterize ([current-environment-variables
                  (environment-variables-copy (current-environment-variables))])
    (for ([kv (in-list extra-env)])
      (putenv (car kv) (cdr kv)))
    (apply system*/exit-code exe (cdr argv))))

;; --- Ordered plan execution with partial success ----------------------------

;; blockers-of : graph symbol (hash symbol->symbol) -> (listof symbol)
;; The in-plan producers of `name's inputs that already finished with a non-'ok
;; status. Empty => the task may run. Pure — this is the partial-success core:
;; a failure blocks only its dependents, never independent tasks. Producers not
;; present in `status' are assumed already satisfied (e.g. skipped by --from).
(define (blockers-of g name status)
  (define t (hash-ref (graph-tasks g) name))
  (for*/list ([in (in-list (task-inputs t))]
              [p (in-value (producer-of g in))]
              #:when (and p
                          (hash-has-key? status p)
                          (memq (hash-ref status p) '(failed skipped)))) ; 'ok/'cached ok
    p))

;; run-plan : graph (listof symbol) (hash symbol->runtime)
;;            #:env (listof (cons string string)) -> (hash symbol->symbol)
;; Run tasks in the given (topological) order. A task whose in-plan producers all
;; succeeded runs; otherwise it is skipped (partial success). Returns each task's
;; final status: 'ok | 'failed | 'skipped.
;; With #:resolve (symbol export-dir -> path/#f), #:export-dir, and #:cache-dir
;; all supplied, a task whose input fingerprint matches its cache sidecar and
;; whose outputs still exist is SKIPPED as 'cached (skip-if-current). Tasks whose
;; inputs aren't fully content-addressable (fingerprint #f) always run.
(define (run-plan g ordered runtimes
                  #:env [extra-env '()]
                  #:resolve [resolve #f]
                  #:export-dir [export-dir #f]
                  #:cache-dir [cache-dir #f])
  (define caching? (and resolve export-dir cache-dir))
  (define status (make-hash))
  (for ([name (in-list ordered)])
    (define t (hash-ref (graph-tasks g) name))
    (define blockers (blockers-of g name status))
    (define input-fp
      (and caching? (input-fingerprint g name (lambda (a) (resolve a export-dir)))))
    (define out-paths
      (if caching? (filter values (map (lambda (o) (resolve o export-dir)) (task-outputs t))) '()))
    (cond
      [(pair? blockers)
       (printf "\n⊘ ~a — skipped (blocked by ~a)\n"
               name (string-join (map symbol->string blockers) ", "))
       (hash-set! status name 'skipped)]
      [(and input-fp (cache-hit? cache-dir name input-fp out-paths))
       (printf "\n≡ ~a — cached (inputs unchanged)\n" name)
       (hash-set! status name 'cached)]
      [else
       (define rt (hash-ref runtimes (recipe-runtime (task-invoke t))))
       (printf "\n▶ ~a  [~a]\n" name (runtime-label rt))
       (define code (run-task g name runtimes #:env extra-env))
       (define ok? (zero? code))
       (hash-set! status name (if ok? 'ok 'failed))
       (printf "~a ~a — exit ~a\n" (if ok? "✓" "✗") name code)
       (when (and ok? input-fp) (cache-store! cache-dir name input-fp out-paths))]))
  status)
