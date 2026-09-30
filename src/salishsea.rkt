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
;;       │                                                      Pacific day)
;;       │                         ├────────▶ occurrence-ids ▶ ids/
;;       │                         │          (transform)       (id → day, in
;;       │                         │                             256 shards, for
;;       │                         │                             ?o= links)
;;       │                         └────────▶ calendar ───▶ calendar/
;;       │                                   (transform)       (day counts per
;;       │                                                      region, one file
;;       │                                                      per Pacific month)
;;       ├──────▶ the catalogue ──────▶ individual-pages ▶ profiles/individuals/
;;       │        (a relation per       matriline-pages ─▶ profiles/matrilines/
;;       │         table)               ecotype-pages ───▶ profiles/ecotypes/
;;       │                              haulout-pages ───▶ profiles/haulouts/
;;       │                              profile-index ───▶ redirects.json,
;;       │                                                  sitemap.xml,
;;       │                                                  catalog-codes.json
;;       │                              (transforms)       (one prerendered page
;;       │                                  ▲               per subject, and its
;;       │                                  │               map's dots)
;;       ├──────▶ snapshot-meta ────────────┴──────▶ manifest ──▶ manifest.json
;;       │        (when it was taken)      (after days/,       (what the build
;;       │                                  calendar/, ids/,     covered)
;;       │                                  the pages)
;;       └──────▶ what the occurrences are derived from (decision 061):
;;                the sources' tables and the reference tables the five
;;                views read, typed, one relation per table. Nothing reads
;;                them yet: the DuckDB port of those views (salish-xv35.2)
;;                will, checked against occurrences-snapshot.
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

;; The snapshot database: in the checkout by default (*.duckdb is gitignored in
;; salishsea), or wherever SALISHSEA_SNAPSHOT_DB says — on the Fly machine, the
;; volume, since the checkout there is the image and does not survive a restart.
;; The recipes and the engine read the same absolute path, so the file a task
;; writes is the file the engine content-addresses.
(define snapshot-db
  (let ([p (getenv "SALISHSEA_SNAPSHOT_DB")])
    (if (and p (not (string=? p ""))) (string->path p) (in-checkout "data" "read-path.duckdb"))))
(define SNAPSHOT-DB (path->string snapshot-db))

;; --- Runtime ----------------------------------------------------------------
;; salishsea pins node in .nvmrc, and nothing about `node' on PATH carries that
;; pin (this machine's default is 26; salishsea wants 24). Same shape as beeatlas's
;; node runtime and for the same reasons — see its comment there: cd into the
;; checkout, source nvm if present, observe the resolved interpreter by probe.
;;
;; The scripts run under plain `node', which strips their TypeScript types
;; itself (salishsea's tsconfig holds them to erasableSyntaxOnly and
;; verbatimModuleSyntax, what that needs). Not tsx: its wrapper process and
;; esbuild service cost ~30 MB beside every task on a 1 GB Fly machine, for a
;; transform node already does. Nor `pnpm exec', which checks the install and
;; may try to fix it — a build must not install.
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
;; range, and the lockfile that fixes @duckdb/node-api and the scripts' other
;; dependencies.
(define node-code
  (list (in-checkout ".nvmrc")
        (in-checkout "package.json")
        (in-checkout "pnpm-lock.yaml")))

(define (node-script script . args)
  (node-script/code script '() args))

;; node-script/code : like node-script, with extra code files the script imports —
;; hashed into the task's address, so editing one reruns it.
(define (node-script/code script extra-code args)
  (recipe 'node
          (append (list "node" script) args)
          (append (list (in-checkout script))
                  (map in-checkout extra-code)
                  node-code)))

;; --- The graph --------------------------------------------------------------

;; The snapshot's catalogue tables, as snapshot.ts names them. Each is one
;; relation, `<table>-snapshot' with hyphens, so --why names the one that moved.
(define catalogue-tables
  '("individuals" "designations" "nicknames" "parties" "social_groups"
    "group_parents" "matriline_members" "animal_names" "haulouts"
    "individual_occurrences" "group_occurrences" "ecotype_occurrences"
    "haulout_occurrences"))

(define (snapshot-relation table)
  (string->symbol (string-append (string-replace table "_" "-") "-snapshot")))

(define catalogue-relations (map snapshot-relation catalogue-tables))

;; What the occurrences are derived from (salishsea decision 061, salish-xv35.1):
;; every table the five views behind derived.occurrences read, the reference tables
;; the functions they call read, the Maplify resolvers' inputs, the stored
;; identifier candidates to check a port against, and the enums' declared orders.
;; snapshot.ts writes each under its Postgres name, typed rather than as documents,
;; so each is named for its table here too: --why names the one that moved, and the
;; per-column observation says which column.
(define derivation-input-tables
  '("maplify.sightings" "maplify.collection_rule"
    "inaturalist.observations" "inaturalist.observation_photos" "inaturalist.taxa"
    "happywhale.encounters" "happywhale.users" "happywhale.individuals"
    "happywhale.species" "happywhale.media"
    "public.observations" "public.observation_photos" "public.contributors"
    "public.acoustic_bouts" "public.acoustic_bout_entities"
    "public.providers" "public.collections" "public.organizations"
    "register.entities" "register.names" "register.mappings"
    "register.ancestor" "register.deprecations"
    "derived.occurrence_identifier_candidates"
    "types.enums"))

(define derivation-input-relations (map string->symbol derivation-input-tables))

;; What each kind of page reads: profiles.ts's INDIVIDUAL_TABLES and its siblings,
;; which load only these, so each task's inputs are exactly what it reads.
(define individual-page-relations
  (map snapshot-relation
       '("individuals" "designations" "nicknames" "parties" "social_groups"
         "group_parents" "matriline_members" "animal_names" "individual_occurrences")))
(define matriline-page-relations
  (map snapshot-relation
       '("social_groups" "group_parents" "nicknames" "parties" "individuals"
         "matriline_members" "group_occurrences")))
(define ecotype-page-relations
  (map snapshot-relation '("social_groups" "group_parents" "ecotype_occurrences")))
(define haulout-page-relations
  (map snapshot-relation '("haulouts" "haulout_occurrences")))
(define profile-index-relations
  (map snapshot-relation '("individuals" "designations" "social_groups" "haulouts")))

;; A kind's page task. Its code is profiles.ts's import closure (esbuild's
;; metafile, not a grep: all three kinds' templates, since one script renders
;; them), the kind's Vite-built shell, and Vite's manifest, which names the map
;; island's files. The shell and the manifest are code here rather than artifacts
;; because the site build that writes dist/ is outside the graph (the image's, on
;; Fly), and the pages must rerun when either changes.
;;
;; The year the presence table ends on is the snapshot's, which is why
;; snapshot-meta is an input — and why each reruns every build (its bytes still
;; cut off unless something moved).
(define (profile-pages-task name kind shell relations output)
  (make-task name 'transform
             #:inputs (cons 'snapshot-meta relations)
             #:outputs (list output)
             #:invoke (node-script/code "scripts/read-path/profiles.ts"
                                (list "scripts/read-path/profile-document.ts"
                                      "scripts/read-path/replace-dir.ts"
                                      "scripts/read-path/snapshot-tables.ts"
                                      "src/individual-profile.ts" "src/matriline-profile.ts"
                                      "src/date-format.ts"
                                      "src/ecotype-profile.ts" "src/haulout-profile.ts"
                                      "src/profile-shared.ts"
                                      "src/catalog.ts" "src/fold.ts" "src/supabase.ts"
                                      (string-append "dist/" shell) "dist/.vite/manifest.json")
                                (list kind SNAPSHOT-DB (path->string (in-checkout "dist"))))))

(define artifacts
  (list*
   ;; What the snapshot read from Postgres. Derived: it is ours to rebuild from
   ;; the database at any time, and the build never writes back.
   (make-artifact 'occurrences-snapshot 'db-relation)
   ;; When the snapshot was taken, read before anything else. A separate relation
   ;; so that it moving on every build does not move the occurrences' digest:
   ;; the day files still cut off when the data hasn't changed.
   (make-artifact 'snapshot-meta 'db-relation)
   ;; One JSON array per Pacific day, newest first — what fetchOccurrences gets
   ;; for that day with no region selected.
   (make-artifact 'days 'dir)
   ;; The calendar's day counts, one file per Pacific month, per region — what
   ;; the occurrence_days RPC returns (decision 056).
   (make-artifact 'calendar 'dir)
   ;; Which day each occurrence is on, sharded by a hash of its id, so a ?o=
   ;; link opens without asking the database (decision 056).
   (make-artifact 'ids 'dir)
   ;; What the last build covered (salish-t3g.4): the frontend reads a missing
   ;; day file as empty only for a covered day, and watches it for new builds.
   ;; It changes every build by design, since the snapshot time does.
   (make-artifact 'manifest.json 'file)
   ;; Each subject's page as HTML, and beside it the sighting links its map loads
   ;; (decision 057), one dir per kind: profiles/individuals/ and its siblings,
   ;; never profiles/ itself, so no kind's extent holds another's.
   (make-artifact 'individual-pages 'dir)
   (make-artifact 'matriline-pages 'dir)
   (make-artifact 'ecotype-pages 'dir)
   (make-artifact 'haulout-pages 'dir)
   ;; Where the profiles live, for what finds them rather than renders them
   ;; (salishsea decision 057, step 5): each designation, folded, to its page —
   ;; the redirect server on Fly answers legacy /individuals/T65A links from it —
   ;; and the sitemap, Vite's own entries with every published profile after them.
   (make-artifact 'redirects.json 'file)
   (make-artifact 'sitemap.xml 'file)
   ;; The rows the map's sighting cards link designations from (T065A to her
   ;; page), so those links survive the database being unreachable.
   (make-artifact 'catalog-codes.json 'file)
   ;; What the profile pages show (salishsea decision 057): the catalogue, and the
   ;; views linking a subject to its sightings. All of what the snapshot writes is
   ;; declared, including the relations no page reads yet.
   (append
    (for/list ([name (in-list catalogue-relations)])
      (make-artifact name 'db-relation))
    ;; What the occurrences are derived from (decision 061). Derived, like the rest
    ;; of the snapshot: the database holds the originals.
    (for/list ([name (in-list derivation-input-relations)])
      (make-artifact name 'db-relation)))))

(define tasks
  (list
   (make-task 'snapshot 'boundary
              #:outputs (list* 'occurrences-snapshot 'snapshot-meta
                               (append catalogue-relations derivation-input-relations))
              #:invoke (node-script "scripts/read-path/snapshot.ts" SNAPSHOT-DB))
   (make-task 'occurrence-days 'transform
              #:inputs '(occurrences-snapshot)
              #:outputs '(days)
              #:invoke (node-script/code "scripts/read-path/occurrence-days.ts"
                                 '("scripts/read-path/replace-dir.ts")
                                 (list SNAPSHOT-DB)))
   ;; The region boxes are the map's own, so the files they come from are code.
   (make-task 'calendar 'transform
              #:inputs '(occurrences-snapshot)
              #:outputs '(calendar)
              #:invoke (node-script/code "scripts/read-path/calendar.ts"
                                 '("scripts/read-path/replace-dir.ts"
                                   "src/constants.ts" "src/extents.ts")
                                 (list SNAPSHOT-DB)))
   ;; The shard hash is shared with the browser, so it is code: change it and
   ;; every id moves, which must rebuild the index.
   (make-task 'occurrence-ids 'transform
              #:inputs '(occurrences-snapshot)
              #:outputs '(ids)
              #:invoke (node-script/code "scripts/read-path/occurrence-ids.ts"
                                 '("scripts/read-path/replace-dir.ts" "src/read-path-shard.ts")
                                 (list SNAPSHOT-DB)))
   ;; The profile pages: the shared templates filled from the snapshot, inside
   ;; the shell Vite built (salishsea decision 057).
   (profile-pages-task 'individual-pages "individuals" "individual.html"
                       individual-page-relations 'individual-pages)
   (profile-pages-task 'matriline-pages "matrilines" "matriline.html"
                       matriline-page-relations 'matriline-pages)
   (profile-pages-task 'ecotype-pages "ecotypes" "ecotype.html"
                       ecotype-page-relations 'ecotype-pages)
   (profile-pages-task 'haulout-pages "haulouts" "haulout.html"
                       haulout-page-relations 'haulout-pages)
   ;; No snapshot-meta: nothing here depends on when the snapshot was taken, so
   ;; unlike the pages this cuts off whenever the catalogue holds still. Vite's
   ;; sitemap is code, like the pages' shells, for the same reason.
   (make-task 'profile-index 'transform
              #:inputs profile-index-relations
              #:outputs '(redirects.json sitemap.xml catalog-codes.json)
              #:invoke (node-script/code "scripts/read-path/profile-index.ts"
                                 '("scripts/read-path/profile-document.ts"
                                   "scripts/read-path/snapshot-tables.ts"
                                   "scripts/read-path/redirect-keys.ts"
                                   "src/catalog.ts" "src/fold.ts" "src/supabase.ts"
                                   "dist/sitemap.xml")
                                 (list SNAPSHOT-DB (path->string (in-checkout "dist")))))
   ;; Takes days, calendar, ids and the pages as inputs only for their ORDER: the
   ;; manifest must never claim a build whose files are not yet in place, and a
   ;; failed export must leave the last manifest standing. It reads none of them.
   (make-task 'manifest 'transform
              #:inputs '(snapshot-meta days calendar ids
                         individual-pages matriline-pages ecotype-pages haulout-pages
                         redirects.json sitemap.xml catalog-codes.json)
              #:outputs '(manifest.json)
              #:invoke (node-script "scripts/read-path/manifest.ts" SNAPSHOT-DB))))

(define salishsea-graph (build-graph tasks artifacts))

;; --- Where artifacts live, and how relations are addressed ------------------

(define (salishsea-path artifact export-dir)
  (case artifact
    [(days) (build-path export-dir "days")]
    [(manifest.json) (build-path export-dir "manifest.json")]
    [(calendar) (build-path export-dir "calendar")]
    [(ids) (build-path export-dir "ids")]
    [(individual-pages) (build-path export-dir "profiles" "individuals")]
    [(matriline-pages) (build-path export-dir "profiles" "matrilines")]
    [(ecotype-pages) (build-path export-dir "profiles" "ecotypes")]
    [(haulout-pages) (build-path export-dir "profiles" "haulouts")]
    [(redirects.json) (build-path export-dir "redirects.json")]
    [(sitemap.xml) (build-path export-dir "sitemap.xml")]
    [(catalog-codes.json) (build-path export-dir "catalog-codes.json")]
    [else #f]))

(define (relation-tables artifact)
  (case artifact
    [(occurrences-snapshot) '("snapshot.occurrences")]
    [(snapshot-meta) '("snapshot.meta")]
    [else
     (cond
       [(memq artifact derivation-input-relations) (list (symbol->string artifact))]
       [else
        (for/first ([table (in-list catalogue-tables)]
                    #:when (eq? artifact (snapshot-relation table)))
          (list (string-append "snapshot." table)))])]))

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
