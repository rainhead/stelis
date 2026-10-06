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
(provide (struct-out project)
         make-project)

(struct project (name graph runtimes path
                 resolve-relation resolve-relation-columns resolve-store-keys
                 partial-tasks incremental-tasks edge-verify-tasks
                 source-date-epoch
                 checkout checkout-env
                 default-state-dir
                 history-retention
                 build-log-after-build?))

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
                      #:build-log-after-build? [build-log-after-build? #t])
  (project name graph runtimes path
           resolve-relation resolve-relation-columns resolve-store-keys
           partial-tasks incremental-tasks edge-verify-tasks
           source-date-epoch
           checkout checkout-env
           default-state-dir
           history-retention
           build-log-after-build?))
