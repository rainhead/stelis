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
(check-equal? (set-count pruned) 12
              (string-append "the calendar, the id index, the pages, the profile index, the manifest, "
                             "and the two ports and their gates are off the path to days"))

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
  (check-not-false (memq 'snapshot-meta (task-inputs (hash-ref (graph-tasks salishsea-graph) pages)))
                   "the presence table's newest year is the snapshot's, so its time is an input"))
(check-equal? (sort (task-inputs (hash-ref (graph-tasks salishsea-graph) 'ecotype-pages)) symbol<?)
              '(ecotype-occurrences-snapshot group-parents-snapshot snapshot-meta social-groups-snapshot)
              "a kind's inputs are the tables profiles.ts loads for it, and no others")
(check-equal? (sort (task-inputs (hash-ref (graph-tasks salishsea-graph) 'haulout-pages)) symbol<?)
              '(haulout-occurrences-snapshot haulouts-snapshot snapshot-meta)
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
