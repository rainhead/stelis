#lang racket/base

;; Integration validation for the fan-out-key harness (st-tul, st-5jt, st-q6i):
;; check the declared fan-outs of place-maps (single JSON key), species-maps (five
;; parquet keys incl. the composite subgenus (genus,subgenus)), and feeds (manifest-
;; driven, keys checked against the ecdysis_data db-relation) against a reference
;; build. It needs beeatlas plus a POPULATED reference EXPORT_DIR — the built
;; directories and their key sources (places.json, species.parquet,
;; feeds/index.json) — and DuckDB. The reference is STELIS_REFERENCE_DIR, else the
;; scratch out-dir a plain --build fills.
;; GATED (test-gate.rkt): absent that environment it prints a NOT CHECKED note and
;; passes, unless STELIS_REQUIRE_GATED=1, when it fails.
;;
;; The pure classification core is tested unconditionally in fan-out-key-test.rkt;
;; this file is the environment-coupled half (and the only place the parquet key
;; source and the manifest DB check, which need DuckDB, are exercised).

(require rackunit
         "beeatlas.rkt"
         "fan-out-key.rkt"
         "test-gate.rkt")

;; the keyed 'dir terminals whose fan-out has been wired (st-tul, st-5jt, st-q6i)
(define KEYED-TASKS '(places-maps species-maps feeds))

;; reference = the scratch out-dir a prior --build/--run populates
(define reference (stelis-reference-dir))

;; (built dir . key-source relative to the reference root) each terminal needs
(define REQUIRED '(("place-maps" . "places.json")
                   ("species-maps" . "species.parquet")
                   ("feeds" . "feeds/index.json")))

(define (reference-usable?)
  (and (file-exists? beeatlas-db)                          ; beeatlas checkout present
       (find-executable-path "duckdb")                     ; parquet keys + manifest check need it
       (for/and ([r (in-list REQUIRED)])
         (and (directory-exists? (build-path reference (car r)))  ; the built dir set
              (file-exists? (build-path reference (cdr r)))))))   ; its key source

(cond
  [(reference-usable?)
   (test-case "place-maps + species-maps + feeds are sound data-dependent sets"
     (check-true
      (verify-fan-out-keys beeatlas-graph KEYED-TASKS beeatlas-path reference #:db beeatlas-db)
      "every produced file keys to a real input entity; filtered entities reported, not failed"))]
  [else
   (skip-or-fail "fan-out-key integration"
                 "no usable reference at ~a, so place-maps, species-maps and feeds were not checked (a build with --export-dir fills one; set STELIS_REFERENCE_DIR to it)"
                 reference)])

;; There is deliberately no notes/ arm here: the build runs that identity check
;; itself after every clean run of the producer (ADR 0016 D7), and as a pre-build
;; test it was wrong on the nightly hosts (see the commit that removed it, st-cip).
