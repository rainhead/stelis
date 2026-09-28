#lang racket/base

;; The salishsea graph as authored (st-ml9.2). Pure: nothing here launches a
;; task or needs a checkout — build-graph's own integrity checks already ran when
;; the module loaded, so this pins the SHAPE: what the day files depend on, and
;; that the project value carries the graph the CLI will select.

(require rackunit
         racket/set
         "model.rkt"
         "project.rkt"
         "salishsea.rkt")

(define-values (ordered pruned) (plan salishsea-graph 'days))
(check-equal? ordered '(snapshot occurrence-days)
              "the day files need exactly the snapshot, then the export")
(check-equal? (set-count pruned) 1 "only the manifest is off the path to days")

(define-values (manifest-plan _p) (plan salishsea-graph 'manifest.json))
(check-equal? manifest-plan '(snapshot occurrence-days manifest)
              "the manifest comes after the day files, so it never claims a build whose files aren't in place")

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
