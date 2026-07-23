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
         "cache.rkt"
         "trace.rkt")

(provide (struct-out runtime)                       ; re-provided from model.rkt
         recipe recipe? recipe-runtime recipe-args recipe-code ; (st-top: types
         (struct-out rule-check)                    ;  moved there for cache.rkt)
         (struct-out check-context)
         recipe->argv
         shell-quote
         print-plan-commands
         run-task
         prune-keys!
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

;; The `runtime' and `recipe' TYPES now live in model.rkt (st-top: the cache
;; layer content-addresses a recipe's code files, and exec.rkt requires cache.rkt,
;; so the types had to sit below both). Re-provided above; behavior stays here.

;; An IN-PROCESS node (st-0vz): the "second Datalog application" runs a rule-set
;; as a build node instead of shelling out. Its invoke is a `rule-check' whose
;; `run' evaluates the rule (e.g. a Datalog data-quality check) in Racket and
;; returns a verdict. A #f verdict FAILS the node — so, positioned as a 'gate, it
;; blocks its downstream via the ordinary partial-success flow (blockers-of),
;; exactly like a subprocess gate that exits non-zero. This is the modality the
;; whole data-quality-Datalog line needs; the integrity gate is its first rule.
;;   label : string — short display tag (e.g. "integrity")
;;   run   : (check-context -> (values boolean string)) — verdict + a human note
(struct rule-check (label run) #:transparent)

;; What a rule node sees when it runs: the graph and its own task name, the
;; build-env (resolve-relation etc. — the current data), and the state-dir (where
;; the history it compares against lives). A rule reasons over data + memory; this
;; is the handle to both, kept off build-env so that value doesn't grow again.
(struct check-context (graph task env state-dir) #:transparent)

;; print-plan-commands : graph (listof symbol) (hash symbol->runtime)
;;   [#:context (or/c build-env? #f)] -> void
;; Dry run: print the exact ordered shell commands a plan would execute. Executes
;; nothing. When a build-env is supplied, annotate each task's predicted
;; disposition:
;;   ≡ cached      inputs unchanged AND no upstream reruns -> it will be skipped
;;   ≈ conditional currently a cache hit, but an upstream WILL rerun, so its
;;                 inputs may change: unknowable until that upstream actually runs
;;   ▶ would run   a genuine miss (or not content-addressable, e.g. ingestion/dbt)
;; Only the materialised frontier can be predicted exactly; the ≈ marks where
;; foreknowledge runs out (see the input-addressed vs early-cutoff distinction).
(define (print-plan-commands g ordered runtimes #:context [env #f])
  (define will-run (make-hash)) ; tasks predicted to run; seeds the frontier walk
  (define (upstream-runs? name)
    (pair? (producers-of-inputs g name (lambda (p) (hash-ref will-run p #f)))))
  (for ([name (in-list ordered)] [i (in-naturals 1)])
    (define t (hash-ref (graph-tasks g) name))
    (define rec (task-invoke t))
    (define hit?
      (and env (eq? 'skip (decision-verdict (task-decision g name env)))))
    (define cached?      (and hit? (not (upstream-runs? name))))
    (define conditional? (and hit? (upstream-runs? name)))
    (unless cached? (hash-set! will-run name #t)) ; conditional + miss both may run
    (define tag
      (cond [(not env)      ""]
            [cached?        "  ≡ cached"]
            [conditional?   "  ≈ conditional"]
            [else           "  ▶ would run"]))
    (cond
      [(rule-check? rec)
       (printf "~a. ~a  [rule: ~a]~a\n     (in-process rule — no command)\n"
               (~i i) name (rule-check-label rec) tag)]
      [rec
       (define rt (hash-ref runtimes (recipe-runtime rec)))
       (printf "~a. ~a  [~a]~a\n     ~a\n"
               (~i i) name (runtime-label rt) tag
               (string-join (map shell-quote (recipe->argv rec runtimes)) " "))]
      [else
       (printf "~a. ~a  [no recipe]~a\n" (~i i) name tag)])))

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
;; With #:label, the child's stdout/stderr are captured and each line re-emitted
;; prefixed with the label (streaming per-task observability, st-d44.5) — so in a
;; multi-task build you can tell which task produced which line. Without a label,
;; the child inherits our stdio directly (simplest; used by single --run).
;; #:rebuild-keys, when a non-empty list, requests a PARTIAL rebuild (st-pd1): the
;; keys are injected as STELIS_REBUILD_KEYS (newline-separated, since a key like a
;; canonical_name contains spaces). An exporter that honors the var emits only
;; those keys into the existing EXPORT_DIR (merge in place); one that ignores it
;; rebuilds fully — so this is an opt-in HINT, never a correctness dependency.
(define (run-task g name runtimes #:env [extra-env '()] #:label [label #f]
                  #:rebuild-keys [rebuild-keys #f])
  (define rec (task-invoke (hash-ref (graph-tasks g) name)))
  (unless rec (error 'run-task "task ~a has no recipe" name))
  (define argv (recipe->argv rec runtimes))
  (define exe (or (find-executable-path (car argv))
                  (error 'run-task "executable not found on PATH: ~a" (car argv))))
  ;; a list (even empty — a pure-retraction rebuild) requests partial mode; #f is a
  ;; full rebuild (the var stays unset).
  (define env*
    (if (list? rebuild-keys)
        (cons (cons "STELIS_REBUILD_KEYS" (string-join rebuild-keys "\n")) extra-env)
        extra-env))
  (flush-output) ; our buffered banner must land before the child's direct fd writes
  (parameterize ([current-environment-variables
                  (environment-variables-copy (current-environment-variables))])
    (for ([kv (in-list env*)])
      (putenv (car kv) (cdr kv)))
    (if label
        (run/streaming exe (cdr argv) label)
        (apply system*/exit-code exe (cdr argv)))))

;; run/streaming : path (listof string) symbol -> exact-integer
;; Run the command, prefixing each captured output line with `label'. stdout and
;; stderr are pumped by separate threads (so a chatty stream can't deadlock the
;; other), each line flushed as it arrives for real-time streaming.
(define (run/streaming exe args label)
  (define-values (sp out in err) (apply subprocess #f #f #f exe args))
  (close-output-port in) ; these tasks read no stdin
  (define prefix (format "  ~a │ " label))
  (define (pump port sink)
    (thread
     (lambda ()
       (let loop ()
         (define line (read-line port 'any)) ; 'any: also split dbt's \r progress
         (unless (eof-object? line)
           (fprintf sink "~a~a\n" prefix line)
           (flush-output sink)
           (loop))))))
  (define t-out (pump out (current-output-port)))
  (define t-err (pump err (current-error-port)))
  (subprocess-wait sp)
  (thread-wait t-out)
  (thread-wait t-err)
  (subprocess-status sp))

;; prune-keys! : path-string (listof string) -> void
;; The engine's half of a partial rebuild's RETRACTION (st-pd1): delete the files
;; for `removed' keys (relative paths under `dir'). An exporter told "rebuild keys
;; X" can't know key Z was removed, so the engine removes Z's file itself. Missing
;; files are a no-op (idempotent); other keys' files are untouched (the merge).
(define (prune-keys! dir removed)
  (for ([rel (in-list removed)])
    (define p (build-path dir rel))
    (when (file-exists? p) (delete-file p))))

;; keyed-dir-outputs : graph symbol build-env? -> (listof path-string)
;; The task's 'dir outputs that already exist on disk — where a partial rebuild
;; merges into and where retracted keys are pruned. Existence is all this asks;
;; whether the dir is a sound merge BASIS is prior-complete-build?'s question
;; (asked before the run — after a partial run the merged dir necessarily
;; differs from the receipt, and pruning must still find it).
(define (keyed-dir-outputs g name env)
  (for*/list ([out (in-list (task-outputs (hash-ref (graph-tasks g) name)))]
              [a (in-value (hash-ref (graph-artifacts g) out #f))]
              #:when (and a (eq? 'dir (artifact-kind a)))
              [p (in-value (and env (env-resolve env out)))]
              #:when (and p (directory-exists? p)))
    p))

;; prior-complete-build? : graph symbol build-env? -> boolean
;; The partial-rebuild precondition (st-243): a partial rebuild MERGES into the
;; task's existing 'dir output(s), so what's on disk must be a prior COMPLETE
;; build. Directory-exists is not that — an interrupted run or a hand-touched
;; tree also "exists", and merging a few keys into one silently yields an
;; incomplete set. The proof is the cache receipt: every 'dir output's CURRENT
;; tree digest must equal the digest the last clean run recorded
;; (cache-store!'s output-hashes). No receipt, missing dir, or drifted content
;; -> #f, and the caller falls back to a full rebuild.
(define (prior-complete-build? g name env)
  (define dirs
    (for*/list ([out (in-list (task-outputs (hash-ref (graph-tasks g) name)))]
                [a (in-value (hash-ref (graph-artifacts g) out #f))]
                #:when (and a (eq? 'dir (artifact-kind a))))
      out))
  (and (pair? dirs)
       (let ([entry (read-cache-entry (build-env-cache-dir env) name)])
         (and entry
              (let ([recorded (hash-ref entry 'output-hashes '())]
                    [fresh (output-snapshot g name env)])
                (for/and ([out (in-list dirs)])
                  (define rec (assq out recorded))
                  (and rec (equal? rec (assq out fresh)))))))))

;; --- Ordered plan execution with partial success ----------------------------

;; blockers-of : graph symbol (hash symbol->symbol) -> (listof symbol)
;; The in-plan producers of `name's inputs that already finished with a non-'ok
;; status. Empty => the task may run. Pure — this is the partial-success core:
;; a failure blocks only its dependents, never independent tasks. Producers not
;; present in `status' are assumed already satisfied (e.g. skipped by --from).
(define (blockers-of g name status)
  (producers-of-inputs
   g name
   (lambda (p) (and (hash-has-key? status p)
                    (memq (hash-ref status p) '(failed skipped)))))) ; 'ok/'cached fine

;; run-plan : graph (listof symbol) (hash symbol->runtime)
;;            #:env (listof (cons string string)) #:context (or/c build-env? #f)
;;            -> (values (hash symbol->symbol) (listof trace-record?))
;; Run tasks in the given (topological) order. A task whose in-plan producers all
;; succeeded runs; otherwise it is skipped (partial success). Returns each task's
;; final status ('ok | 'failed | 'skipped), plus a trace-record per task in
;; build order, for the build trace (st-yg7.4).
;; With a #:context build-env, a task whose decision verdict is 'skip (inputs
;; unchanged, outputs present) is SKIPPED as 'cached. Tasks whose inputs aren't
;; fully content-addressable always run — their decision says why.
;; Early cutoff (st-8ig) needs no machinery here beyond observing it: each
;; task's decision is taken AFTER its upstreams ran, so a rerun that rebuilds
;; to identical content leaves downstream input hashes unchanged and they skip
;; as 'cached. What this loop adds is the receipt — after a run, the rebuilt
;; outputs are hashed and compared against the previous entry (the delta on
;; the trace record), so the cutoff point can be named, not just enjoyed.
;; #:rebuild-keys-of maps a task name to (rebuild-keys . removed-keys) to run it as
;; a PARTIAL rebuild (st-pd1), or #f for a normal full rebuild. The caller (which
;; owns the delta machinery) decides; the executor just honors it — injecting the
;; rebuild keys and, after a clean run, pruning the removed keys from the merged
;; 'dir output(s). Partial mode additionally requires prior-complete-build?
;; (st-243): the on-disk 'dir(s) must MATCH the last clean run's receipt, not
;; merely exist — anything else falls back to a full rebuild, and says so.
(define (run-plan g ordered runtimes
                  #:env [extra-env '()]
                  #:context [env #f]
                  #:state-dir [state-dir #f]
                  #:rebuild-keys-of [rebuild-keys-of (lambda (_) #f)])
  (define status (make-hash))
  (define records '())
  (for ([name (in-list ordered)])
    (define t (hash-ref (graph-tasks g) name))
    (define blockers (blockers-of g name status))
    ;; the pre-run decision (recorded even for blocked tasks) and, when the
    ;; task is content-addressable, the snapshot to store after a clean run
    (define-values (dec snap)
      (if env (decision+snapshot g name env) (values #f #f)))
    (define delta #f)
    ;; the observation (st-sds): each derived output's content hash after a run,
    ;; recorded on the trace so history projects an artifact→hash timeline. '()
    ;; unless the task actually (re)produced its outputs this build. The per-key
    ;; layer (st-6dv) rides alongside: (path→hash) pairs for each 'dir output.
    (define output-hashes '())
    (define output-key-hashes '())
    ;; the ingestion-boundary CRUD-snapshot (st-2k9): keyed STORE inputs this task
    ;; consumed, recorded when it actually ran (see the run branch). '() otherwise.
    (define input-key-hashes '())
    (define outcome
      (cond
        [(pair? blockers)
         (printf "\n⊘ ~a — skipped (blocked by ~a)\n"
                 name (string-join (map symbol->string blockers) ", "))
         'skipped]
        [(and dec (eq? 'skip (decision-verdict dec)))
         (printf "\n≡ ~a — cached (inputs unchanged)\n" name)
         'cached]
        ;; an in-process rule node (st-0vz): evaluate the rule, no subprocess.
        ;; A gate producing a token has no file outputs to hash, but we still
        ;; store its input snapshot so an unchanged relation cache-skips the
        ;; check next build (an unchanged relation cannot be anomalous vs. its
        ;; own last observation).
        [(rule-check? (task-invoke t))
         (define rc (task-invoke t))
         (printf "\n▶ ~a  [rule: ~a]\n" name (rule-check-label rc))
         (define-values (ok? note)
           ((rule-check-run rc) (check-context g name env state-dir)))
         (printf "~a ~a — ~a\n" (if ok? "✓" "✗") name note)
         (when (and ok? env)
           (cache-store! (build-env-cache-dir env) name snap
                         (env-output-paths env t) '()))
         (if ok? 'ok 'failed)]
        [else
         (define rt (hash-ref runtimes (recipe-runtime (task-invoke t))))
         (printf "\n▶ ~a  [~a]\n" name (runtime-label rt))
         ;; the previous entry, read before cache-store! overwrites it — the
         ;; comparison basis for the output delta
         (define prior (and env (read-cache-entry (build-env-cache-dir env) name)))
         ;; partial rebuild (st-pd1): the caller's (rebuild . removed) for this task,
         ;; or #f for a full rebuild. Only honored on a verified merge basis (st-243).
         (define rk-wanted (and env (rebuild-keys-of name)))
         (define rk (and rk-wanted (prior-complete-build? g name env) rk-wanted))
         (cond
           [rk
            (printf "  ⇒ partial: rebuilding ~a key(s)~a\n"
                    (length (car rk))
                    (if (pair? (cdr rk)) (format ", pruning ~a" (length (cdr rk))) ""))]
           [rk-wanted
            (printf "  ⇒ full rebuild: prior 'dir output missing or ≠ its last receipt\n")])
         (define code (run-task g name runtimes #:env extra-env #:label name
                                #:rebuild-keys (and rk (car rk))))
         (define ok? (zero? code))
         (printf "~a ~a — exit ~a\n" (if ok? "✓" "✗") name code)
         (when (and ok? env)
           ;; retract removed keys from the merged 'dir(s) before observing, so the
           ;; recorded per-key map reflects the pruned set.
           (when rk
             (for ([d (in-list (keyed-dir-outputs g name env))])
               (prune-keys! d (cdr rk))))
           (define-values (out-hashes out-keys) (output-snapshot+keys g name env))
           (set! output-hashes out-hashes)
           (set! output-key-hashes out-keys)
           ;; snapshot the store input's per-key map at the same point the outputs
           ;; are observed — the store is read-only during the build, so this is its
           ;; state for this build (st-2k9).
           (set! input-key-hashes (input-store-snapshot g name env))
           (cache-store! (build-env-cache-dir env) name snap
                         (env-output-paths env t) out-hashes)
           (set! delta (compare-outputs prior out-hashes))
           (when delta
             (case (output-delta-status delta)
               [(identical)
                (printf "  ≡ outputs identical to last build — early cutoff: downstream sees unchanged inputs\n")]
               [(changed)
                (printf "  ± outputs changed: ~a\n"
                        (string-join (map symbol->string (output-delta-details delta)) ", "))])))
         (if ok? 'ok 'failed)]))
    (hash-set! status name outcome)
    (set! records
          (cons (trace-record name dec snap outcome blockers delta
                              output-hashes output-key-hashes input-key-hashes)
                records)))
  (values status (reverse records)))
