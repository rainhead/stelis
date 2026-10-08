#lang racket/base

;; The salishsea graph as authored (st-ml9.2). Pure: nothing here launches a
;; task or needs a checkout — build-graph's own integrity checks already ran when
;; the module loaded, so this pins the SHAPE: what the day files depend on, and
;; that the project value carries the graph the CLI will select.

(require rackunit
         racket/list
         racket/set
         "model.rkt"
         "project.rkt"
         "salishsea.rkt")

(define (inputs-of task) (task-inputs (hash-ref (graph-tasks salishsea-graph) task)))
(define (outputs-of task) (task-outputs (hash-ref (graph-tasks salishsea-graph) task)))

;; Since salishsea's step 3 (decision 061, salish-xv35.9) the published files read the
;; occurrences the build derives, from its own mirrors of Maplify, iNaturalist and
;; Orcasound and the snapshot of what Postgres still holds.
(define-values (ordered pruned) (plan salishsea-graph 'days))
(check-equal? ordered '(happywhale ingest-maplify ingest-orcasound reference snapshot ingest-register
                        ingest-inaturalist maplify-names derive-occurrences occurrence-days)
              (string-append "the day files need Happywhale's frozen file, the three sources' ingests, the reference "
                             "files, the snapshot, the register, the name guard and the derivation; the register follows "
                             "Maplify's ingest, whose pairs it must not un-name, and iNaturalist's follows the register, "
                             "which names the taxa it fetches"))
(check-equal? (set-count pruned) 16
              (string-append "the calendar, the id index, the candidates and links, the catalogue and its "
                             "register views, the pages, the whales page, the profile index, the search index, "
                             "the manifest and the Darwin Core archive are off the path to days"))

;; The catalogue's views over the register are the build's (salishsea decision 064,
;; salish-9uu.2.3): derive-catalogue produces them under the snapshot's names, from the
;; register the build fetched and the catalogue's own rows; the snapshot copies the rest.
(for ([v (in-list '(group-parents-snapshot matriline-members-snapshot animal-names-snapshot))])
  (check-eq? (producer-of salishsea-graph v) 'derive-catalogue (format "~a is derived" v)))
(for ([v (in-list '(individuals-snapshot designations-snapshot social-groups-snapshot
                    nicknames-snapshot parties-snapshot haulouts-snapshot))])
  (check-eq? (producer-of salishsea-graph v) 'catalogue (format "~a comes from its checked-in file" v)))
(for ([file (in-list (filter (lambda (a) (regexp-match? #rx"^catalogue/" (symbol->string a)))
                             (inputs-of 'catalogue)))])
  (check-eq? (artifact-provenance (hash-ref (graph-artifacts salishsea-graph) file)) 'authoritative)
  (check-false (producer-of salishsea-graph file)))
;; Happywhale's frozen tables come from a file on the volume (salish-9uu.2.4), not the
;; snapshot: somebody else's data snapshotted in once, which no task writes.
(for ([t (in-list '(happywhale.encounters happywhale.users happywhale.individuals
                    happywhale.species happywhale.media))])
  (check-eq? (producer-of salishsea-graph t) 'happywhale (format "~a comes from the frozen file" t)))
(check-eq? (artifact-provenance (hash-ref (graph-artifacts salishsea-graph) 'happywhale.duckdb)) 'upstream)
(check-false (producer-of salishsea-graph 'happywhale.duckdb))
(check-not-false (memq 'register.vitals (inputs-of 'catalogue))
                 "an individual's vitals are the register's")
;; The Southern Residents' rows are generated from the register (salishsea decision 070).
(for ([t (in-list '(register.entities register.ancestor register.deprecations
                    register.group_ranks register.parentage register.matriarchs))])
  (check-not-false (memq t (inputs-of 'catalogue)) (format "the catalogue generates rows from ~a" t)))
(check-false (for/or ([o (in-list (task-outputs (hash-ref (graph-tasks salishsea-graph) 'snapshot)))])
               (regexp-match? #rx"-snapshot$" (symbol->string o)))
             "the snapshot copies none of the catalogue")
(check-not-false (memq 'register.ancestor (inputs-of 'derive-catalogue)))
(for ([export (in-list '(occurrence-days calendar occurrence-ids))])
  (check-equal? (inputs-of export) '(build.occurrences)
                "every occurrence export reads the build's occurrences, and nothing of Postgres's answer"))

(define-values (manifest-plan _p) (plan salishsea-graph 'manifest.json))

;; The derivation reads the mirrors in place of Postgres's copies of the three sources.
(for ([mirrored (in-list '(maplify_mirror.sightings inaturalist_mirror.observations
                           inaturalist_mirror.observation_photos inaturalist_mirror.taxa
                           orcasound.bouts orcasound.bout_entities))])
  (check-not-false (memq mirrored (inputs-of 'derive-occurrences))
                   (format "the derivation reads ~a" mirrored)))
(for ([postgres (in-list '(maplify.sightings inaturalist.observations inaturalist.observation_photos
                           public.acoustic_bouts public.acoustic_bout_entities))])
  (check-false (memq postgres (inputs-of 'derive-occurrences))
               (format "and not Postgres's ~a" postgres)))
(check-false (memq 'inaturalist.taxa (inputs-of 'derive-occurrences))
             "nor Postgres's taxa: the mirror holds every taxon the register names (salish-xv35.9.3)")
(check-false (for/or ([t (in-list '(derive-profile-links dwca))]) (memq 'inaturalist.taxa (inputs-of t)))
             "and neither do the links or the archive")
(check-not-false (memq 'types.enums (inputs-of 'derive-occurrences))
                 "two of the views compare enums by their declared order")

;; The reference tables are checked-in files (salishsea decision 064): the reference task
;; produces them, from declared files nobody in the graph writes, and the snapshot no longer
;; reads them from Postgres.
(for ([table (in-list '(public.providers public.organizations public.collections
                        maplify.collection_rule types.enums))])
  (check-eq? (producer-of salishsea-graph table) 'reference
             (format "~a comes from its checked-in file" table))
  (check-not-false (memq table (inputs-of 'derive-occurrences))
                   (format "and the derivation still reads ~a" table)))
(for ([file (in-list (inputs-of 'reference))])
  (check-eq? (artifact-provenance (hash-ref (graph-artifacts salishsea-graph) file)) 'authoritative
             (format "~a is ours and forward-only" file))
  (check-false (producer-of salishsea-graph file) (format "~a is written by a curator with git" file)))
(check-equal? (length (inputs-of 'reference)) 5)
(check-false (memq 'public.identifications (inputs-of 'derive-occurrences))
             "the occurrences don't read the identifications; only the links do")

;; The name guard: a register that un-names a Maplify sighting Postgres named stops the
;; derivation, so the last good files stay published.
(check-not-false (memq 'maplify-names-hold (inputs-of 'derive-occurrences))
                 "the derivation waits on the guard")
(define-values (guard-plan _gp) (plan salishsea-graph 'maplify-names-hold))
(check-equal? guard-plan '(ingest-maplify ingest-register maplify-names)
              "the guard reads the register the build fetched, for the pairs the mirror holds")

;; The register is the build's own fetch (salishsea decision 064), not Postgres's copy: the
;; ingest-register boundary produces every register relation, and the snapshot none.
(for ([r (in-list '(register.entities register.names register.mappings register.ancestor
                    register.deprecations register.classification register.edition))])
  (check-eq? (producer-of salishsea-graph r) 'ingest-register (format "~a comes from the release" r)))
(check-equal? (inputs-of 'ingest-register) '(maplify_mirror.sightings maplify-unnamed.tsv)
              "it judges a new edition by the Maplify pairs and the curator's allow-list")
(check-eq? (task-kind (hash-ref (graph-tasks salishsea-graph) 'ingest-register)) 'boundary)
(check-equal? (task-kind (hash-ref (graph-tasks salishsea-graph) 'maplify-names)) 'gate)
;; its baseline is forward-only state the gate itself writes (salish-xv35.9.2): declared,
;; with the gate as its producer, so the graph knows the file exists and whose it is
(check-eq? (artifact-provenance (hash-ref (graph-artifacts salishsea-graph) 'maplify-names.json))
           'authoritative)
(check-eq? (producer-of salishsea-graph 'maplify-names.json) 'maplify-names)
;; and the curator's allow-list is its input: a checked-in file nobody in the graph writes,
;; declared so an acceptance clears the hold by a declared input moving
(check-not-false (memq 'maplify-unnamed.tsv (inputs-of 'maplify-names)))
(check-eq? (artifact-provenance (hash-ref (graph-artifacts salishsea-graph) 'maplify-unnamed.tsv))
           'authoritative)
(check-false (producer-of salishsea-graph 'maplify-unnamed.tsv) "written by a person with git, not a task")

;; Nothing compares the build's derivation with Postgres's any more.
(for ([retired (in-list '(occurrences-agreement identifier-candidates-agreement profile-links-agreement))])
  (check-false (hash-ref (graph-tasks salishsea-graph) retired #f)
               (format "~a is retired at the cutover" retired)))
(check-false (hash-ref (graph-artifacts salishsea-graph) 'occurrences-snapshot #f)
             "the snapshot no longer reads Postgres's occurrences")

;; The profile pages' link views (salish-xv35.13): derived from the build's own
;; occurrences and candidates, and what the pages read.
(define-values (links-plan _lp) (plan salishsea-graph 'build.individual_occurrences))
(check-equal? (take-right links-plan 3)
              '(derive-occurrences derive-identifier-candidates derive-profile-links)
              "the links are a port of the whole chain, not of the last view alone")
(check-not-false (memq 'public.identifications (inputs-of 'derive-profile-links))
                 "what people assert overrides what a sighting's text suggests")
(check-not-false (memq 'orcasound.bout_entities (inputs-of 'derive-profile-links))
                 "a bout's animals come from the Orcasound mirror")

;; The three ingests: each a boundary of its own, reading its upstream — and, for
;; iNaturalist, the register's mappings, which name the taxa it must hold beyond those
;; its observations reach (salish-xv35.9.3). Maplify's is compared with Postgres's copy
;; by a report nothing published waits on, while Postgres ingests Maplify too.
(for ([ingest (in-list '(ingest-orcasound ingest-maplify))])
  (check-equal? (inputs-of ingest) '() (format "~a reads only its upstream" ingest))
  (check-equal? (task-kind (hash-ref (graph-tasks salishsea-graph) ingest)) 'boundary))
(check-equal? (inputs-of 'ingest-inaturalist) '(register.mappings)
              "ingest-inaturalist reads its upstream and the register's mappings, nothing else")
(check-equal? (task-kind (hash-ref (graph-tasks salishsea-graph) 'ingest-inaturalist)) 'boundary)
(check-false (hash-ref (graph-tasks salishsea-graph) 'maplify-overlap #f)
             "the Maplify overlap report retired with Postgres's Maplify ingest (salish-xv35.9)")
(check-false (memq 'maplify.sightings (inputs-of 'maplify-names))
             "the name guard judges against its own baseline, not Postgres's answer")
(for ([retired (in-list '(orcasound-overlap inaturalist-overlap))])
  (check-false (hash-ref (graph-tasks salishsea-graph) retired #f)
               (format "~a retired with Postgres's ingest of its source (salish-xv35.9)" retired)))
(for ([unread (in-list '(inaturalist.observations inaturalist.observation_photos
                         public.acoustic_bouts public.acoustic_bout_entities))])
  (check-false (hash-ref (graph-artifacts salishsea-graph) unread #f)
               (format "the snapshot no longer reads Postgres's ~a" unread)))

(check-equal? (last manifest-plan) 'manifest
              "the manifest comes after every export, so it never claims a build whose files aren't in place")
(for ([export (in-list '(calendar ecotype-pages haulout-pages individual-pages matriline-pages pod-pages
                         occurrence-days occurrence-ids profile-index whales-page))])
  (check-not-false (memq export manifest-plan) (format "the manifest waits on ~a" export)))

(for ([pages (in-list '(individual-pages matriline-pages ecotype-pages pod-pages haulout-pages))])
  (check-not-false (memq 'snapshot-year (inputs-of pages))
                   "the presence table's newest year is the snapshot's, so that year is an input")
  (check-false (memq 'snapshot-meta (inputs-of pages))
               "but not the moment it was taken, which moves every build: a no-op build skips the pages"))
;; The whales page reads every occurrence, and the register's lineage to know a cetacean.
(check-equal? (sort (inputs-of 'whales-page) symbol<?)
              '(animal-names-snapshot build.occurrences register.ancestor register.classification
                register.entities register.taxon_ancestor social-groups-snapshot)
              "the whales page's inputs are what whales.ts reads")
(check-not-false (memq 'register.taxon_ancestor (outputs-of 'ingest-register))
                 "the build loads the register's taxon lineage")
;; The ecotype's links pooled, and each matriline's for its small map (decision 067).
(check-equal? (sort (inputs-of 'ecotype-pages) symbol<?)
              '(build.ecotype_occurrences build.group_occurrences group-parents-snapshot snapshot-year
                social-groups-snapshot)
              "a kind's inputs are the tables profiles.ts loads for it, its links the build's own")
(check-equal? (inputs-of 'pod-pages) (inputs-of 'ecotype-pages)
              "a pod's page is a population's a level down, read from the same tables")
(check-equal? (sort (inputs-of 'haulout-pages) symbol<?)
              '(build.haulout_occurrences haulouts-snapshot snapshot-year)
              "a haul-out page reads the sites and their reports: the register holds no places")
(check-false (memq 'snapshot-meta (inputs-of 'profile-index))
             "the redirects and the sitemap don't depend on when the snapshot was taken, so they cut off")

;; The Darwin Core archive (salish-xv35.9): behind the name guard, dated by the day, and
;; reading no source it doesn't publish.
(check-not-false (memq 'maplify-names-hold (inputs-of 'dwca)) "a register that un-names sightings stops the archive too")
(check-not-false (memq 'snapshot-day (inputs-of 'dwca)) "dated by the snapshot's day")
(check-false (memq 'snapshot-meta (inputs-of 'dwca)) "not the moment, which moves every build")
(for ([unpublished (in-list '(inaturalist_mirror.observations happywhale.encounters))])
  (check-false (memq unpublished (inputs-of 'dwca))
               (format "~a publishes to GBIF itself, so the archive doesn't read it" unpublished)))
(check-equal? ((project-path salishsea-project) 'dwca (string->path "/x")) (string->path "/x/dwca"))

(check-equal? (task-kind (hash-ref (graph-tasks salishsea-graph) 'snapshot)) 'boundary
              "the snapshot asks Postgres every build — it cannot know otherwise")

(check-eq? (project-graph salishsea-project) salishsea-graph)
(check-equal? (project-name salishsea-project) 'salishsea
              "the key written into every build record")
(check-true (absolute-path? (project-default-state-dir salishsea-project))
            "a new project's state defaults into its checkout, not the shell's cwd")
(check-equal? ((project-path salishsea-project) 'days (string->path "/x"))
              (string->path "/x/days")
              "the day files land under EXPORT_DIR")
(check-equal? ((project-path salishsea-project) 'individual-pages (string->path "/x"))
              (string->path "/x/profiles/individuals")
              "one kind of profile per dir, so the other kinds land beside it, not inside it")
(check-equal? ((project-path salishsea-project) 'matriline-pages (string->path "/x"))
              (string->path "/x/profiles/matrilines"))

;; The search field's index (salishsea GH #640): its own task, reading each subject's
;; reports for its newest, and kept off the manifest's inputs so a failure can't hold
;; the map's files back.
(check-eq? (producer-of salishsea-graph 'search-index.json) 'search-index)
(for ([r (in-list '(build.individual_occurrences build.group_occurrences build.ecotype_occurrences
                    register.names individuals-snapshot nicknames-snapshot))])
  (check-not-false (memq r (inputs-of 'search-index)) (format "the search index reads ~a" r)))
(check-false (memq 'search-index.json (inputs-of 'manifest)))
