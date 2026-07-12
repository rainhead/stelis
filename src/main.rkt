#lang racket/base

;; CLI entry point.
;;
;;   racket src/main.rkt occurrences.db                    ; print the plan
;;   racket src/main.rkt --commands occurrences.db         ; dry-run: print commands
;;   racket src/main.rkt --explain occurrences.db          ; why would each task run/skip?
;;   racket src/main.rkt --why occurrences.db              ; why is it stale? (transitive;
;;   racket src/main.rkt --why dbt-build                   ;  a task or an artifact)
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
         "cache.rkt"
         "exec.rkt"
         "explain.rkt"
         "provenance-datalog.rkt"
         "trace.rkt"
         "determinism.rkt")

(define mode (make-parameter 'plan))      ; 'plan | 'commands | 'explain | 'why | 'run | 'build | 'verify
(define from-task (make-parameter #f))    ; with --build/--verify: bound to a suffix
(define last? (make-parameter #f))        ; with --explain: read the last-build trace

(define name
  (command-line
   #:program "stelis"
   #:once-any
   [("--commands") "dry-run: print the exact hermetic command per task (runs nothing)"
                   (mode 'commands)]
   [("--explain") "print why each task in TARGET's plan would run or be skipped"
                  (mode 'explain)]
   [("--why") "why is NAME (a task or artifact) stale? the transitive chain, via Datalog"
              (mode 'why)]
   [("--run") "execute the named TASK as a subprocess (output to a scratch dir)"
              (mode 'run)]
   [("--build") "execute the plan for TARGET in dependency order (partial success)"
                (mode 'build)]
   [("--verify") "build TARGET twice and compare hashes (determinism harness)"
                 (mode 'verify)]
   #:once-each
   [("--from") ft "with --build: run only the plan suffix beginning at task FT"
               (from-task (string->symbol ft))]
   [("--last") "with --explain: report what the last real --build decided and did"
               (last? #t)]
   #:args (name)
   (string->symbol name)))

;; a stelis-controlled output destination (explicit, no hidden copies)
(define (scratch-out-path) (build-path (find-system-path 'temp-dir) "stelis-out"))
(define (scratch-out) (define out (scratch-out-path)) (make-directory* out) out)

(define stelis-state (build-path ".stelis"))
(define stelis-cache (build-path stelis-state "cache"))

;; Restrict a plan to the suffix beginning at --from, when given. Used by both
;; --build (what runs) and --commands (what the dry run previews), so the preview
;; always mirrors the execution scope.
(define (plan-suffix ordered)
  (cond
    [(from-task)
     (or (member (from-task) ordered)
         (error 'stelis "--from ~a is not in the plan for ~a" (from-task) name))]
    [else ordered]))

(cond
  ;; --- what did the last real build decide and do? -----------------------
  ;; Reads the persisted trace; nothing is re-fingerprinted (the world may
  ;; have moved on since). The recorded target wins over the positional one.
  [(and (eq? (mode) 'explain) (last?))
   (define tr (trace-load stelis-state))
   (cond
     [(not tr)
      (printf "No usable build trace under ~a/ — run --build first.\n"
              (path->string stelis-state))
      (exit 1)]
     [else
      (define records (cdr tr))
      (printf "Last build — target ~a, ~a task(s):\n" (car tr) (length records))
      (printf "  ✓ ran · ≡ cached · ✗ failed · ⊘ skipped\n\n")
      (for ([r (in-list records)] [i (in-naturals 1)])
        (define glyph (case (trace-record-outcome r)
                        [(ok) "✓"] [(cached) "≡"] [(failed) "✗"] [(skipped) "⊘"]))
        (define why
          (cond
            [(eq? 'skipped (trace-record-outcome r))
             (format "blocked by ~a"
                     (string-join (map symbol->string (trace-record-blockers r)) ", "))]
            [(trace-record-decision r) (decision->string (trace-record-decision r))]
            [else "(caching was off)"]))
        (printf "~a~a. ~a ~a\n     ~a\n"
                (if (< i 10) " " "") i glyph (trace-record-task r) why))])]

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
   (define to-run (plan-suffix ordered))
   (define out (scratch-out))
   (printf "Building ~a — ~a task(s)~a  (EXPORT_DIR=~a)\n"
           name (length to-run)
           (if (from-task) (format ", from ~a" (from-task)) "")
           out)
   (define-values (status records)
     (run-plan beeatlas-graph to-run beeatlas-runtimes
               #:env (list (cons "EXPORT_DIR" (path->string out)))
               #:resolve beeatlas-path
               #:export-dir out
               #:cache-dir stelis-cache))
   (trace-store! stelis-state name
                 (map (lambda (r) (apply trace-record r)) records))
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

  ;; --- why is NAME stale? (a task or an artifact) -------------------------
  ;; The subject scopes its own plan: an artifact's plan is its minimal
  ;; upstream, and the question is asked of its producer task; a task's plan
  ;; is scoped through its first output (the task's own upstream cone).
  [(eq? (mode) 'why)
   (define-values (wt target)
     (cond
       [(hash-ref (graph-tasks beeatlas-graph) name #f)
        => (lambda (t)
             (when (null? (task-outputs t))
               (error 'stelis "--why ~a: task has no outputs to scope a plan by" name))
             (values name (car (task-outputs t))))]
       [(producer-of beeatlas-graph name)
        => (lambda (p) (values p name))]
       [(hash-ref (graph-artifacts beeatlas-graph) name #f)
        (error 'stelis "--why ~a: an external input — no producing task, nothing to rebuild"
               name)]
       [else
        (error 'stelis "--why ~a: no task or artifact by that name in the graph" name)]))
   (define-values (ordered _pruned) (plan beeatlas-graph target))
   (define to-run (plan-suffix ordered))
   (unless (memq wt to-run)
     (error 'stelis "--why ~a: task ~a is not in the --from ~a suffix" name wt (from-task)))
   (define exps (plan-explanations beeatlas-graph to-run
                                   #:resolve beeatlas-path
                                   #:export-dir (scratch-out-path)
                                   #:cache-dir stelis-cache))
   (define thy (explanations->theory beeatlas-graph exps))
   (define dec-of (for/hash ([e (in-list exps)])
                    (values (explanation-task e) (explanation-decision e))))
   (unless (eq? wt name)
     (printf "~a is produced by ~a — asking about that task.\n\n" name wt))
   (cond
     [(not (datalog-stale? thy wt))
      (printf "~a is NOT stale — ~a\n" wt (decision->string (hash-ref dec-of wt)))]
     [else
      ;; the transitive chain, as a tree over the stale-because edges; a
      ;; node reached twice (diamonds) is elided after its first showing
      (define shown (mutable-set))
      (let loop ([t wt] [depth 0])
        (define first-time? (not (set-member? shown t)))
        (set-add! shown t)
        (define blames
          (if first-time?
              (sort (set->list (datalog-direct-blames thy t)) symbol<?)
              '()))
        (define d (hash-ref dec-of t))
        (printf "~a~a~a — ~a\n"
                (make-string (* 2 depth) #\space)
                (if (zero? depth) "" "⤷ ")
                t
                (cond
                  [(not first-time?) "(shown above)"]
                  ;; own inputs are fine; the staleness is inherited — say so
                  ;; instead of the misleading bare "cached"
                  [(and (eq? 'skip (decision-verdict d)) (pair? blames))
                   "inputs unchanged, but stale through upstreams ↓"]
                  [else (decision->string d)]))
        (for ([u (in-list blames)])
          (loop u (add1 depth))))])]

  ;; --- plan / dry-run for a target artifact ------------------------------
  [else
   (define-values (ordered pruned) (plan beeatlas-graph name))
   (printf "Target: ~a\n\n" name)
   (cond
     [(eq? (mode) 'explain)
      (define to-run (plan-suffix ordered))
      (printf "Explain — ~a task(s)~a, in build order:\n"
              (length to-run) (if (from-task) (format ", from ~a" (from-task)) ""))
      (printf "  ≡ skips · ≈ conditional (upstream reruns) · ▶ runs\n\n")
      (print-explanations
       (plan-explanations beeatlas-graph to-run
                          #:resolve beeatlas-path
                          #:export-dir (scratch-out-path)
                          #:cache-dir stelis-cache))]
     [(eq? (mode) 'commands)
      (define to-run (plan-suffix ordered))
      (printf "Dry run — ~a command(s)~a, in build order (nothing executed):\n"
              (length to-run) (if (from-task) (format ", from ~a" (from-task)) ""))
      (printf "  ≡ cached · ≈ conditional (upstream reruns) · ▶ would run\n\n")
      (print-plan-commands beeatlas-graph to-run beeatlas-runtimes
                           #:resolve beeatlas-path
                           #:export-dir (scratch-out-path)
                           #:cache-dir stelis-cache)]
     [else
      (printf "Minimal upstream — ~a task(s), in build order:\n" (length ordered))
      (for ([t (in-list ordered)] [i (in-naturals 1)])
        (printf "  ~a. ~a  [~a]\n" i t (task-kind (hash-ref (graph-tasks beeatlas-graph) t))))])
   (printf "\nPruned — ~a task(s) not upstream of ~a:\n  ~a\n"
           (set-count pruned) name (sort (set->list pruned) symbol<?))])
