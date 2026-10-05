#lang racket/base

;; The salishsea-io build graph (st-ml9): what a logged-out visitor to
;; salishsea.io reads, built as static files from a snapshot of its Supabase
;; database — the first step of taking the query API off the site's read path
;; (salishsea's salish-t3g; the frontend half is salish-t3g.1).
;;
;; Stelis's second project. The shape, since salishsea's step 3 moved the
;; derivation and the upstream ingests into the build (decision 061, salish-xv35):
;;
;;   ingest-maplify ─────▶ maplify_mirror.*  ──┐   (boundaries: each source's own
;;   ingest-inaturalist ─▶ inaturalist_mirror.*┤    fetch, into a SQLite mirror
;;   ingest-orcasound ───▶ orcasound.*  ───────┤    holding only what it said)
;;                                             │
;;   reference ─▶ the reference tables ────────┤   (checked-in files under data/
;;                                             │    reference/, decision 064)
;;   snapshot ──▶ what Postgres still holds ───┤   (native sightings, Happywhale,
;;   (boundary)   (the register, the catalogue,│    the register, the catalogue;
;;       │         native sightings)           │    nothing of the three sources)
;;       │              │                      │
;;       │              ▼                      ▼
;;       │        maplify-names ──▶ derive-occurrences ──▶ build.occurrences
;;       │        (gate: every Maplify      (DuckDB twins of            │
;;       │         name Postgres named,      Postgres's five views)    │
;;       │         the register still names)                           │
;;       │      ┌──────────────────┬──────────────────┬────────────────┤
;;       │      ▼                  ▼                  ▼                ▼
;;       │  occurrence-days    calendar     occurrence-ids   derive-identifier-candidates
;;       │   ▶ days/          ▶ calendar/      ▶ ids/              ▼
;;       │                                              derive-profile-links
;;       │                                              ▶ build.individual_occurrences
;;       │                                                and its three siblings
;;       ├──────▶ the catalogue ──────▶ individual-pages ▶ profiles/individuals/
;;       │        (a relation per       matriline-pages ─▶ profiles/matrilines/
;;       │         table) + the links   ecotype-pages ───▶ profiles/ecotypes/
;;       │                              haulout-pages ───▶ profiles/haulouts/
;;       │                              profile-index ───▶ redirects.json,
;;       │                                                  sitemap.xml,
;;       │                                                  catalog-codes.json
;;       ├──────▶ snapshot-year ──────▶ (the pages)
;;       └──────▶ snapshot-meta ──────▶ manifest ──▶ manifest.json
;;                (when it was taken)   (after every published file)
;;
;; salishsea.io itself reads these files (salish-xv35.16). Postgres stopped ingesting
;; all three sources (salish-xv35.9: iNaturalist and Orcasound on 2026-10-04, Maplify
;; the day after); its copies stay frozen, read only by the twin test.
;; The boundary runs every build — it cannot know whether Postgres changed without
;; asking. What it wrote is content-addressed like any other relation, so a
;; database that did NOT change digests the same and early cutoff skips the rest.
;; salishsea's decision 055 is the problem this answers: a five-minute refresh
;; recomputed all 76k occurrences when about one tick in five changed anything.
;;
;; Transformations stay external (DESIGN): both steps are salishsea's own
;; TypeScript under scripts/read-path/, run at its pinned node. This file only
;; says what reads what.

(require racket/list
         racket/port
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

;; Each upstream source's mirror, once the build ingests it itself (salishsea decision
;; 061): a SQLite file beside the snapshot, never in the export, so nothing serves it.
;; Derived: a lost mirror costs one fetch.
(define mirror-dir (build-path (let-values ([(dir _n _d) (split-path snapshot-db)]) dir) "mirrors"))
(define orcasound-mirror (build-path mirror-dir "orcasound.sqlite"))
(define maplify-mirror (build-path mirror-dir "maplify.sqlite"))
(define inaturalist-mirror (build-path mirror-dir "inaturalist.sqlite"))

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
    "group_parents" "matriline_members" "animal_names" "haulouts"))

;; The relations a mirror holds, each named "<source>.<table>", as the mirror is attached
;; under the source's name.
(define orcasound-relations '(orcasound.bouts orcasound.bout_entities))
;; Maplify's mirror is attached as maplify_mirror, not maplify: the snapshot named
;; Postgres's copy maplify.sightings while both ingested, and the twin test still does.
(define maplify-relations '(maplify_mirror.sightings maplify_mirror.covered_days))
;; iNaturalist's, attached as inaturalist_mirror for the same reason.
(define inaturalist-relations
  '(inaturalist_mirror.observations inaturalist_mirror.observation_photos inaturalist_mirror.taxa
    inaturalist_mirror.covered_days inaturalist_mirror.sync))

(define (snapshot-relation table)
  (string->symbol (string-append (string-replace table "_" "-") "-snapshot")))

(define catalogue-relations (map snapshot-relation catalogue-tables))

;; What the occurrences were derived from in Postgres (salishsea decision 061,
;; salish-xv35.1): every table the five views behind derived.occurrences read, the
;; reference tables the functions they call read, the Maplify resolvers' inputs, and
;; the enums' declared orders; and the identifications people assert, which the
;; profile pages' link views start from (salish-xv35.13). Postgres stopped ingesting
;; all three sources (salish-xv35.9), so none of their tables is read — the iNaturalist
;; taxa were the last, until the mirror held every taxon the register names
;; (salish-xv35.9.3), and Maplify's table the last of the sources, read by the overlap
;; report and the name guard's bootstrap until Postgres's Maplify ingest stopped. The
;; derivation reads the mirrors instead.
;; snapshot.ts writes each under its Postgres name, typed rather than as documents,
;; so each is named for its table here too: --why names the one that moved, and the
;; per-column observation says which column.
(define snapshot-input-tables
  '("happywhale.encounters" "happywhale.users" "happywhale.individuals"
    "happywhale.species" "happywhale.media"
    "public.observations" "public.observation_photos" "public.contributors"
    "public.identifications"
    "register.entities" "register.names" "register.mappings"
    "register.ancestor" "register.deprecations" "register.classification"))

;; The reference tables (salishsea decision 064, salish-9uu.2.1): providers,
;; organizations, collections, Maplify's collection rules and the enums' declared
;; orders. Migrations wrote them and nothing in the app does, so they are checked-in
;; files under data/reference/ now, loaded into the snapshot database under the same
;; Postgres names by the reference task, and the derivation reads them unchanged.
(define reference-tables
  '("public.providers" "public.organizations" "public.collections"
    "maplify.collection_rule" "types.enums"))
(define reference-relations (map string->symbol reference-tables))
;; Each table's file, as a declared input nobody in the graph writes.
(define reference-files
  '(reference/providers.tsv reference/organizations.tsv reference/collections.tsv
    reference/maplify-collection-rules.tsv reference/enums.tsv))

(define snapshot-input-relations (map string->symbol snapshot-input-tables))
;; Everything the derivations read besides the mirrors: what the snapshot copies from
;; Postgres and what the reference task loads from the files.
(define derivation-input-tables (append snapshot-input-tables reference-tables))
(define derivation-input-relations (map string->symbol derivation-input-tables))

;; The upstream sources as the build's own mirrors hold them (salish-xv35.9), which the
;; derivation reads in place of Postgres's copies (salishsea's derive/sources.sql).
;; iNaturalist's taxa too: the mirror holds those its observations reach AND those the
;; register names (fetched from the register's mappings, salish-xv35.9.3), and re-asks
;; upstream about a few of the longest-unchecked each run.
(define mirror-source-relations
  '(maplify_mirror.sightings
    inaturalist_mirror.observations inaturalist_mirror.observation_photos inaturalist_mirror.taxa
    orcasound.bouts orcasound.bout_entities))

;; What derive-occurrences reads: the mirrors for the three sources, the snapshot for the
;; rest, but not the identifications, which only the profile links read, nor the register's
;; classification, which only the Darwin Core archive reads; and the name
;; guard's token, so a register that un-names Maplify sightings stops the derivation.
(define occurrence-derivation-inputs
  (append (remq* '(maplify.sightings public.identifications register.classification)
                 derivation-input-relations)
          mirror-source-relations
          '(maplify-names-hold)))

;; The mirrors, as the derivations take them: maplify, inaturalist, orcasound.
(define MIRRORS
  (map path->string (list maplify-mirror inaturalist-mirror orcasound-mirror)))

;; The profile pages' link views, each twinned under build. by derive-profile-links
;; (salish-xv35.13); the pages read the twins.
(define profile-link-tables
  '("individual_occurrences" "group_occurrences" "ecotype_occurrences" "haulout_occurrences"))
(define profile-link-relations
  (for/list ([table (in-list profile-link-tables)])
    (string->symbol (string-append "build." table))))

;; What each kind of page reads: profiles.ts's INDIVIDUAL_TABLES and its siblings,
;; which load only these, so each task's inputs are exactly what it reads.
(define individual-page-relations
  (append (map snapshot-relation
               '("individuals" "designations" "nicknames" "parties" "social_groups"
                 "group_parents" "matriline_members" "animal_names"))
          '(build.individual_occurrences)))
(define matriline-page-relations
  (append (map snapshot-relation
               '("social_groups" "group_parents" "nicknames" "parties" "individuals"
                 "matriline_members"))
          '(build.group_occurrences)))
(define ecotype-page-relations
  (append (map snapshot-relation '("social_groups" "group_parents"))
          '(build.ecotype_occurrences)))
(define haulout-page-relations
  (append (map snapshot-relation '("haulouts"))
          '(build.haulout_occurrences)))
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
;; snapshot-year is an input: the Pacific year alone, not snapshot-meta's moment,
;; so a build in the same year that changed none of a kind's tables skips it
;; (salish-xv35.12) rather than rerunning it to identical bytes.
(define (profile-pages-task name kind shell relations output)
  (make-task name 'transform
             #:inputs (cons 'snapshot-year relations)
             #:outputs (list output)
             #:invoke (node-script/code "scripts/read-path/profiles.ts"
                                (list "scripts/read-path/profile-document.ts"
                                      "scripts/read-path/replace-dir.ts"
                                      "scripts/read-path/snapshot-tables.ts"
                                      "scripts/read-path/duckdb-budget.ts"
                                      "src/individual-profile.ts" "src/matriline-profile.ts"
                                      "src/date-format.ts"
                                      "src/ecotype-profile.ts" "src/haulout-profile.ts"
                                      "src/profile-shared.ts"
                                      "src/catalog.ts" "src/fold.ts" "src/supabase.ts"
                                      (string-append "dist/" shell) "dist/.vite/manifest.json")
                                (list kind SNAPSHOT-DB (path->string (in-checkout "dist"))))))

(define artifacts
  (list*
   ;; When the snapshot was taken, read before anything else. A separate relation
   ;; so that it moving on every build does not move the occurrences' digest:
   ;; the day files still cut off when the data hasn't changed.
   (make-artifact 'snapshot-meta 'db-relation)
   ;; The Pacific year it was taken in, all the profile pages read of when: moves
   ;; once a year where snapshot-meta moves every build (salish-xv35.12).
   (make-artifact 'snapshot-year 'db-relation)
   ;; The UTC day it was taken on, which the Darwin Core archive is dated by: moves once a
   ;; day, so the archive reruns when its data changes or the date does, not every build.
   (make-artifact 'snapshot-day 'db-relation)
   ;; The Darwin Core archive GBIF crawls (salish-xv35.9): the zip, its GeoParquet
   ;; sidecar and their checksums, at /dwca/ as the nightly workflow published them.
   (make-artifact 'dwca 'dir)
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
   ;; What the profile pages show of the catalogue (salishsea decision 057). All of
   ;; what the snapshot writes is declared, including the relations no page reads yet.
   (append
    (for/list ([name (in-list catalogue-relations)])
      (make-artifact name 'db-relation))
    ;; What the occurrences are derived from (decision 061). Derived, like the rest
    ;; of the snapshot: the database or the checked-in files hold the originals.
    (for/list ([name (in-list derivation-input-relations)])
      (make-artifact name 'db-relation))
    (list
     ;; The occurrences as the build derives them (salish-xv35.2): id, observed_at
     ;; and the document to_jsonb would write. Written into the snapshot file, under
     ;; build., beside what it was derived from. What every published file reads
     ;; (salish-xv35.9).
     (make-artifact 'build.occurrences 'db-relation)
     ;; That every Maplify name Postgres resolved still resolves in the register the
     ;; build was given.
     (make-artifact 'maplify-names-hold 'token)
     ;; The guard's baseline: the last PASSING build's answers, which the next build is
     ;; judged against (salish-xv35.9.2). Forward-only — each pass rewrites it from the
     ;; one before, and once Postgres stops resolving Maplify nothing can regenerate it
     ;; — so 'authoritative, written by a task in this graph (ADR 0013's 'either arm).
     ;; Declared so the graph names its producer and extent, not so the cache can
     ;; address it: an authoritative output is excluded from cutoff by design.
     (make-artifact 'maplify-names.json 'file #:provenance 'authoritative)
     ;; The pairs a curator has accepted as un-named (data/maplify-unnamed.tsv): a
     ;; checked-in decision record, written by a person with git, that the guard reads
     ;; — so an acceptance clears the hold by a declared input moving. Producerless and
     ;; forward-only: ADR 0013's other 'authoritative arm.
     (make-artifact 'maplify-unnamed.tsv 'file #:provenance 'authoritative)
     ;; The reference tables' files (decision 064): checked in, edited by a curator's
     ;; pull request, so producerless and forward-only like the allow-list above.
     (make-artifact 'reference/providers.tsv 'file #:provenance 'authoritative)
     (make-artifact 'reference/organizations.tsv 'file #:provenance 'authoritative)
     (make-artifact 'reference/collections.tsv 'file #:provenance 'authoritative)
     (make-artifact 'reference/maplify-collection-rules.tsv 'file #:provenance 'authoritative)
     (make-artifact 'reference/enums.tsv 'file #:provenance 'authoritative)
     ;; Orcasound's bouts as the build fetches them itself (salish-xv35.6).
     (make-artifact 'orcasound.bouts 'db-relation)
     (make-artifact 'orcasound.bout_entities 'db-relation)
     ;; Maplify's sightings as the build fetches them (salish-xv35.7): every one Maplify
     ;; returned for each window, in the map's scope or not, and the days fetched.
     (make-artifact 'maplify_mirror.sightings 'db-relation)
     (make-artifact 'maplify_mirror.covered_days 'db-relation)
     ;; iNaturalist's observations as the build fetches them (salish-xv35.8): every one in
     ;; the fetch box, their photos, the taxa they reach, the days reconciled, and how far
     ;; the changes sweep has read (sync).
     (make-artifact 'inaturalist_mirror.observations 'db-relation)
     (make-artifact 'inaturalist_mirror.observation_photos 'db-relation)
     (make-artifact 'inaturalist_mirror.taxa 'db-relation)
     (make-artifact 'inaturalist_mirror.covered_days 'db-relation)
     (make-artifact 'inaturalist_mirror.sync 'db-relation)
     ;; Which individual or matriline each designation an occurrence names means
     ;; (salish-xv35.3), as the build derives it.
     (make-artifact 'build.occurrence_identifier_candidates 'db-relation))
    ;; Which sightings each individual, matriline, ecotype and haul-out site was seen
    ;; in (salish-xv35.13), as the build derives them: one relation per view twinned,
    ;; each holding documents in the shape of the snapshot's copy of that view.
    (for/list ([name (in-list profile-link-relations)])
      (make-artifact name 'db-relation)))))

(define tasks
  (list
   (make-task 'snapshot 'boundary
              #:outputs (list* 'snapshot-meta 'snapshot-year 'snapshot-day
                               (append catalogue-relations snapshot-input-relations))
              #:invoke (node-script/code "scripts/read-path/snapshot.ts"
                                 '("scripts/read-path/duckdb-budget.ts")
                                 (list SNAPSHOT-DB)))
   ;; The reference tables from their checked-in files (decision 064): a transform, not
   ;; a boundary, since its inputs are declared files. Into the snapshot database, which
   ;; the snapshot attaches rather than recreates, so neither erases the other's tables.
   (make-task 'reference 'transform
              #:inputs reference-files
              #:outputs reference-relations
              #:invoke (node-script/code "scripts/read-path/reference.ts" '()
                                 (list SNAPSHOT-DB)))
   (make-task 'occurrence-days 'transform
              #:inputs '(build.occurrences)
              #:outputs '(days)
              #:invoke (node-script/code "scripts/read-path/occurrence-days.ts"
                                 '("scripts/read-path/replace-dir.ts" "scripts/read-path/duckdb-budget.ts")
                                 (list SNAPSHOT-DB)))
   ;; The region boxes are the map's own, so the files they come from are code.
   (make-task 'calendar 'transform
              #:inputs '(build.occurrences)
              #:outputs '(calendar)
              #:invoke (node-script/code "scripts/read-path/calendar.ts"
                                 '("scripts/read-path/replace-dir.ts" "scripts/read-path/duckdb-budget.ts"
                                   "src/constants.ts" "src/extents.ts")
                                 (list SNAPSHOT-DB)))
   ;; The shard hash is shared with the browser, so it is code: change it and
   ;; every id moves, which must rebuild the index.
   (make-task 'occurrence-ids 'transform
              #:inputs '(build.occurrences)
              #:outputs '(ids)
              #:invoke (node-script/code "scripts/read-path/occurrence-ids.ts"
                                 '("scripts/read-path/replace-dir.ts" "src/read-path-shard.ts"
                                   "scripts/read-path/duckdb-budget.ts")
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
                                   "scripts/read-path/duckdb-budget.ts"
                                   "scripts/read-path/redirect-keys.ts"
                                   "src/catalog.ts" "src/fold.ts" "src/supabase.ts"
                                   "dist/sitemap.xml")
                                 (list SNAPSHOT-DB (path->string (in-checkout "dist")))))
   ;; A register edition that loses a name would quietly drop every Maplify sighting
   ;; that used it, since the derivation resolves names from the register it is given.
   ;; This fails when the build's own rule can no longer name a pair the last passing
   ;; build named (its baseline, maplify-names.json), before the derivation, so the last
   ;; good files stand. Only pairs the mirror still holds count: a sighting Maplify no
   ;; longer returns isn't on the map to lose. The register-refresh workflow asks the
   ;; same question of an edition before loading it, so this is the backstop.
   (make-task 'maplify-names 'gate
              #:inputs '(maplify_mirror.sightings register.entities register.names
                         register.ancestor register.deprecations maplify-unnamed.tsv)
              #:outputs '(maplify-names-hold maplify-names.json)
              #:invoke (node-script/code "scripts/read-path/check-maplify-names.ts"
                                 '("scripts/ingest/maplify.ts" "scripts/register/name-index.ts"
                                   "scripts/register/unnamed.ts"
                                   "src/extents.ts" "src/fold.ts" "scripts/read-path/duckdb-budget.ts")
                                 (list SNAPSHOT-DB (path->string maplify-mirror)
                                       "--allow" (path->string (build-path SALISHSEA "data" "maplify-unnamed.tsv")))))
   ;; The five per-source Postgres views behind derived.occurrences, as DuckDB SQL
   ;; (salishsea decision 061), reading Maplify, iNaturalist and Orcasound from the
   ;; build's mirrors (salish-xv35.9) through derive/sources.sql. Its two regex
   ;; extractions run in node first, since RE2 can't express Postgres's word
   ;; boundaries, and so does Maplify's entity resolution, which is the ingest's own
   ;; resolveEntity over the register's name index (salish-xv35.11). The code list is
   ;; the script's esbuild import closure; the SQL is read, not imported, so it is
   ;; listed by hand.
   (make-task 'derive-occurrences 'transform
              #:inputs occurrence-derivation-inputs
              #:outputs '(build.occurrences)
              #:invoke (node-script/code "scripts/read-path/derive-occurrences.ts"
                                 '("scripts/read-path/derive/extract.sql"
                                   "scripts/read-path/derive/sources.ts"
                                   "scripts/read-path/derive/sources.sql"
                                   "scripts/read-path/derive/maplify-entities.ts"
                                   "scripts/read-path/derive/inaturalist-scope.ts"
                                   "scripts/ingest/maplify.ts" "scripts/ingest/inaturalist.ts"
                                   "scripts/register/name-index.ts"
                                   "src/fold.ts" "src/extents.ts"
                                   "scripts/read-path/duckdb-budget.ts"
                                   "scripts/read-path/derive/shared.sql"
                                   "scripts/read-path/derive/lookups.sql"
                                   "scripts/read-path/derive/occurrences.sql")
                                 (list* SNAPSHOT-DB MIRRORS)))
   ;; Postgres's derived.identifier_candidates as DuckDB SQL: each designation an
   ;; occurrence names, paired with the catalogue's individual or matriline. Reads the
   ;; occurrences the build derived, so it is a port of the whole chain;
   ;; register.fold's twin is in the SQL, read rather than imported.
   (make-task 'derive-identifier-candidates 'transform
              #:inputs '(build.occurrences social-groups-snapshot designations-snapshot)
              #:outputs '(build.occurrence_identifier_candidates)
              #:invoke (node-script/code "scripts/read-path/derive-identifier-candidates.ts"
                                 '("scripts/read-path/duckdb-budget.ts"
                                   "scripts/read-path/derive/identifier-candidates.sql")
                                 (list SNAPSHOT-DB)))
   ;; The four views a profile page's map reads (salish-xv35.13), as DuckDB SQL over the
   ;; occurrences and candidates the build derived, the identifications people assert,
   ;; Orcasound's bout entities (from its mirror) and the catalogue. A haul-out report's distance is
   ;; PostGIS's spheroidal one, measured in node with GeographicLib, which PostGIS
   ;; calls, rather than with DuckDB's spatial extension on a 1 GB machine.
   (make-task 'derive-profile-links 'transform
              #:inputs '(build.occurrences build.occurrence_identifier_candidates
                         public.identifications orcasound.bout_entities
                         register.entities register.deprecations register.ancestor
                         inaturalist_mirror.taxa
                         individuals-snapshot social-groups-snapshot matriline-members-snapshot
                         haulouts-snapshot)
              #:outputs profile-link-relations
              #:invoke (node-script/code "scripts/read-path/derive-profile-links.ts"
                                 '("scripts/read-path/derive/haulout-distance.ts"
                                   "scripts/read-path/derive/sources.ts"
                                   "scripts/read-path/derive/sources.sql"
                                   "scripts/read-path/duckdb-budget.ts"
                                   "scripts/read-path/derive/shared.sql"
                                   "scripts/read-path/derive/haulout-nearby.sql"
                                   "scripts/read-path/derive/profile-links.sql")
                                 (list* SNAPSHOT-DB MIRRORS)))
   ;; Orcasound's whole corpus, fetched by the build (salishsea decision 061, step B):
   ;; the same fetch shell and pure core as the Supabase function, written to a SQLite
   ;; mirror whole and atomically, nothing written unless the fetch is complete. A fetch that
   ;; fails leaves the mirror as it was and exits 0, recording the failure in the run log
   ;; beside the mirrors (ingest-runs.ts), so a source being down never stops the build
   ;; publishing everything else; the same holds for Maplify and iNaturalist below. It
   ;; reports through the boundary receipt whether the corpus changed.
   (make-task 'ingest-orcasound 'boundary
              #:outputs orcasound-relations
              #:invoke (node-script/code "scripts/read-path/ingest-orcasound.ts"
                                 '("scripts/read-path/ingest-runs.ts" "scripts/ingest/fetch-orcasound.ts" "scripts/ingest/orcasound.ts"
                                   "scripts/ingest/retry.ts")
                                 (list (path->string orcasound-mirror))))
   ;; Maplify's windows, fetched by the build (salishsea decision 061, salish-xv35.7): the
   ;; thirty days ending today and one older month for anti-entropy (salish-xv35.15),
   ;; each reconciled into a SQLite mirror in one transaction, nothing written unless the
   ;; response parses whole. Everything Maplify returned is kept;
   ;; which sightings are in the map's scope is the derivation's call (Peter, 2026-10-02).
   ;; A backfill is the same script with a start and end, run by hand.
   (make-task 'ingest-maplify 'boundary
              #:outputs maplify-relations
              #:invoke (node-script/code "scripts/read-path/ingest-maplify.ts"
                                 '("scripts/read-path/ingest-runs.ts" "scripts/ingest/fetch-maplify.ts" "scripts/ingest/maplify.ts"
                                   "scripts/ingest/retry.ts" "scripts/ingest/window.ts"
                                   "scripts/read-path/windows.ts"
                                   "scripts/register/name-index.ts" "src/extents.ts" "src/fold.ts")
                                 (list (path->string maplify-mirror))))
;; iNaturalist, fetched by the build (salishsea decision 061, salish-xv35.8): what changed
   ;; since the last run (updated_since, which is how a late upload arrives), the last ten
   ;; days and one older month reconciled for deletions, every observation in the fetch box
   ;; kept with its photos and the taxa it reaches. A handful of requests a run, a second
   ;; apart, within iNaturalist's asked-for pace. A backfill is the same script with a start
   ;; and end, run by hand. It also keeps the mirror's taxa whole and current
   ;; (salish-xv35.9.3): every taxon the register's mappings name is fetched with its
   ;; ancestors — so the register is an input, and this boundary runs after the snapshot —
   ;; and a handful of the longest-unchecked are re-asked of upstream each run.
   (make-task 'ingest-inaturalist 'boundary
              #:inputs '(register.mappings)
              #:outputs inaturalist-relations
              #:invoke (node-script/code "scripts/read-path/ingest-inaturalist.ts"
                                 '("scripts/read-path/ingest-runs.ts" "scripts/ingest/fetch-inaturalist.ts" "scripts/ingest/inaturalist.ts"
                                   "scripts/ingest/retry.ts" "scripts/ingest/window.ts"
                                   "scripts/read-path/windows.ts" "src/extents.ts"
                                   "scripts/read-path/duckdb-budget.ts")
                                 (list (path->string inaturalist-mirror) "--register" SNAPSHOT-DB)))
   ;; The Darwin Core archive (salish-xv35.9), which a nightly workflow built from
   ;; Postgres's dwc views until Postgres stopped ingesting Maplify. derive/dwc.sql's
   ;; twins of those views, over the same lookups and Maplify resolution the occurrences
   ;; use, written by the nightly's own archive writer after the nightly's own checks.
   ;; Behind the name guard, like the occurrences: a register that un-names Maplify
   ;; sightings would drop them from the archive too. It reads Maplify and native
   ;; sightings only (iNaturalist and Happywhale publish to GBIF themselves), so neither
   ;; of those is an input. Dated by the snapshot's day.
   (make-task 'dwca 'transform
              #:inputs '(snapshot-day maplify-names-hold
                         maplify_mirror.sightings maplify.collection_rule
                         inaturalist_mirror.taxa
                         public.observations public.observation_photos public.contributors
                         public.providers public.collections public.organizations
                         register.entities register.names register.mappings register.ancestor
                         register.deprecations register.classification types.enums)
              #:outputs '(dwca)
              #:invoke (node-script/code "scripts/read-path/dwca.ts"
                                 '("scripts/dwca/assertions.ts" "scripts/dwca/build.ts" "scripts/dwca/eml.ts"
                                   "scripts/dwca/fields.ts" "scripts/dwca/guard.ts" "scripts/dwca/meta-xml.ts"
                                   "scripts/dwca/verify-artifact.ts" "scripts/dwca/zip.ts"
                                   "scripts/ingest/maplify.ts" "scripts/register/name-index.ts"
                                   "scripts/read-path/derive/extract.sql" "scripts/read-path/derive/maplify-entities.ts"
                                   "scripts/read-path/derive/sources.ts" "scripts/read-path/derive/sources.sql"
                                   "scripts/read-path/derive/shared.sql" "scripts/read-path/derive/lookups.sql"
                                   "scripts/read-path/derive/dwc.sql"
                                   "scripts/read-path/duckdb-budget.ts" "scripts/read-path/replace-dir.ts"
                                   "src/extents.ts" "src/fold.ts")
                                 (list* SNAPSHOT-DB MIRRORS)))
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
    [(dwca) (build-path export-dir "dwca")]
    [(maplify-names.json) (build-path mirror-dir "maplify-names.json")]
    [(maplify-unnamed.tsv) (build-path SALISHSEA "data" "maplify-unnamed.tsv")]
    [(reference/providers.tsv) (build-path SALISHSEA "data" "reference" "providers.tsv")]
    [(reference/organizations.tsv) (build-path SALISHSEA "data" "reference" "organizations.tsv")]
    [(reference/collections.tsv) (build-path SALISHSEA "data" "reference" "collections.tsv")]
    [(reference/maplify-collection-rules.tsv) (build-path SALISHSEA "data" "reference" "maplify-collection-rules.tsv")]
    [(reference/enums.tsv) (build-path SALISHSEA "data" "reference" "enums.tsv")]
    [else #f]))

(define (relation-tables artifact)
  (case artifact
    [(snapshot-meta) '("snapshot.meta")]
    [(snapshot-year) '("snapshot.year")]
    [(snapshot-day) '("snapshot.day")]
    [else
     (cond
       [(or (memq artifact derivation-input-relations)
            (memq artifact orcasound-relations)
            (memq artifact maplify-relations)
            (memq artifact inaturalist-relations)
            (memq artifact '(build.occurrences build.occurrence_identifier_candidates))
            (memq artifact profile-link-relations))
        (list (symbol->string artifact))]
       [else
        (for/first ([table (in-list catalogue-tables)]
                    #:when (eq? artifact (snapshot-relation table)))
          (list (string-append "snapshot." table)))])]))

;; The database a relation lives in: a mirror's SQLite file, attached under its source's
;; name (relation-digest's sqlite-db), or the snapshot. #f when the file isn't there yet.
(define (relation-db artifact)
  (cond
    [(memq artifact orcasound-relations) (sqlite-db orcasound-mirror "orcasound")]
    [(memq artifact maplify-relations) (sqlite-db maplify-mirror "maplify_mirror")]
    [(memq artifact inaturalist-relations) (sqlite-db inaturalist-mirror "inaturalist_mirror")]
    [(file-exists? snapshot-db) snapshot-db]
    [else #f]))
;; A relation's digest and its per-column parts, for every relation of a database in
;; one batch, held until a task writes the relation (st-ml9.6): the snapshot's ~45
;; relations cost two DuckDB launches, where asking one relation at a time cost about
;; four launches each, every one opening the 330 MB file.
(define-values (resolve-relation resolve-relation-columns)
  (make-relation-observer
   (for/list ([(name a) (in-hash (graph-artifacts salishsea-graph))]
              #:when (eq? (artifact-kind a) 'db-relation))
     name)
   relation-db
   relation-tables))

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
                #:default-state-dir (in-checkout ".stelis")
                ;; Thirty days (Peter, 2026-10-02): at a build every few minutes the
                ;; whole timeline would fill the Fly volume within months (st-ml9.7).
                #:history-retention (* 30 24 60 60)
                ;; Nothing publishes salishsea's build log, and at a build every five
                ;; minutes rendering it cost ~6 s of each; --render-log draws it when
                ;; someone wants to read it.
                #:build-log-after-build? #f))
