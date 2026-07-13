#lang racket/base

;; CLI entry point.
;;
;;   racket src/main.rkt occurrences.db                    ; print the plan
;;   racket src/main.rkt --commands occurrences.db         ; dry-run: print commands
;;   racket src/main.rkt --explain occurrences.db          ; why would each task run/skip?
;;   racket src/main.rkt --why occurrences.db              ; why is it stale? (transitive;
;;   racket src/main.rkt --why dbt-build                   ;  a task or an artifact)
;;   racket src/main.rkt --explain --last                  ; what did the last build do?
;;   racket src/main.rkt --run generate-sqlite             ; execute one TASK
;;   racket src/main.rkt --build occurrences.db            ; execute the whole plan
;;   racket src/main.rkt --build --from dbt-build occurrences.db   ; ...a suffix

(require racket/cmdline
         racket/set
         racket/list
         racket/file
         racket/path
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
   [("--from") ft "scope --build/--commands/--explain/--why/--verify to the plan suffix at FT"
               (from-task (string->symbol ft))]
   [("--last") "with --explain: report what the last real --build decided and did"
               (last? #t)]
   #:args names
   (cond
     [(null? names) #f]
     [(null? (cdr names)) (string->symbol (car names))]
     [else (error 'stelis "expects at most one <name>, given: ~a"
                  (string-join names " "))])))

;; every mode needs the positional name except reading back the trace
(unless (or name (and (eq? (mode) 'explain) (last?)))
  (error 'stelis "expects a <name> (a target artifact, or a task for --run/--why)"))

;; a stelis-controlled output destination (explicit, no hidden copies)
(define (scratch-out-path) (build-path (find-system-path 'temp-dir) "stelis-out"))
(define (scratch-out) (define out (scratch-out-path)) (make-directory* out) out)

(define stelis-state (build-path ".stelis"))
(define stelis-cache (build-path stelis-state "cache"))

;; the one build environment every cache-aware mode shares. resolve-relation
;; content-addresses db-relation inputs via DuckDB (st-d5d), so early cutoff
;; reaches the pre-dbt graph and not only the file edges around dbt-build.
(define benv (make-build-env beeatlas-path (scratch-out-path) stelis-cache
                             #:resolve-relation beeatlas-resolve-relation))

;; ADR 0004 (st-3mi): the deterministic build clock injected into every executed
;; task's hermetic env, so outputs that stamp a build time stay byte-stable.
;; Computed per exec (not at top level) so pure planning modes never shell git.
(define (task-env out)
  (list (cons "EXPORT_DIR" (path->string out))
        (cons "SOURCE_DATE_EPOCH" (beeatlas-source-date-epoch))))

;; verify-seeds (st-dtq): the (src . basename) files to copy into a --verify
;; suffix's fresh build dir. The suffix's EXTERNAL input artifacts — those not
;; produced by any task in the suffix — resolved in `ref-dir' (a populated
;; EXPORT_DIR) and existing on disk. Post-dbt exporters read all their file inputs
;; from EXPORT_DIR (Pitfall 5), so seeding by basename lands them where the fresh
;; build's scripts look; inputs at fixed absolute paths (sandbox marts, raw files)
;; resolve outside ref-dir and are read in place, so they need no seeding.
(define (verify-seeds g to-run ref-dir)
  (define in-suffix (list->set to-run))
  (define produced
    (for*/set ([t (in-list to-run)]
               [o (in-list (task-outputs (hash-ref (graph-tasks g) t)))])
      o))
  (define externals
    (remove-duplicates
     (for*/list ([t (in-list to-run)]
                 [i (in-list (task-inputs (hash-ref (graph-tasks g) t)))]
                 #:unless (set-member? produced i))
       i)))
  (for*/list ([a (in-list externals)]
              [p (in-value (beeatlas-path a ref-dir))]
              #:when (and (path? p) (file-exists? p)
                          ;; only EXPORT_DIR-relative inputs need seeding
                          (equal? (path-only p) (path->directory-path ref-dir))))
    (cons p (path->string (file-name-from-path p)))))

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
  ;; have moved on since). Needs no positional name — the trace knows its target.
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
        (define why
          (cond
            [(eq? 'skipped (trace-record-outcome r))
             (format "blocked by ~a"
                     (string-join (map symbol->string (trace-record-blockers r)) ", "))]
            [(trace-record-decision r) (decision->string (trace-record-decision r))]
            [else "(caching was off)"]))
        ;; the cutoff receipt (st-8ig): what the rerun did to its outputs
        (define delta (trace-record-delta r))
        (define delta-note
          (cond
            [(not delta) ""]
            [(eq? 'identical (output-delta-status delta))
             " → reran; outputs identical — early cutoff, downstream saw unchanged inputs"]
            [else
             (format " → reran; outputs changed: ~a"
                     (string-join (map symbol->string (output-delta-details delta)) ", "))]))
        (printf "~a~a. ~a ~a\n     ~a~a\n"
                (if (< i 10) " " "") i
                (outcome-glyph (trace-record-outcome r)) (trace-record-task r)
                why delta-note))])]

  ;; --- execute a single task ---------------------------------------------
  [(eq? (mode) 'run)
   (define out (scratch-out))
   (printf "Running ~a  (EXPORT_DIR=~a)\n" name out)
   (define code (run-task beeatlas-graph name beeatlas-runtimes
                          #:env (task-env out)))
   (printf "\n~a ~a — exit ~a\n" (if (zero? code) "✓" "✗") name code)
   (define db (build-path out "occurrences.db"))
   (when (and (eq? name 'generate-sqlite) (file-exists? db))
     (printf "  wrote ~a (~a bytes)\n" db (file-size db)))
   (exit code)]

  ;; --- execute an ordered plan (partial success) -------------------------
  [(eq? (mode) 'build)
   (define-values (ordered pruned) (plan beeatlas-graph name))
   (define to-run (plan-suffix ordered))
   ;; st-6qc: refuse to build a plan whose 'file outputs can't be verified.
   (check-file-outputs-resolvable beeatlas-graph to-run benv)
   (define out (scratch-out))
   (printf "Building ~a — ~a task(s)~a  (EXPORT_DIR=~a)\n"
           name (length to-run)
           (if (from-task) (format ", from ~a" (from-task)) "")
           out)
   (define-values (status records)
     (run-plan beeatlas-graph to-run beeatlas-runtimes
               #:env (task-env out)
               #:context benv))
   (trace-store! stelis-state name records)
   (define (tally s) (for/sum ([v (in-hash-values status)] #:when (eq? v s)) 1))
   (printf "\n— ~a ok · ~a cached · ~a failed · ~a skipped —\n"
           (tally 'ok) (tally 'cached) (tally 'failed) (tally 'skipped))
   (define db (build-path out "occurrences.db"))
   (when (file-exists? db) (printf "  ~a (~a bytes)\n" db (file-size db)))
   (exit (if (for/or ([v (in-hash-values status)]) (memq v '(failed skipped))) 1 0))]

  ;; --- determinism: build twice, compare hashes --------------------------
  [(eq? (mode) 'verify)
   ;; st-6qc: same guard as --build — the plan verify will run must have
   ;; verifiable file outputs.
   (define-values (ordered _pruned) (plan beeatlas-graph name))
   (define to-run (plan-suffix ordered))
   (check-file-outputs-resolvable beeatlas-graph to-run benv)
   ;; st-dtq (1): compare the TARGET's on-disk file, not a hardcoded occurrences.db.
   ;; The basename is stable across export-dirs, so any resolvable dir gives it.
   (define target-path (beeatlas-path name (scratch-out-path)))
   (unless (path? target-path)
     (error 'stelis "--verify ~a: target has no resolvable file to compare" name))
   (define out-file (path->string (file-name-from-path target-path)))
   ;; st-dtq (2): a --from suffix builds into a fresh dir that lacks the @export
   ;; inputs its scripts read from EXPORT_DIR. Seed each build with the suffix's
   ;; EXTERNAL inputs (produced outside the suffix), taken from the populated
   ;; scratch dir a prior --build/--run left behind — holding upstream fixed so we
   ;; measure the suffix's own determinism. (Full-plan --verify needs no seeding.)
   (define seed (verify-seeds beeatlas-graph to-run (scratch-out-path)))
   (exit (if (verify-determinism beeatlas-graph name beeatlas-runtimes
                                 #:from (from-task)
                                 #:seed seed
                                 #:out-file out-file
                                 #:extra-env
                                 (list (cons "SOURCE_DATE_EPOCH"
                                             (beeatlas-source-date-epoch))))
             0 1))]

  ;; --- why is NAME stale? (a task or an artifact) -------------------------
  ;; The subject scopes its own plan: an artifact's plan is its minimal
  ;; upstream, and the question is asked of its producer task; a task's plan
  ;; is the union of its outputs' upstream cones (so a multi-output task is
  ;; covered whole, not through an arbitrary first output).
  [(eq? (mode) 'why)
   (define-values (subject-task targets)
     (cond
       [(hash-ref (graph-tasks beeatlas-graph) name #f)
        => (lambda (t)
             (when (null? (task-outputs t))
               (error 'stelis "--why ~a: task has no outputs to scope a plan by" name))
             (values name (task-outputs t)))]
       [(producer-of beeatlas-graph name)
        => (lambda (p) (values p (list name)))]
       [(hash-ref (graph-artifacts beeatlas-graph) name #f)
        (error 'stelis "--why ~a: an external input — no producing task, nothing to rebuild"
               name)]
       [else
        (error 'stelis "--why ~a: no task or artifact by that name in the graph" name)]))
   (define required
     (for/fold ([s (set)]) ([a (in-list targets)])
       (set-union s (required-tasks beeatlas-graph a))))
   (define to-run (plan-suffix (topo-sort beeatlas-graph required)))
   (unless (memq subject-task to-run)
     (error 'stelis "--why ~a: task ~a is not in the --from ~a suffix"
            name subject-task (from-task)))
   (define exps (plan-explanations beeatlas-graph to-run benv))
   (define thy (explanations->theory beeatlas-graph exps))
   (define dec-of (for/hash ([e (in-list exps)])
                    (values (explanation-task e) (explanation-decision e))))
   (unless (eq? subject-task name)
     (printf "~a is produced by ~a — asking about that task.\n\n" name subject-task))
   (if (datalog-stale? thy subject-task)
       (print-why-tree thy subject-task (lambda (t) (hash-ref dec-of t)))
       (printf "~a is NOT stale — ~a\n"
               subject-task (decision->string (hash-ref dec-of subject-task))))]

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
      (print-explanations (plan-explanations beeatlas-graph to-run benv))]
     [(eq? (mode) 'commands)
      (define to-run (plan-suffix ordered))
      (printf "Dry run — ~a command(s)~a, in build order (nothing executed):\n"
              (length to-run) (if (from-task) (format ", from ~a" (from-task)) ""))
      (printf "  ≡ cached · ≈ conditional (upstream reruns) · ▶ would run\n\n")
      (print-plan-commands beeatlas-graph to-run beeatlas-runtimes #:context benv)]
     [else
      (printf "Minimal upstream — ~a task(s), in build order:\n" (length ordered))
      (for ([t (in-list ordered)] [i (in-naturals 1)])
        (printf "  ~a. ~a  [~a]\n" i t (task-kind (hash-ref (graph-tasks beeatlas-graph) t))))])
   (printf "\nPruned — ~a task(s) not upstream of ~a:\n  ~a\n"
           (set-count pruned) name (sort (set->list pruned) symbol<?))])
