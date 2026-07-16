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
;;   racket src/main.rkt --history                         ; list every recorded build
;;   racket src/main.rkt --history species-maps            ; one artifact's hash timeline

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
         "history.rkt"
         "delta.rkt"
         "delta-explain.rkt"
         "determinism.rkt")

(define mode (make-parameter 'plan))      ; 'plan | 'commands | 'explain | 'why | 'run | 'build | 'verify | 'history
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
   [("--history") "browse the build history: all builds, or one artifact's hash timeline"
                  (mode 'history)]
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

;; every mode needs the positional name except reading back persisted state:
;; --explain --last (the trace knows its target) and --history (no arg = all builds)
(unless (or name (and (eq? (mode) 'explain) (last?)) (eq? (mode) 'history))
  (error 'stelis "expects a <name> (a target artifact, or a task for --run/--why)"))

;; short-hash : (or/c string #f) -> string — a hash's first 10 chars for display
(define (short-hash h)
  (cond [(not h) "?"]
        [(<= (string-length h) 10) h]
        [else (string-append (substring h 0 10) "…")]))

;; show-keys : string (listof string) -> void — a labelled key list, capped so a
;; wide fan-out doesn't flood the terminal; the cap is REPORTED, never silent.
(define (show-keys label names)
  (unless (null? names)
    (define shown (if (> (length names) 8) (take names 8) names))
    (define extra (- (length names) (length shown)))
    (printf "             ~a: ~a~a\n" label (string-join shown ", ")
            (if (> extra 0) (format ", …(+~a more)" extra) ""))))

;; a stelis-controlled output destination (explicit, no hidden copies)
(define (scratch-out-path) (build-path (find-system-path 'temp-dir) "stelis-out"))
(define (scratch-out) (define out (scratch-out-path)) (make-directory* out) out)

(define stelis-state (build-path ".stelis"))
(define stelis-cache (build-path stelis-state "cache"))

;; the one build environment every cache-aware mode shares. resolve-relation
;; content-addresses db-relation inputs via DuckDB (st-d5d), so early cutoff
;; reaches the pre-dbt graph and not only the file edges around dbt-build.
(define benv (make-build-env beeatlas-path (scratch-out-path) stelis-cache
                             #:resolve-relation beeatlas-resolve-relation
                             #:resolve-relation-columns beeatlas-resolve-relation-columns))

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
  ;; Reads history's tail; nothing is re-fingerprinted (the world may have moved
  ;; on since). Needs no positional name — the build record knows its target.
  [(and (eq? (mode) 'explain) (last?))
   (define bld (history-last stelis-state))
   (cond
     [(not bld)
      (printf "No usable build history under ~a/ — run --build first.\n"
              (path->string stelis-state))
      (exit 1)]
     [else
      (define records (build-record-records bld))
      (printf "Last build — target ~a, ~a task(s):\n"
              (build-record-target bld) (length records))
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

  ;; --- browse the build history ------------------------------------------
  ;; No name: the list of builds (append order — for BROWSING, not freshness).
  ;; A name: that artifact's content-hash timeline, marking where it changed.
  [(eq? (mode) 'history)
   (define builds (history-load stelis-state))
   (cond
     [(null? builds)
      (printf "No build history under ~a/ — run --build first.\n"
              (path->string stelis-state))
      (exit 1)]
     [(not name)
      (printf "Build history — ~a build(s), in append order:\n\n" (length builds))
      (for ([b (in-list builds)] [i (in-naturals 1)] [prev (in-list (cons #f builds))])
        (define h (build-record-graph-hash b))
        ;; topology drift: flag a build whose graph differs from the one before
        (define drift (and prev (not (equal? h (build-record-graph-hash prev)))))
        (printf "~a~a. ~a   graph ~a~a   ~a task(s)   epoch ~a\n"
                (if (< i 10) " " "") i
                (build-record-target b) (short-hash h)
                (if drift " (topology changed)" "")
                (length (build-record-records b))
                (build-record-epoch b)))]
     [else
      (define obs (history-observations stelis-state name))
      (define kobs (history-key-observations stelis-state name))
      (cond
        [(null? obs)
         (printf "~a — no observations in the history.\n" name)
         (printf "  (an external input, a never-built or always-cached artifact, or a typo)\n")
         (exit 1)]
        ;; a fan-out 'dir OR a db-relation: refine each ± into WHICH parts moved —
        ;; keys (paths) for a dir (st-6dv), columns for a relation (st-7vz)
        [(pair? kobs)
         (define kind (let ([a (hash-ref (graph-artifacts beeatlas-graph) name #f)])
                        (and a (artifact-kind a))))
         (define noun (if (eq? kind 'db-relation) "column" "key"))
         (define source (if (eq? kind 'db-relation) "db-relation" "fan-out 'dir"))
         (printf "~a — ~a observation(s), per ~a (~a):\n" name (length kobs) noun source)
         (printf "  ✦ first seen · ≡ unchanged · ± ~as changed/added/removed\n\n" noun)
         (for ([o (in-list kobs)] [prev (in-list (cons #f kobs))])
           (define cur (key-observation-keys o))
           (cond
             [(not prev)
              (printf "  build ~a  ✦ ~a ~a(s) first seen   (by ~a)\n"
                      (key-observation-build o) (length cur) noun
                      (trace-record-task (key-observation-record o)))]
             [else
              (define-values (added removed changed)
                (diff-key-maps (key-observation-keys prev) cur))
              (cond
                [(and (null? added) (null? removed) (null? changed))
                 (printf "  build ~a  ≡ rebuilt, all ~a ~a(s) identical\n"
                         (key-observation-build o) (length cur) noun)]
                [else
                 (printf "  build ~a  ± ~a changed, +~a added, -~a removed\n"
                         (key-observation-build o)
                         (length changed) (length added) (length removed))
                 (show-keys "changed" changed)
                 (show-keys "added" added)
                 (show-keys "removed" removed)])]))]
        [else
         (printf "~a — ~a observation(s), in build order:\n" name (length obs))
         (printf "  ✦ first seen · ≡ rebuilt to identical content · ± changed\n\n")
         (for ([o (in-list obs)] [prev (in-list (cons #f obs))])
           (define h (observation-hash o))
           (define glyph
             (cond [(not prev) "✦"]
                   [(equal? h (observation-hash prev)) "≡"]
                   [else "±"]))
           (printf "  build ~a  ~a ~a   (by ~a)\n"
                   (observation-build o) glyph (short-hash h)
                   (trace-record-task (observation-record o))))])])]

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
   ;; st-6qc: refuse to build a plan whose file/dir outputs can't be verified.
   (check-output-paths-resolvable beeatlas-graph to-run benv)
   (define out (scratch-out))
   (printf "Building ~a — ~a task(s)~a  (EXPORT_DIR=~a)\n"
           name (length to-run)
           (if (from-task) (format ", from ~a" (from-task)) "")
           out)
   (define-values (status records)
     (run-plan beeatlas-graph to-run beeatlas-runtimes
               #:env (task-env out)
               #:context benv
               #:state-dir stelis-state))
   ;; st-sds: append this build to the history (retiring last-build.rktd). The
   ;; source-epoch is sequence metadata for browsing only — freshness never reads
   ;; it. The graph snapshot is written once per distinct topology.
   (history-append! stelis-state name beeatlas-graph
                    (beeatlas-source-date-epoch) records)
   (define (tally s) (for/sum ([v (in-hash-values status)] #:when (eq? v s)) 1))
   (printf "\n— ~a ok · ~a cached · ~a failed · ~a skipped —\n"
           (tally 'ok) (tally 'cached) (tally 'failed) (tally 'skipped))
   (define db (build-path out "occurrences.db"))
   (when (file-exists? db) (printf "  ~a (~a bytes)\n" db (file-size db)))
   (exit (if (for/or ([v (in-hash-values status)]) (memq v '(failed skipped))) 1 0))]

  ;; --- determinism: build twice, compare hashes --------------------------
  [(eq? (mode) 'verify)
   ;; st-6qc: same guard as --build — the plan verify will run must have
   ;; verifiable file/dir outputs.
   (define-values (ordered _pruned) (plan beeatlas-graph name))
   (define to-run (plan-suffix ordered))
   (check-output-paths-resolvable beeatlas-graph to-run benv)
   ;; st-dtq (1): compare the TARGET's on-disk file/dir, not a hardcoded
   ;; occurrences.db. The basename is stable across export-dirs, so any resolvable
   ;; target (a file, or a 'dir tree — st-cly) gives it.
   (define target-path (beeatlas-path name (scratch-out-path)))
   (unless (path? target-path)
     (error 'stelis "--verify ~a: target has no resolvable path to compare" name))
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
       (print-why-tree thy subject-task (lambda (t) (hash-ref dec-of t))
                       (make-reason->string beeatlas-graph benv stelis-state))
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
      (print-explanations (plan-explanations beeatlas-graph to-run benv)
                          (make-reason->string beeatlas-graph benv stelis-state))]
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
