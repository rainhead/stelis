#lang racket/base

;; The salishsea-io build graph (st-ml9): what a logged-out visitor to
;; salishsea.io reads, built as static files from a snapshot of its Supabase
;; database — the first step of taking the query API off the site's read path
;; (salishsea's salish-t3g; the frontend half is salish-t3g.1).
;;
;; Stelis's second project, and deliberately a small one. Slice 1 (st-ml9.2) is
;; the smallest path that exercises the whole shape:
;;
;;   snapshot ──▶ occurrences-snapshot ──▶ occurrence-days ──▶ days/
;;   (boundary)   (db-relation)            (transform)         (one file per
;;                                                              Pacific day)
;;
;; The boundary runs every build — it cannot know whether Postgres changed without
;; asking. What it wrote is content-addressed like any other relation, so a
;; database that did NOT change digests the same and early cutoff skips the rest.
;; salishsea's decision 055 is the problem this answers: a five-minute refresh
;; recomputed all 76k occurrences when about one tick in five changed anything.
;;
;; Transformations stay external (DESIGN): both steps are salishsea's own
;; TypeScript under scripts/read-path/, run at its pinned node. This file only
;; says what reads what.

(require racket/port
         racket/string
         racket/system
         "model.rkt"
         "exec.rkt"
         "project.rkt"
         "relation-digest.rkt")

(provide salishsea-project
         salishsea-graph
         SALISHSEA)

;; Where the salishsea-io checkout lives. Defaults to the author's; SALISHSEA_DIR
;; relocates it (another host, or a worktree).
(define SALISHSEA (or (getenv "SALISHSEA_DIR") "/Users/rainhead/dev/salishsea-io"))
(define (in-checkout . parts) (apply build-path SALISHSEA parts))

;; The snapshot database. Relative in the recipes (the node runtime runs in the
;; checkout) and absolute here, where the engine reads it to content-address it.
;; *.duckdb is gitignored in salishsea.
(define SNAPSHOT-DB-REL "data/read-path.duckdb")
(define snapshot-db (in-checkout SNAPSHOT-DB-REL))

;; --- Runtime ----------------------------------------------------------------
;; salishsea pins node in .nvmrc, and nothing about `node' on PATH carries that
;; pin (this machine's default is 26; salishsea wants 24). Same shape as beeatlas's
;; node runtime and for the same reasons — see its comment there: cd into the
;; checkout, source nvm if present, observe the resolved interpreter by probe.
;;
;; tsx is invoked from node_modules directly rather than through `pnpm exec',
;; which checks the install and may try to fix it — a build must not install.
(define salishsea-runtimes
  (hash 'node (runtime 'node
                       (list "bash" "-c"
                             (string-append
                              "set -e; cd " SALISHSEA "; "
                              "if [ -s \"$HOME/.nvm/nvm.sh\" ]; then "
                              ". \"$HOME/.nvm/nvm.sh\"; nvm use --silent; "
                              "else echo \"WARN: no nvm; node may not match .nvmrc\" >&2; fi; "
                              "exec \"$@\"")
                             "stelis-node")
                       "node/.nvmrc"
                       (list "node" "--version"))))

;; The pins a node task's bytes depend on beyond its own script: the interpreter
;; range, and the lockfile that fixes @duckdb/node-api and tsx.
(define node-code
  (list (in-checkout ".nvmrc")
        (in-checkout "package.json")
        (in-checkout "pnpm-lock.yaml")))

(define (tsx script . args)
  (recipe 'node
          (append (list "node_modules/.bin/tsx" script) args)
          (cons (in-checkout script) node-code)))

;; --- The graph --------------------------------------------------------------

(define artifacts
  (list
   ;; What the snapshot read from Postgres. Derived: it is ours to rebuild from
   ;; the database at any time, and the build never writes back.
   (make-artifact 'occurrences-snapshot 'db-relation)
   ;; One JSON array per Pacific day, newest first — what fetchOccurrences gets
   ;; for that day with no region selected.
   (make-artifact 'days 'dir)))

(define tasks
  (list
   (make-task 'snapshot 'boundary
              #:outputs '(occurrences-snapshot)
              #:invoke (tsx "scripts/read-path/snapshot.ts" SNAPSHOT-DB-REL))
   (make-task 'occurrence-days 'transform
              #:inputs '(occurrences-snapshot)
              #:outputs '(days)
              #:invoke (tsx "scripts/read-path/occurrence-days.ts" SNAPSHOT-DB-REL))))

(define salishsea-graph (build-graph tasks artifacts))

;; --- Where artifacts live, and how relations are addressed ------------------

(define (salishsea-path artifact export-dir)
  (case artifact
    [(days) (build-path export-dir "days")]
    [else #f]))

(define (relation-tables artifact)
  (case artifact
    [(occurrences-snapshot) '("snapshot.occurrences")]
    [else #f]))

(define (resolve-relation artifact)
  (define tables (relation-tables artifact))
  (and tables (file-exists? snapshot-db) (relation-digest snapshot-db tables)))

(define (resolve-relation-columns artifact)
  (define tables (relation-tables artifact))
  (and tables (file-exists? snapshot-db) (relation-columns snapshot-db tables)))

;; --- Build clock (ADR 0004) -------------------------------------------------
;; The committer date of the checkout's HEAD, as for beeatlas; an already-set
;; SOURCE_DATE_EPOCH wins. Nothing in slice 1 stamps a time, but every task gets
;; the clock and the history records it.
(define (salishsea-source-date-epoch)
  (define (epoch? s) (and s (regexp-match? #px"^[0-9]+$" s)))
  (define preset (getenv "SOURCE_DATE_EPOCH"))
  (cond
    [(epoch? preset) preset]
    [else
     (define out
       (with-output-to-string
         (lambda ()
           (parameterize ([current-error-port (open-output-nowhere)])
             (system* (find-executable-path "git")
                      "-C" SALISHSEA "log" "-1" "--format=%ct")))))
     (define trimmed (string-trim out))
     (if (epoch? trimmed)
         trimmed
         (error 'salishsea-source-date-epoch
                "could not read git committer date for ~a" SALISHSEA))]))

;; State defaults into the checkout (st-7f4, decided for new projects 2026-09-27):
;; there is no existing timeline to strand, so the default can mean "this
;; project's" from the first build. salishsea gitignores .stelis/.
(define salishsea-project
  (make-project 'salishsea
                #:graph salishsea-graph
                #:runtimes salishsea-runtimes
                #:path salishsea-path
                #:resolve-relation resolve-relation
                #:resolve-relation-columns resolve-relation-columns
                #:source-date-epoch salishsea-source-date-epoch
                #:checkout (string->path SALISHSEA)
                #:checkout-env "SALISHSEA_DIR"
                #:default-state-dir (in-checkout ".stelis")))
