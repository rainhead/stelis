#lang info
;; The engine as a Racket collection, `stelis` (st-ab3, ADR 0020): a project's graph
;; may live in the project's own repository and require the engine's modules by
;; collection path (stelis/model, stelis/project, stelis/relation-digest, ...) rather
;; than by a relative path into this checkout. scripts/link-collection.sh links this
;; directory under that name; the image, CI and a developer machine all run it.
;; The engine's own modules keep requiring each other by relative path, so nothing
;; inside the repo needs the link to run.
(define collection "stelis")
(define deps '("base" "datalog" "sha" "rackunit-lib"))
