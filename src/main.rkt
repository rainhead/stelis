#lang racket/base

;; CLI entry point.
;;
;;   racket src/main.rkt occurrences.db                    ; print the plan
;;   racket src/main.rkt --commands occurrences.db         ; dry-run: print commands
;;   racket src/main.rkt --explain occurrences.db          ; why would each task run/skip?
;;   racket src/main.rkt --why occurrences.db              ; why is it stale? (transitive;
;;   racket src/main.rkt --why dbt-build                   ;  a task or an artifact) — PROSPECTIVE
;;   racket src/main.rkt --explain --last                  ; what did the last build do?
;;   racket src/main.rkt --run generate-sqlite             ; execute one TASK
;;   racket src/main.rkt --build occurrences.db            ; execute the whole plan
;;   racket src/main.rkt --build --all --export-dir DIR    ; build EVERY target (the run.py replacement)
;;   racket src/main.rkt --build --from dbt-build occurrences.db   ; ...a suffix
;;   racket src/main.rkt --build --from notes-harvest --export-dir DIR notes  ; CRUD: targeted notes into a served dir
;;   racket src/main.rkt --history                         ; list every recorded build
;;   racket src/main.rkt --history species-maps            ; one artifact's hash timeline
;;   racket src/main.rkt --history species-maps:genus/Bombus.svg  ; why ONE KEY last moved — RETROSPECTIVE
;;   racket src/main.rkt --moved-keys notes                ; which keys moved in the LAST build (machine-readable)

(require racket/cmdline
         racket/pretty
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
         "key-blame.rkt"
         "blockstore.rkt"
         (only-in "dasl.rkt" cid? cid->string)
         "determinism.rkt")

(define mode (make-parameter 'plan))      ; 'plan | 'commands | 'explain | 'why | 'run | 'build | 'verify | 'history | 'moved-keys | 'block
(define from-task (make-parameter #f))    ; with --build/--verify: bound to a suffix
(define last? (make-parameter #f))        ; with --explain: read the last-build trace
(define export-dir-arg (make-parameter #f)) ; --export-dir: an explicit output destination
(define all? (make-parameter #f))           ; --all: build the whole graph (replaces run.py)

(define name
  (command-line
   #:program "stelis"
   #:once-any
   [("--commands") "dry-run: print the exact hermetic command per task (runs nothing)"
                   (mode 'commands)]
   [("--explain") "print why each task in TARGET's plan would run or be skipped"
                  (mode 'explain)]
   [("--why") "why is NAME (a task or artifact) stale? the transitive chain, via Datalog (prospective)"
              (mode 'why)]
   [("--run") "execute the named TASK as a subprocess (output to a scratch dir)"
              (mode 'run)]
   [("--build") "execute the plan for TARGET in dependency order (partial success)"
                (mode 'build)]
   [("--verify") "build TARGET twice and compare hashes (determinism harness)"
                 (mode 'verify)]
   [("--history") "read the recorded history: all builds, one artifact's hash timeline, or — as ARTIFACT:KEY — why that one key last moved"
                  (mode 'history)]
   [("--moved-keys") "print the keys of ARTIFACT that moved in the LAST build, one per line (for a caller that rebuilds per key)"
                     (mode 'moved-keys)]
   [("--block") "print the stored block named by CID as a readable datum (state is content-addressed and binary; this is the way back out)"
                (mode 'block)]
   #:once-each
   [("--from") ft "scope --build/--commands/--explain/--why/--verify to the plan suffix at FT"
               (from-task (string->symbol ft))]
   [("--last") "with --explain: report what the last real --build decided and did"
               (last? #t)]
   [("--export-dir") dir "with --build/--run: write outputs to DIR (an explicit, served destination — e.g. a CRUD rebuild into the site's data dir) instead of the scratch dir"
                     (export-dir-arg dir)]
   [("--all") "with --build/--commands/--explain: the WHOLE graph (every task, topo-ordered) — the run.py replacement; no <target> needed"
              (all? #t)]
   #:args names
   (cond
     [(null? names) #f]
     [(null? (cdr names)) (string->symbol (car names))]
     [else (error 'stelis "expects at most one <name>, given: ~a"
                  (string-join names " "))])))

;; every mode needs the positional name except: reading back persisted state
;; (--explain --last, --history), and --all (the whole graph — no target).
(unless (or name (all?) (and (eq? (mode) 'explain) (last?)) (eq? (mode) 'history))
  (error 'stelis "expects a <name> (a target artifact, or a task for --run/--why)"))

;; block->datum : any -> any
;; A decoded block, rendered for reading: maps become alists SORTED by key (a hash
;; prints in no useful order, and the whole point of the format is that one value
;; has one spelling), and a CID link prints as its `b` string rather than a struct.
(define (block->datum v)
  (cond
    [(hash? v) (for/list ([p (in-list (sort (hash->list v) string<? #:key car))])
                 (cons (car p) (block->datum (cdr p))))]
    [(list? v) (map block->datum v)]
    [(cid? v) (cid->string v)]
    [else v]))

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

;; a stelis-controlled output destination (explicit, no hidden copies). --export-dir
;; overrides the scratch default so a CRUD rebuild can land in the served data dir.
(define (scratch-out-path)
  (if (export-dir-arg)
      (path->complete-path (export-dir-arg))
      (build-path (find-system-path 'temp-dir) "stelis-out")))
(define (scratch-out) (define out (scratch-out-path)) (make-directory* out) out)

;; Build STATE — the observation history, its graph snapshots, and the
;; input-addressed cache (st-7wu). This belongs to the PROJECT being built, not to
;; the engine checkout that happens to be cwd: history.rkt and cache.rkt are already
;; parameterized on a state dir, and this was the last constant holding the two
;; together. STELIS_STATE_DIR relocates them as a unit, which is what lets an engine
;; checkout be updated or replaced without touching a project's record of itself.
;;
;; The default stays cwd-relative deliberately. `.stelis/` is NOT uniformly derived:
;; the cache is disposable, but the observation history is append-only and not
;; reconstructible, and history.rkt treats a missing history as a legal first run —
;; so changing where we look by default would start a silent, empty timeline rather
;; than fail. Relocation is an operator action (mv the dir, set the env), never a
;; side effect of upgrading the engine.
(define stelis-state-env
  (let ([env (getenv "STELIS_STATE_DIR")])
    (and env (not (string=? env "")) env)))
(define stelis-state
  (if stelis-state-env (string->path stelis-state-env) (build-path ".stelis")))
(define stelis-cache (build-path stelis-state "cache"))

;; An empty state dir is INDISTINGUISHABLE from a never-built one — history.rkt
;; treats a missing history as a legal first run, by design. That is fine while the
;; default is the only location, and misleading the moment a history is relocated:
;; the reader is told "run --build first" when the builds exist, elsewhere. A
;; relocated deployment sets STELIS_STATE_DIR in its pipeline, but an INTERACTIVE
;; shell on the same host does not inherit it, which is exactly where this bites.
;; So whenever we report nothing found, say which of the two dirs we resolved and
;; how — never just that it was empty.
(define (state-dir-note)
  (if stelis-state-env
      (format "  (STELIS_STATE_DIR=~a)\n" stelis-state-env)
      (string-append
       "  STELIS_STATE_DIR is unset, so this path is relative to the current\n"
       "  directory. If the history was relocated, point at it:\n"
       "    STELIS_STATE_DIR=<dir> racket src/main.rkt --history\n")))

;; the one build environment every cache-aware mode shares. resolve-relation
;; content-addresses db-relation inputs via DuckDB (st-d5d), so early cutoff
;; reaches the pre-dbt graph and not only the file edges around dbt-build.
(define (beeatlas-env export-dir cache-dir)
  (make-build-env beeatlas-path export-dir cache-dir
                  #:resolve-relation beeatlas-resolve-relation
                  #:resolve-relation-columns beeatlas-resolve-relation-columns
                  #:resolve-store-keys beeatlas-resolve-store-keys
                  ;; st-top: recipe hashes cover the resolved argv +
                  ;; named code files, so script/pin edits invalidate
                  #:runtimes beeatlas-runtimes))

(define benv (beeatlas-env (scratch-out-path) stelis-cache))

;; ADR 0004 (st-3mi): the deterministic build clock injected into every executed
;; task's hermetic env, so outputs that stamp a build time stay byte-stable.
;; Computed per exec (not at top level) so pure planning modes never shell git.
(define (task-env out)
  (list (cons "EXPORT_DIR" (path->string out))
        (cons "SOURCE_DATE_EPOCH" (beeatlas-source-date-epoch))))

;; beeatlas-rebuild-keys-of : symbol
;;   -> (or/c (cons (listof string) (listof string)) #f)
;; The run-plan #:rebuild-keys-of hook (st-pd1): the (rebuild-keys . removed-relpaths)
;; that makes a partial-capable task a TARGETED rebuild, or #f for a full one. For a
;; partial-capable task about to rerun on a changed keyed input, fold the H1
;; prospective delta into the canonical_names to re-harvest (added+changed) and the
;; output files to prune (removed → "<name>.json"). #f (full) unless there is a real
;; per-key delta; run-plan additionally requires the prior 'dir output to match its
;; last clean-run receipt (prior-complete-build?, st-243) — a verified merge basis.
(define (beeatlas-rebuild-keys-of name)
  (and (memq name beeatlas-partial-tasks)
       (let-values ([(dec _snap) (decision+snapshot beeatlas-graph name benv)])
         (and (eq? 'run (decision-verdict dec))
              (eq? 'input-changed (decision-reason dec))
              (let ([deltas (input-key-deltas beeatlas-graph dec benv stelis-state)])
                (and (pair? deltas)
                     (cons (remove-duplicates
                            (append-map (lambda (d)
                                          (append (key-delta-added d) (key-delta-changed d)))
                                        deltas))
                           (remove-duplicates
                            (map (lambda (k) (string-append k ".json"))
                                 (append-map key-delta-removed deltas))))))))))

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

;; plan-for : (values (listof symbol) set) — the plan for this invocation. With
;; --all it is the WHOLE graph (every task, topo-ordered; nothing pruned) — the
;; run.py replacement. Otherwise the target's minimal-upstream plan.
(define (plan-for)
  (if (all?)
      (values (topo-sort beeatlas-graph
                         (list->set (hash-keys (graph-tasks beeatlas-graph))))
              (set))
      (plan beeatlas-graph name)))

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
      (printf "No usable build history under ~a/ — run --build first.\n~a"
              (path->string stelis-state) (state-dir-note))
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
        ;; what the rerun did. Two receipts can ride a run: a probing boundary's
        ;; own source report (st-8bj) and the generic output-cutoff delta (st-8ig).
        (define sr (trace-record-source-report r))
        (define delta (trace-record-delta r))
        ;; the cutoff receipt as a clause, or #f — reused below.
        (define delta-clause
          (cond
            [(not delta) #f]
            [(eq? 'identical (output-delta-status delta))
             "outputs identical — early cutoff, downstream saw unchanged inputs"]
            [else
             (format "outputs changed: ~a"
                     (string-join (map symbol->string (output-delta-details delta)) ", "))]))
        (define note
          (cond
            ;; an UNCHANGED source short-circuits ingestion and leaves outputs
            ;; untouched, so the delta can only echo "identical" — the report says
            ;; it better and fuller; show it alone.
            [(and sr (source-report-unchanged? sr))
             (format " → reran; ~a" (source-report->string sr))]
            ;; a CHANGED source means the loader re-ingested; keep the delta clause
            ;; too, since whether the outputs actually moved is the informative bit.
            [sr (format " → reran; ~a~a" (source-report->string sr)
                        (if delta-clause (format "; ~a" delta-clause) ""))]
            [delta-clause (format " → reran; ~a" delta-clause)]
            [else ""]))
        (printf "~a~a. ~a ~a\n     ~a~a\n"
                (if (< i 10) " " "") i
                (outcome-glyph (trace-record-outcome r)) (trace-record-task r)
                why note))])]

  ;; --- read one block back out -------------------------------------------
  ;; State is content-addressed and binary now (ADR 0010), so it needs a way back
  ;; out: `--block <cid>` prints any stored block — a graph snapshot, a keyed
  ;; artifact's map — as a readable datum. Inspectability was the price of the
  ;; format change, and this is what buys it back.
  [(eq? (mode) 'block)
   (define v (block-ref stelis-state (symbol->string name)))
   (cond
     [(not v)
      (eprintf "No block ~a under ~a/ — absent, unreadable, or not addressed by that CID.\n"
               name (path->string stelis-state))
      (exit 1)]
     [else (pretty-print (block->datum v))])]

  ;; --- why does ONE KEY of a keyed artifact look the way it does? ---------
  ;; `--history <artifact>:<key>` (st-nbu) — provenance that reaches a KEY, not
  ;; just a node. Split on the FIRST colon: no task or artifact name in the graph
  ;; carries one, while keys are relative paths that freely carry `/` and `.`.
  ;;
  ;; IT LIVES UNDER --history, NOT --why, because the tense is what divides this
  ;; CLI's two provenance families. --why / --explain are PROSPECTIVE: they
  ;; fingerprint the world now and report what WOULD run. --history is
  ;; RETROSPECTIVE: it reads what was recorded. This question — "why does this
  ;; published file say what it says?" — is retrospective, and the two answers
  ;; genuinely differ the moment anything has changed since the last build. Asking
  ;; it through --why would have made one flag mean two tenses depending on
  ;; whether its argument had a colon in it.
  ;;
  ;; So the progression is one flag deep to shallow: `--history` (every build),
  ;; `--history A` (A's timeline), `--history A:K` (why THAT key last moved).
  [(and (eq? (mode) 'history) name
        (regexp-match #rx"^([^:]+):(.+)$" (symbol->string name)))
   => (lambda (m)
        (define art (string->symbol (cadr m)))
        (define key (caddr m))
        ;; A name that isn't in the graph is a typo, and must not reach the walk —
        ;; there it is indistinguishable from a real artifact never built.
        (unless (hash-ref (graph-artifacts beeatlas-graph) art #f)
          (eprintf "~a — no artifact by that name in the graph.\n" art)
          (exit 1))
        (when (null? (history-load stelis-state))
          (eprintf "~a — no build history under ~a/; nothing to explain.\n~a"
                   art (path->string stelis-state) (state-dir-note))
          (exit 1))
        ;; one read per artifact, not one per node: history-key-observations
        ;; re-parses the whole log, and the chain revisits artifacts.
        (define cache (make-hash))
        (define (kobs-of a)
          (hash-ref! cache a (lambda () (history-key-observations stelis-state a))))
        (define node (key-blame-tree art key kobs-of))
        (case node
          [(no-timeline)
           (printf "~a has no per-key observations — nothing to ask about a key.\n" art)
           (printf "  (not a keyed artifact, or never built. Try `--history ~a`.)\n" art)
           (exit 1)]
          [(unknown-key)
           (printf "~a — no key `~a` in ~a's recorded timeline.\n" art key art)
           (printf "  (`--history ~a` lists the keys it has carried.)\n" art)
           (exit 1)]
          [(never-moved)
           (printf "~a:~a has never moved — present since ~a's first recorded observation, unchanged since.\n"
                   art key art)]
          [else
           (printf "~a:~a — why this key last moved, from the observation history.\n" art key)
           (printf "  (`--why ~a` asks the other tense: what would rebuild it now.)\n\n" art)
           (print-key-blame node short-hash)]))]

  ;; --- browse the build history ------------------------------------------
  ;; No name: the list of builds (append order — for BROWSING, not freshness).
  ;; A name: that artifact's content-hash timeline, marking where it changed.
  [(eq? (mode) 'history)
   (define builds (history-load stelis-state))
   (cond
     [(null? builds)
      (printf "No build history under ~a/ — run --build first.\n~a"
              (path->string stelis-state) (state-dir-note))
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
         (define source (case kind
                          [(db-relation) "db-relation"]
                          [(file)        "keyed store"]
                          [else          "fan-out 'dir"]))
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

  ;; --- which keys moved in the last build? (machine-readable) -------------
  ;; --history's per-key timeline, reduced to the one question a per-key REBUILDER
  ;; asks: of this keyed artifact, which members did the build I just ran move? The
  ;; answer goes on stdout as bare keys, one per line, and nothing else — so a shell
  ;; can feed it straight to a targeted consumer. Everything else is stderr.
  ;;
  ;; This is the read side of the same seam --explain/--why decorate prospectively
  ;; (delta-explain.rkt) and #:rebuild-keys-of drives internally (st-pd1): a keyed
  ;; input's delta already steers a targeted rebuild INSIDE the engine, and this
  ;; exposes the same fact to a targeted step OUTSIDE it — beeatlas's scoped 11ty
  ;; render (beeatlas-4oa), whose key set must agree with the harvest's or a note
  ;; publish bakes the wrong page.
  ;;
  ;; EXIT CODES ARE THE CONTRACT, because "nothing moved" and "I cannot tell you"
  ;; are opposite instructions to a caller who will otherwise do a partial rebuild:
  ;;   0 + keys   — these moved
  ;;   0 + silence — nothing moved (the producer cache-skipped, or re-produced
  ;;                 byte-identical content). A targeted rebuild of zero keys is
  ;;                 correct and is the point of early cutoff.
  ;;   1 + reason — no basis for an answer. The caller must fall back to a FULL
  ;;                rebuild, never to the empty set.
  [(eq? (mode) 'moved-keys)
   (define builds (history-load stelis-state))
   (when (null? builds)
     (eprintf "~a — no build history under ~a/; cannot say what moved.\n~a"
              name (path->string stelis-state) (state-dir-note))
     (exit 1))
   ;; A name that isn't in the graph is a typo, and must never reach the delta —
   ;; there it would be indistinguishable from a real artifact with no timeline.
   ;; Both refuse, but only here can we say WHICH mistake it was.
   (unless (hash-ref (graph-artifacts beeatlas-graph) name #f)
     (eprintf "~a — no artifact by that name in the graph.\n" name)
     (exit 1))
   (define kobs (history-key-observations stelis-state name))
   (define d (build-key-delta name kobs (length builds)))
   (cond
     [(eq? d 'not-produced)
      ;; Silence on stdout is the answer. Say why on stderr so an operator running
      ;; this by hand isn't left wondering whether it worked.
      (eprintf "~a — not re-produced by the last build (~a); no keys moved.\n"
               name (length builds))
      (exit 0)]
     [(eq? d 'no-basis)
      (eprintf "~a — first recorded production (build ~a): every key is new, which is not a delta. Rebuild in full.\n"
               name (length builds))
      (exit 1)]
     [else
      (for ([k (in-list (key-delta-moved d))]) (displayln k))
      (eprintf "~a — ~a (build ~a vs ~a)\n"
               name (key-delta->string d) (key-delta-to-build d) (key-delta-from-build d))
      (exit 0)])]

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
   (define-values (ordered pruned) (plan-for))
   (define to-run (plan-suffix ordered))
   ;; st-6qc: refuse to build a plan whose file/dir outputs can't be verified.
   (check-output-paths-resolvable beeatlas-graph to-run benv)
   (define out (scratch-out))
   (printf "Building ~a — ~a task(s)~a  (EXPORT_DIR=~a)\n"
           (or name "the whole graph") (length to-run)
           (if (from-task) (format ", from ~a" (from-task)) "")
           out)
   (define-values (status records)
     (run-plan beeatlas-graph to-run beeatlas-runtimes
               #:env (task-env out)
               #:context benv
               #:state-dir stelis-state
               #:rebuild-keys-of beeatlas-rebuild-keys-of))
   ;; st-sds: append this build to the history (retiring last-build.rktd). The
   ;; source-epoch is sequence metadata for browsing only — freshness never reads
   ;; it. The graph snapshot is written once per distinct topology.
   (history-append! stelis-state (or name 'all) beeatlas-graph
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
   ;; A target that does NOT live under the export dir (the app bundle, st-hdm:
   ;; the site build writes it to _site/assets and EXPORT_DIR does not steer it)
   ;; must be compared where it actually is. Passing the basename would send the
   ;; harness looking inside the throwaway build dir, where nothing was written.
   (define export-relative?
     (let ([root (path->string (scratch-out-path))]
           [tgt  (path->string target-path)])
       (and (>= (string-length tgt) (string-length root))
            (string=? root (substring tgt 0 (string-length root))))))
   (define out-file
     (if export-relative?
         (path->string (file-name-from-path target-path))
         (path->string target-path)))
   ;; st-dtq (2): a --from suffix builds into a fresh dir that lacks the @export
   ;; inputs its scripts read from EXPORT_DIR. Seed each build with the suffix's
   ;; EXTERNAL inputs (produced outside the suffix), taken from the populated
   ;; scratch dir a prior --build/--run left behind — holding upstream fixed so we
   ;; measure the suffix's own determinism. (Full-plan --verify needs no seeding.)
   (define seed (verify-seeds beeatlas-graph to-run (scratch-out-path)))
   ;; each build gets its own env, with its cache INSIDE that build's throwaway
   ;; dir — an in-process node needs an env to resolve paths at all (st-ozp), and
   ;; a shared cache would let build 2 skip and make the comparison vacuous.
   (exit (if (verify-determinism beeatlas-graph name beeatlas-runtimes
                                 #:from (from-task)
                                 #:seed seed
                                 #:out-file out-file
                                 #:make-context
                                 (lambda (dir) (beeatlas-env dir (build-path dir ".cache")))
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
       ;; a colon says they meant the per-key question, which lives on --history:
       ;; --why is the prospective family, --history the retrospective one. Say so
       ;; rather than letting it read as a typo.
       [(regexp-match #rx"^([^:]+):(.+)$" (symbol->string name))
        => (lambda (m)
             (error 'stelis
                    "--why ~a: a KEY is a retrospective question — try `--history ~a`"
                    name name))]
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
   (define-values (ordered pruned) (plan-for))
   (printf "Target: ~a\n\n" (or name "the whole graph (--all)"))
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
           (set-count pruned) (or name "the target") (sort (set->list pruned) symbol<?))])
