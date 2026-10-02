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
;;       ├──────▶ snapshot-year ────────────┘
;;       │        (the Pacific year it was taken in)
;;       ├──────▶ snapshot-meta ───────────────────▶ manifest ──▶ manifest.json
;;       │        (when it was taken)      (after days/,       (what the build
;;       │                                  calendar/, ids/,     covered)
;;       │                                  the pages)
;;       └──────▶ what the occurrences ──▶ derive-occurrences ──▶ build.occurrences
;;                are derived from          (DuckDB twins of the       │       │
;;                (decision 061): the       five Postgres views)       │       ▼
;;                sources' and reference                               │  derive-identifier-candidates
;;                tables, typed, one                                   │       ▼
;;                relation per table              build.occurrence_identifier_candidates
;;                                                                     ▼       ▼
;;                         occurrences-agreement, identifier-candidates-agreement
;;                         (gates: each port must equal Postgres's stored answer,
;;                          read in the same snapshot) ──▶ tokens
;;                                                             │       │
;;                                                             ▼       ▼
;;                               derive-profile-links ──▶ build.individual_occurrences
;;                               (twins of the four views     and its three siblings
;;                                the pages' maps read)  ──▶ profile-links-agreement
;;
;; Until salishsea's step-3 cutover (salish-xv35.9) the pages still read
;; occurrences-snapshot and the snapshot's link views; the ports run beside them,
;; and each gate fails the build the moment the two disagree.
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

;; The relations a mirror holds, each named "<source>.<table>", as the mirror is attached
;; under the source's name.
(define orcasound-relations '(orcasound.bouts orcasound.bout_entities))

(define (snapshot-relation table)
  (string->symbol (string-append (string-replace table "_" "-") "-snapshot")))

(define catalogue-relations (map snapshot-relation catalogue-tables))

;; What the occurrences are derived from (salishsea decision 061, salish-xv35.1):
;; every table the five views behind derived.occurrences read, the reference tables
;; the functions they call read, the Maplify resolvers' inputs, the stored
;; identifier candidates to check a port against, and the enums' declared orders;
;; and the identifications people assert, which the profile pages' link views start
;; from (salish-xv35.13).
;; snapshot.ts writes each under its Postgres name, typed rather than as documents,
;; so each is named for its table here too: --why names the one that moved, and the
;; per-column observation says which column.
(define derivation-input-tables
  '("maplify.sightings" "maplify.collection_rule"
    "inaturalist.observations" "inaturalist.observation_photos" "inaturalist.taxa"
    "happywhale.encounters" "happywhale.users" "happywhale.individuals"
    "happywhale.species" "happywhale.media"
    "public.observations" "public.observation_photos" "public.contributors"
    "public.acoustic_bouts" "public.acoustic_bout_entities" "public.identifications"
    "public.providers" "public.collections" "public.organizations"
    "register.entities" "register.names" "register.mappings"
    "register.ancestor" "register.deprecations"
    "derived.occurrence_identifier_candidates"
    "types.enums"))

(define derivation-input-relations (map string->symbol derivation-input-tables))

;; What derive-occurrences reads: all of the above but the stored candidates, which
;; are there to check the candidates' port against, not to derive from, and the
;; identifications, which only the profile links read.
(define occurrence-derivation-inputs
  (remq* '(derived.occurrence_identifier_candidates public.identifications)
         derivation-input-relations))

;; The profile pages' link views, each twinned under build. by derive-profile-links
;; (salish-xv35.13) and compared with the snapshot's copy of the view.
(define profile-link-tables
  '("individual_occurrences" "group_occurrences" "ecotype_occurrences" "haulout_occurrences"))
(define profile-link-relations
  (for/list ([table (in-list profile-link-tables)])
    (string->symbol (string-append "build." table))))

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
   ;; The Pacific year it was taken in, all the profile pages read of when: moves
   ;; once a year where snapshot-meta moves every build (salish-xv35.12).
   (make-artifact 'snapshot-year 'db-relation)
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
      (make-artifact name 'db-relation))
    (list
     ;; The occurrences as the build derives them (salish-xv35.2): id, observed_at
     ;; and the document, in the shape of occurrences-snapshot. Written into the
     ;; snapshot file, under build., beside what it was derived from.
     (make-artifact 'build.occurrences 'db-relation)
     ;; That the build's occurrences and Postgres's agree, row for row.
     (make-artifact 'occurrences-agree 'token)
     ;; Orcasound's bouts as the build fetches them itself (salish-xv35.6), and how
     ;; they compare with Postgres's copy while both are ingested: a report for a person,
     ;; not a gate, since the two fetches are minutes apart.
     (make-artifact 'orcasound.bouts 'db-relation)
     (make-artifact 'orcasound.bout_entities 'db-relation)
     (make-artifact 'orcasound-overlap.json 'file)
     ;; Which individual or matriline each designation an occurrence names means
     ;; (salish-xv35.3), as the build derives it, and that it agrees with Postgres's.
     (make-artifact 'build.occurrence_identifier_candidates 'db-relation)
     (make-artifact 'identifier-candidates-agree 'token)
     ;; That the profile links the build derives agree with Postgres's views.
     (make-artifact 'profile-links-agree 'token))
    ;; Which sightings each individual, matriline, ecotype and haul-out site was seen
    ;; in (salish-xv35.13), as the build derives them: one relation per view twinned,
    ;; each holding documents in the shape of the snapshot's copy of that view.
    (for/list ([name (in-list profile-link-relations)])
      (make-artifact name 'db-relation)))))

(define tasks
  (list
   (make-task 'snapshot 'boundary
              #:outputs (list* 'occurrences-snapshot 'snapshot-meta 'snapshot-year
                               (append catalogue-relations derivation-input-relations))
              #:invoke (node-script/code "scripts/read-path/snapshot.ts"
                                 '("scripts/read-path/duckdb-budget.ts")
                                 (list SNAPSHOT-DB)))
   (make-task 'occurrence-days 'transform
              #:inputs '(occurrences-snapshot)
              #:outputs '(days)
              #:invoke (node-script/code "scripts/read-path/occurrence-days.ts"
                                 '("scripts/read-path/replace-dir.ts" "scripts/read-path/duckdb-budget.ts")
                                 (list SNAPSHOT-DB)))
   ;; The region boxes are the map's own, so the files they come from are code.
   (make-task 'calendar 'transform
              #:inputs '(occurrences-snapshot)
              #:outputs '(calendar)
              #:invoke (node-script/code "scripts/read-path/calendar.ts"
                                 '("scripts/read-path/replace-dir.ts" "scripts/read-path/duckdb-budget.ts"
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
   ;; The five per-source Postgres views behind derived.occurrences, as DuckDB SQL
   ;; (salishsea decision 061). Its two regex extractions run in node first, since
   ;; RE2 can't express Postgres's word boundaries, and so does Maplify's entity
   ;; resolution, which is the ingest's own resolveEntity over the register's name
   ;; index (salish-xv35.11). The code list is the script's esbuild import closure;
   ;; the SQL is read, not imported, so it is listed by hand.
   (make-task 'derive-occurrences 'transform
              #:inputs occurrence-derivation-inputs
              #:outputs '(build.occurrences)
              #:invoke (node-script/code "scripts/read-path/derive-occurrences.ts"
                                 '("scripts/read-path/derive/extract.ts"
                                   "scripts/read-path/derive/maplify-entities.ts"
                                   "scripts/ingest/maplify.ts"
                                   "scripts/register/name-index.ts"
                                   "src/fold.ts" "src/extents.ts"
                                   "scripts/read-path/duckdb-budget.ts"
                                   "scripts/read-path/derive/shared.sql"
                                   "scripts/read-path/derive/occurrences.sql")
                                 (list SNAPSHOT-DB)))
   ;; The port's check: every occurrence Postgres stores, the build derived the same,
   ;; compared as the day files would write them. Fails the build on any difference,
   ;; naming the rows, until the cutover retires it.
   (make-task 'occurrences-agreement 'gate
              #:inputs '(build.occurrences occurrences-snapshot)
              #:outputs '(occurrences-agree)
              #:invoke (node-script/code "scripts/read-path/compare-occurrences.ts"
                                 '("scripts/read-path/duckdb-budget.ts")
                                 (list SNAPSHOT-DB)))
   ;; Postgres's derived.identifier_candidates as DuckDB SQL: each designation an
   ;; occurrence names, paired with the catalogue's individual or matriline. Reads the
   ;; occurrences the build derived, not Postgres's, so it is a port of the whole
   ;; chain; register.fold's twin is in the SQL, read rather than imported.
   (make-task 'derive-identifier-candidates 'transform
              #:inputs '(build.occurrences social-groups-snapshot designations-snapshot)
              #:outputs '(build.occurrence_identifier_candidates)
              #:invoke (node-script/code "scripts/read-path/derive-identifier-candidates.ts"
                                 '("scripts/read-path/duckdb-budget.ts"
                                   "scripts/read-path/derive/identifier-candidates.sql")
                                 (list SNAPSHOT-DB)))
   (make-task 'identifier-candidates-agreement 'gate
              #:inputs '(build.occurrence_identifier_candidates derived.occurrence_identifier_candidates)
              #:outputs '(identifier-candidates-agree)
              #:invoke (node-script/code "scripts/read-path/compare-identifier-candidates.ts"
                                 '("scripts/read-path/duckdb-budget.ts")
                                 (list SNAPSHOT-DB)))
   ;; The four views a profile page's map reads (salish-xv35.13), as DuckDB SQL over the
   ;; occurrences and candidates the build derived, the identifications people assert,
   ;; Orcasound's bout entities and the catalogue. A haul-out report's distance is
   ;; PostGIS's spheroidal one, measured in node with GeographicLib, which PostGIS
   ;; calls, rather than with DuckDB's spatial extension on a 1 GB machine.
   (make-task 'derive-profile-links 'transform
              #:inputs '(build.occurrences build.occurrence_identifier_candidates
                         public.identifications public.acoustic_bout_entities
                         register.entities register.deprecations register.ancestor
                         inaturalist.taxa
                         individuals-snapshot social-groups-snapshot matriline-members-snapshot
                         haulouts-snapshot)
              #:outputs profile-link-relations
              #:invoke (node-script/code "scripts/read-path/derive-profile-links.ts"
                                 '("scripts/read-path/derive/haulout-distance.ts"
                                   "scripts/read-path/duckdb-budget.ts"
                                   "scripts/read-path/derive/shared.sql"
                                   "scripts/read-path/derive/haulout-nearby.sql"
                                   "scripts/read-path/derive/profile-links.sql")
                                 (list SNAPSHOT-DB)))
   ;; Each twin against the snapshot's copy of its view, as multisets of documents.
   (make-task 'profile-links-agreement 'gate
              #:inputs (append profile-link-relations
                               (map snapshot-relation profile-link-tables))
              #:outputs '(profile-links-agree)
              #:invoke (node-script/code "scripts/read-path/compare-profile-links.ts"
                                 '("scripts/read-path/duckdb-budget.ts")
                                 (list SNAPSHOT-DB)))
   ;; Orcasound's whole corpus, fetched by the build (salishsea decision 061, step B):
   ;; the same fetch shell and pure core as the Supabase function, written to a SQLite
   ;; mirror whole and atomically, nothing written unless the fetch is complete. It
   ;; reports through the boundary receipt whether the corpus changed.
   (make-task 'ingest-orcasound 'boundary
              #:outputs orcasound-relations
              #:invoke (node-script/code "scripts/read-path/ingest-orcasound.ts"
                                 '("scripts/ingest/fetch-orcasound.ts" "scripts/ingest/orcasound.ts"
                                   "scripts/ingest/retry.ts")
                                 (list (path->string orcasound-mirror))))
   ;; While Postgres still ingests Orcasound too, what differs between the two copies.
   ;; A difference never fails it, since the fetches race and CI proves the two store a
   ;; corpus alike; only being unable to compare does.
   (make-task 'orcasound-overlap 'transform
              #:inputs (append orcasound-relations '(public.acoustic_bouts public.acoustic_bout_entities))
              #:outputs '(orcasound-overlap.json)
              #:invoke (node-script/code "scripts/read-path/compare-orcasound-mirror.ts"
                                 '("scripts/read-path/duckdb-budget.ts")
                                 (list SNAPSHOT-DB (path->string orcasound-mirror)
                                       (path->string (build-path mirror-dir "orcasound-overlap.json")))))
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
    [(orcasound-overlap.json) (build-path mirror-dir "orcasound-overlap.json")]
    [else #f]))

(define (relation-tables artifact)
  (case artifact
    [(occurrences-snapshot) '("snapshot.occurrences")]
    [(snapshot-meta) '("snapshot.meta")]
    [(snapshot-year) '("snapshot.year")]
    [else
     (cond
       [(or (memq artifact derivation-input-relations)
            (memq artifact orcasound-relations)
            (memq artifact '(build.occurrences build.occurrence_identifier_candidates))
            (memq artifact profile-link-relations))
        (list (symbol->string artifact))]
       [else
        (for/first ([table (in-list catalogue-tables)]
                    #:when (eq? artifact (snapshot-relation table)))
          (list (string-append "snapshot." table)))])]))

(define (resolve-relation artifact)
  (define tables (relation-tables artifact))
  (define db (relation-db artifact))
  (and tables db (relation-digest db tables)))

(define (resolve-relation-columns artifact)
  (define tables (relation-tables artifact))
  (define db (relation-db artifact))
  (and tables db (relation-columns db tables)))

;; The database a relation lives in: a mirror's SQLite file, attached under its source's
;; name (relation-digest's sqlite-db), or the snapshot. #f when the file isn't there yet.
(define (relation-db artifact)
  (cond
    [(memq artifact orcasound-relations) (sqlite-db orcasound-mirror "orcasound")]
    [(file-exists? snapshot-db) snapshot-db]
    [else #f]))

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
