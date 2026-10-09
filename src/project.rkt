#lang racket/base

;; A PROJECT: everything the CLI needs to build one case study's graph (st-ml9.1).
;;
;; Until salishsea-io arrived, main.rkt reached for beeatlas by name about forty
;; times — its graph, where its artifacts live, how to launch its tasks, how to
;; content-address its database relations, which of its tasks rebuild per key, its
;; build clock, its checkout. That was one project's wiring spelled out inline, not
;; an engine that happened to have one project. This struct is those facts as ONE
;; value, so the engine is written once against it and a second graph is a second
;; value rather than a second main.rkt.
;;
;; It is deliberately a bag of what already existed, not a framework: every field
;; is something main.rkt was already calling under a beeatlas- name. A field earns
;; its place by a second project needing it, not by symmetry.
;;
;;   name               : symbol — the project's key. It is written into every build
;;                        record (history.rkt), which is what lets a state dir refuse
;;                        a build that isn't its own (st-z1c).
;;   graph              : graph — the authored build graph
;;   runtimes           : (hash symbol runtime) — how each task kind is launched
;;   path               : (artifact-name export-dir -> (or/c path #f)) — where an
;;                        artifact lives, given the build's EXPORT_DIR
;;   resolve-relation, resolve-relation-columns, resolve-store-keys
;;                      : the build-env resolver slots (cache.rkt), or #f when the
;;                        project has no such inputs
;;   partial-tasks      : (listof symbol) — tasks that honour STELIS_REBUILD_KEYS
;;   incremental-tasks  : (listof symbol) — tasks that honour STELIS_CHANGED_INPUTS
;;                        (ADR 0015): told which of their inputs changed since their
;;                        last recorded run, when their outputs are as that run left
;;                        them, so they can recompute only the partition that reads
;;                        those inputs. A hint: a task that ignores it recomputes whole.
;;   edge-verify-tasks  : (listof symbol) — the tasks --verify-edges covers
;;   source-date-epoch  : (-> string) — the deterministic build clock (ADR 0004)
;;   checkout           : path — the project's repository, which its recipes' code
;;                        paths live under
;;   checkout-env       : string — the env var that relocates `checkout' (so a
;;                        missing checkout can say how to fix it)
;;   default-state-dir  : path — where build state lives when STELIS_STATE_DIR is
;;                        unset. beeatlas's is cwd-relative `.stelis' for history's
;;                        sake (st-7f4: moving it would start a silent empty
;;                        timeline); a NEW project defaults into its own checkout,
;;                        since it has no timeline to strand.
;;   history-retention  : (or/c exact-positive-integer #f) — seconds of build history
;;                        to keep (history-prune!, st-ml9.7), or #f to keep it all.
;;                        Pruned in batches: up to a thirtieth more is kept, so the
;;                        log is rewritten about once a day rather than every build.
;;                        salishsea builds every few minutes and keeps 30 days;
;;                        beeatlas builds nightly and keeps its whole timeline.
;;   build-log-after-build? : boolean — refresh the operator build log (st-9rf) after
;;                        every --build. beeatlas publishes the page, so it does;
;;                        salishsea builds every five minutes and publishes nothing
;;                        from it, so rendering it each time was ~6 s of every build
;;                        for a page nobody opened. --render-log renders it on demand.
;;   databases          : (listof db-binding) — the database files the project's
;;                        answers are claims about, each chosen by an env var with a
;;                        fallback. Named in the context banner, and a STRICT one's
;;                        fallback is refused by the modes that execute (st-az9).
(provide (struct-out project)
         make-project
         (struct-out db-binding)
         env-db-binding
         db-binding-description
         db-binding-refusal)

;; --- which database (st-az9) ------------------------------------------------------
;; A database a project reads is chosen by an env var, falling back to a default
;; path for local runs. The fallback is a convenience that turns into a wrong answer
;; the moment two copies exist: beeatlas's nightly ran its publish gate before
;; exporting DB_PATH, so the gate read the checkout's five-month-stale copy while
;; the pipeline after it read the serving one, and a fix to the serving database
;; changed nothing. An unset variable alone is not the hazard (an absent fallback
;; fails on its own); the hazard is "unset AND the fallback exists" — a confident
;; answer about the wrong file.
;;
;;   label     : string — what the file is, for a reader ("beeatlas DuckDB")
;;   path      : path — the file chosen
;;   env       : string — the variable that chooses it
;;   from-env? : boolean — #t when `env' chose it, #f when it is the fallback
;;   strict?   : boolean — refuse the fallback in modes that execute tasks. Strict
;;               where something OUTSIDE this invocation decides which copy is real
;;               (beeatlas: the nightly's pipeline); not where the build writes the
;;               file itself and the fallback is simply where it keeps it
;;               (salishsea's snapshot).
;; Resolution stays TOTAL — a binding is a module-level value, and raising there
;; would break planning, the test suite, and CI (which has no checkout). The
;; refusal lands at the point of use.
(struct db-binding (label path env from-env? strict?) #:transparent)

;; env-db-binding : string string path #:strict? boolean -> db-binding
;; An empty value counts as unset, so `VAR= racket ...` cannot name the empty path.
(define (env-db-binding label env fallback #:strict? [strict? #f])
  (define v (getenv env))
  (if (and v (not (string=? v "")))
      (db-binding label (string->path v) env #t strict?)
      (db-binding label fallback env #f strict?)))

;; db-binding-description : db-binding boolean -> string
;; The banner's line for one binding, given whether its file exists now. Says
;; where the choice came from, because "which file" is only half the question —
;; the other half is whether anyone MEANT it.
(define (db-binding-description b exists?)
  (format "~a: ~a~a~a"
          (db-binding-label b) (db-binding-path b)
          (if (db-binding-from-env? b)
              (format " (from ~a~a)" (db-binding-env b)
                      ;; Only a chosen path can be relative; the fallbacks are built
                      ;; absolute. Flagged here, refused in executing modes (st-hs7).
                      (if (relative-path? (db-binding-path b))
                          (format ", relative to ~a" (current-directory))
                          ""))
              ;; Shouted only where the fallback can be the wrong file.
              (format " — ~a is unset, so this is the ~a" (db-binding-env b)
                      (if (db-binding-strict? b) "FALLBACK" "default")))
          (if exists? "" " — no such file")))

;; db-binding-refusal : db-binding boolean string -> (or/c string #f)
;; Why a mode that executes tasks must not proceed on this binding, or #f. Two
;; ambiguous cases refuse, and nothing else:
;;   - a RELATIVE chosen path, strict or not (st-hs7). The engine resolves it from
;;     its own cwd, but the tasks get the raw string and resolve it from THEIRS (a
;;     runtime's directory in the project's checkout), so the engine would content-
;;     address one file while the tasks write another, without an error. Making it
;;     absolute here would silently pick one of the two meanings; the caller says
;;     which.
;;   - strict, the fallback, and the fallback exists (st-az9).
;; `mode' is the flag being refused, for the message.
(define (db-binding-refusal b exists? mode)
  (cond
    [(and (db-binding-from-env? b) (relative-path? (db-binding-path b)))
     (define abs (path->complete-path (db-binding-path b)))
     (format (string-append
              "~a is a relative path (~a), which names two files: the engine reads it\n"
              "from ~a, so\n  ~a\n"
              "while the tasks resolve it from their own working directory. A mode that\n"
              "runs tasks does not guess which you mean (st-hs7). Say it absolutely:\n"
              "  ~a=~a racket src/main.rkt ~a ...")
             (db-binding-env b) (db-binding-path b) (current-directory) abs
             (db-binding-env b) abs mode)]
    [else (fallback-refusal b exists? mode)]))

(define (fallback-refusal b exists? mode)
  (and (db-binding-strict? b)
       (not (db-binding-from-env? b))
       exists?
       (format (string-append
                "~a would read the ~a at
  ~a
"
                "because ~a is unset and that is the fallback. A mode that runs tasks
"
                "does not guess which copy you mean: the pipeline you are gating may read
"
                "a different one (st-az9). Say which:
"
                "  ~a=~a racket src/main.rkt ~a ...")
               mode (db-binding-label b) (db-binding-path b) (db-binding-env b)
               (db-binding-env b) (db-binding-path b) mode)))

(struct project (name graph runtimes path
                 resolve-relation resolve-relation-columns resolve-store-keys
                 partial-tasks incremental-tasks edge-verify-tasks
                 source-date-epoch
                 checkout checkout-env
                 default-state-dir
                 history-retention
                 build-log-after-build?
                 databases))

(define (make-project name
                      #:graph graph
                      #:runtimes runtimes
                      #:path path
                      #:resolve-relation [resolve-relation #f]
                      #:resolve-relation-columns [resolve-relation-columns #f]
                      #:resolve-store-keys [resolve-store-keys #f]
                      #:partial-tasks [partial-tasks '()]
                      #:incremental-tasks [incremental-tasks '()]
                      #:edge-verify-tasks [edge-verify-tasks '()]
                      #:source-date-epoch source-date-epoch
                      #:checkout checkout
                      #:checkout-env checkout-env
                      #:default-state-dir default-state-dir
                      #:history-retention [history-retention #f]
                      #:build-log-after-build? [build-log-after-build? #t]
                      #:databases [databases '()])
  (project name graph runtimes path
           resolve-relation resolve-relation-columns resolve-store-keys
           partial-tasks incremental-tasks edge-verify-tasks
           source-date-epoch
           checkout checkout-env
           default-state-dir
           history-retention
           build-log-after-build?
           databases))
