#lang racket/base

;; Integration retro-validation for the edge-verify harness (st-qp7): run the real
;; terminal tasks against a reference build and assert every declared edge is
;; input-sufficient and output-complete. This shells into the uv/3.14 runtime and
;; needs both beeatlas and a POPULATED reference EXPORT_DIR (the @export copies a
;; prior build left in the scratch out-dir), so it is GATED: when the reference or
;; beeatlas is absent (a bare checkout / CI), it prints a skip note and passes,
;; keeping `raco test src/*-test.rkt` green. Locally, after any build, it validates.
;;
;; The pure classification core is tested unconditionally in edge-verify-test.rkt;
;; this file is the environment-coupled half, kept separate for that reason.

(require rackunit
         "beeatlas.rkt"
         "edge-verify.rkt")

;; the four shipped terminals whose edges have been built+verified (st-h4m, st-4cm)
(define TERMINALS '(generate-sqlite species-export collectors-export places-export))

;; reference = the scratch out-dir a prior --build populates with @export copies
(define reference (build-path (find-system-path 'temp-dir) "stelis-out"))

;; the EXPORT_DIR inputs the terminals need seeded (by basename)
(define REQUIRED-SEEDS
  '("occurrences.parquet" "occurrence_places.parquet" "species.parquet"))

(define (reference-usable?)
  (and (file-exists? beeatlas-db)          ; beeatlas checkout present
       (directory-exists? reference)
       (for/and ([f (in-list REQUIRED-SEEDS)])
         (file-exists? (build-path reference f)))))

(cond
  [(reference-usable?)
   (test-case "shipped terminals verify input-sufficient and output-complete"
     (check-true
      (verify-edges beeatlas-graph TERMINALS beeatlas-runtimes beeatlas-path reference)
      "every shipped terminal's declared edge verifies clean"))]
  [else
   (printf "edge-verify integration: SKIPPED — no usable reference at ~a\n"
           reference)
   (printf "  (run e.g. `racket src/main.rkt --build occurrences.db` first)\n")])
