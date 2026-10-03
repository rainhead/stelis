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

(define-values (ordered pruned) (plan salishsea-graph 'days))
(check-equal? ordered '(snapshot occurrence-days)
              "the day files need exactly the snapshot, then the export")
(check-equal? (set-count pruned) 20
              (string-append "the calendar, the id index, the pages, the profile index, the manifest, "
                             "the three ports and their gates, and the Orcasound, Maplify and iNaturalist "
                             "mirrors and their reports are off the path to days"))

(define-values (manifest-plan _p) (plan salishsea-graph 'manifest.json))

;; The occurrence port (salishsea decision 061): derived beside Postgres's answer and
;; checked against it, with nothing published waiting on it until the cutover.
(define-values (agree-plan _ap) (plan salishsea-graph 'occurrences-agree))
(check-equal? agree-plan '(snapshot derive-occurrences occurrences-agreement)
              "the gate compares the port with the snapshot it was derived from")
(check-false (memq 'derived.occurrence_identifier_candidates
                   (task-inputs (hash-ref (graph-tasks salishsea-graph) 'derive-occurrences)))
             "the stored candidates are there to check a later port against, not to derive from")
(check-not-false (memq 'types.enums (task-inputs (hash-ref (graph-tasks salishsea-graph) 'derive-occurrences)))
                 "two of the views compare enums by their declared order")
(define-values (candidates-plan _cp) (plan salishsea-graph 'identifier-candidates-agree))
(check-equal? candidates-plan '(snapshot derive-occurrences derive-identifier-candidates
                                identifier-candidates-agreement)
              "the candidates are derived from the build's own occurrences, then checked")
(check-false (memq 'identifier-candidates-agreement manifest-plan)
             "nor anything published on the candidates' gate")
;; The profile pages' link views (salish-xv35.13): derived from the build's own
;; occurrences and candidates, then checked against the snapshot's copies of the views.
(define-values (links-plan _lp) (plan salishsea-graph 'profile-links-agree))
(check-equal? links-plan '(snapshot derive-occurrences derive-identifier-candidates
                           derive-profile-links profile-links-agreement)
              "the links are a port of the whole chain, not of the last view alone")
(check-not-false (memq 'public.identifications
                       (task-inputs (hash-ref (graph-tasks salishsea-graph) 'derive-profile-links)))
                 "what people assert overrides what a sighting's text suggests")
(check-false (memq 'public.identifications
                   (task-inputs (hash-ref (graph-tasks salishsea-graph) 'derive-occurrences)))
             "the occurrences don't read the identifications; only the links do")
(check-false (memq 'profile-links-agreement manifest-plan)
             "until the cutover the pages read the snapshot's views, so the gate holds nothing back")
(check-equal? (sort (task-inputs (hash-ref (graph-tasks salishsea-graph) 'profile-links-agreement)) symbol<?)
              '(build.ecotype_occurrences build.group_occurrences build.haulout_occurrences
                build.individual_occurrences
                ecotype-occurrences-snapshot group-occurrences-snapshot haulout-occurrences-snapshot
                individual-occurrences-snapshot)
              "each twin against the snapshot's copy of the view it twins")
;; Orcasound's own ingest (salishsea decision 061, step B): a boundary of its own, beside
;; the snapshot, compared with Postgres's copy by a report nothing published waits on.
(check-equal? (task-inputs (hash-ref (graph-tasks salishsea-graph) 'ingest-orcasound)) '()
              "the build's ingest reads only orcasite")
(check-equal? (task-kind (hash-ref (graph-tasks salishsea-graph) 'ingest-orcasound)) 'boundary)
(check-equal? (sort (task-inputs (hash-ref (graph-tasks salishsea-graph) 'orcasound-overlap)) symbol<?)
              '(orcasound.bout_entities orcasound.bouts public.acoustic_bout_entities public.acoustic_bouts)
              "the report compares the mirror with Postgres's copy, table for table")
(check-false (memq 'orcasound-overlap manifest-plan)
             "the overlap report holds nothing published back")
;; Maplify's (salish-xv35.7): a windowed boundary of its own, compared with Postgres's copy
;; through the register, since the mirror keeps what is out of the map's scope too.
(check-equal? (task-inputs (hash-ref (graph-tasks salishsea-graph) 'ingest-maplify)) '()
              "the build's ingest reads only Maplify: scope is decided downstream")
(check-equal? (task-kind (hash-ref (graph-tasks salishsea-graph) 'ingest-maplify)) 'boundary)
(check-not-false (memq 'register.names (task-inputs (hash-ref (graph-tasks salishsea-graph) 'maplify-overlap)))
                 "the report filters the mirror by scope, which needs the register's names")
(check-false (memq 'maplify-overlap manifest-plan)
             "nor does Maplify's")
;; iNaturalist's (salish-xv35.8): a boundary of its own; its report needs no register, since
;; whether an observation is a killer whale comes with it from iNaturalist.
(check-equal? (task-inputs (hash-ref (graph-tasks salishsea-graph) 'ingest-inaturalist)) '())
(check-equal? (task-kind (hash-ref (graph-tasks salishsea-graph) 'ingest-inaturalist)) 'boundary)
(check-false (memq 'inaturalist-overlap manifest-plan) "nor does iNaturalist's")
(check-false (memq 'occurrences-agreement manifest-plan)
             "until the cutover nothing published reads the port, so a disagreement can't hold the site back")

(check-equal? (car manifest-plan) 'snapshot)
(check-equal? (last manifest-plan) 'manifest
              "the manifest comes after every export, so it never claims a build whose files aren't in place")
(check-equal? (sort (cdr (reverse (cdr manifest-plan))) symbol<?)
              '(calendar ecotype-pages haulout-pages individual-pages matriline-pages
                occurrence-days occurrence-ids profile-index))

(define-values (pages-plan _pp) (plan salishsea-graph 'individual-pages))
(check-equal? pages-plan '(snapshot individual-pages)
              "the pages need only the snapshot: they read none of the other exports")
(for ([pages (in-list '(individual-pages matriline-pages ecotype-pages haulout-pages))])
  (check-not-false (memq 'snapshot-year (task-inputs (hash-ref (graph-tasks salishsea-graph) pages)))
                   "the presence table's newest year is the snapshot's, so that year is an input")
  (check-false (memq 'snapshot-meta (task-inputs (hash-ref (graph-tasks salishsea-graph) pages)))
               "but not the moment it was taken, which moves every build: a no-op build skips the pages"))
(check-equal? (sort (task-inputs (hash-ref (graph-tasks salishsea-graph) 'ecotype-pages)) symbol<?)
              '(ecotype-occurrences-snapshot group-parents-snapshot snapshot-year social-groups-snapshot)
              "a kind's inputs are the tables profiles.ts loads for it, and no others")
(check-equal? (sort (task-inputs (hash-ref (graph-tasks salishsea-graph) 'haulout-pages)) symbol<?)
              '(haulout-occurrences-snapshot haulouts-snapshot snapshot-year)
              "a haul-out page reads the sites and their reports: the register holds no places")
(check-false (memq 'snapshot-meta (task-inputs (hash-ref (graph-tasks salishsea-graph) 'profile-index)))
             "the redirects and the sitemap don't depend on when the snapshot was taken, so they cut off")

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
