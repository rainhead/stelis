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

;; Since salishsea's step 3 (decision 061, salish-xv35.9) the published files read the
;; occurrences the build derives, from its own mirrors of Maplify, iNaturalist and
;; Orcasound and the snapshot of what Postgres still holds.
(define-values (ordered pruned) (plan salishsea-graph 'days))
(check-equal? ordered '(ingest-inaturalist ingest-maplify ingest-orcasound snapshot
                        maplify-names derive-occurrences occurrence-days)
              "the day files need the three sources' ingests, the snapshot, the name guard and the derivation")
(check-equal? (set-count pruned) 12
              (string-append "the calendar, the id index, the candidates and links, the pages, the profile "
                             "index, the manifest, the Maplify overlap report and the Darwin Core archive are off the path to days"))
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
(check-not-false (memq 'inaturalist.taxa (inputs-of 'derive-occurrences))
                 "Postgres's taxa beyond the mirror's: the register names them for other sources' sightings")
(check-not-false (memq 'types.enums (inputs-of 'derive-occurrences))
                 "two of the views compare enums by their declared order")
(check-false (memq 'public.identifications (inputs-of 'derive-occurrences))
             "the occurrences don't read the identifications; only the links do")

;; The name guard: a register that un-names a Maplify sighting Postgres named stops the
;; derivation, so the last good files stay published.
(check-not-false (memq 'maplify-names-hold (inputs-of 'derive-occurrences))
                 "the derivation waits on the guard")
(define-values (guard-plan _gp) (plan salishsea-graph 'maplify-names-hold))
(check-equal? guard-plan '(ingest-maplify snapshot maplify-names)
              "the guard reads Postgres's stored answer and the register, for the pairs the mirror holds")
(check-equal? (task-kind (hash-ref (graph-tasks salishsea-graph) 'maplify-names)) 'gate)

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

;; The three ingests: each a boundary of its own, reading only its upstream. Maplify's is
;; compared with Postgres's copy by a report nothing published waits on, while Postgres
;; ingests Maplify too.
(for ([ingest (in-list '(ingest-orcasound ingest-maplify ingest-inaturalist))])
  (check-equal? (inputs-of ingest) '() (format "~a reads only its upstream" ingest))
  (check-equal? (task-kind (hash-ref (graph-tasks salishsea-graph) ingest)) 'boundary))
(check-not-false (memq 'register.names (inputs-of 'maplify-overlap))
                 "the report filters the mirror by scope, which needs the register's names")
(check-false (memq 'maplify-overlap manifest-plan) "the Maplify overlap report holds nothing published back")
(for ([retired (in-list '(orcasound-overlap inaturalist-overlap))])
  (check-false (hash-ref (graph-tasks salishsea-graph) retired #f)
               (format "~a retired with Postgres's ingest of its source (salish-xv35.9)" retired)))
(for ([unread (in-list '(inaturalist.observations inaturalist.observation_photos
                         public.acoustic_bouts public.acoustic_bout_entities))])
  (check-false (hash-ref (graph-artifacts salishsea-graph) unread #f)
               (format "the snapshot no longer reads Postgres's ~a" unread)))

(check-equal? (last manifest-plan) 'manifest
              "the manifest comes after every export, so it never claims a build whose files aren't in place")
(for ([export (in-list '(calendar ecotype-pages haulout-pages individual-pages matriline-pages
                         occurrence-days occurrence-ids profile-index))])
  (check-not-false (memq export manifest-plan) (format "the manifest waits on ~a" export)))

(for ([pages (in-list '(individual-pages matriline-pages ecotype-pages haulout-pages))])
  (check-not-false (memq 'snapshot-year (inputs-of pages))
                   "the presence table's newest year is the snapshot's, so that year is an input")
  (check-false (memq 'snapshot-meta (inputs-of pages))
               "but not the moment it was taken, which moves every build: a no-op build skips the pages"))
(check-equal? (sort (inputs-of 'ecotype-pages) symbol<?)
              '(build.ecotype_occurrences group-parents-snapshot snapshot-year social-groups-snapshot)
              "a kind's inputs are the tables profiles.ts loads for it, its links the build's own")
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
