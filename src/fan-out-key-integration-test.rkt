#lang racket/base

;; Integration validation for the fan-out-key harness (st-tul, st-5jt): check the
;; declared fan-outs of place-maps (single JSON key) and species-maps (five parquet
;; keys incl. the composite subgenus (genus,subgenus)) against a reference build.
;; Like edge-verify's integration half (and determinism.rkt), it needs beeatlas plus
;; a POPULATED reference EXPORT_DIR — the built directories and their key inputs
;; (places.json, species.parquet). GATED: absent that reference (a bare checkout /
;; CI), it prints a skip note and passes, keeping `raco test src/*-test.rkt` green.
;;
;; The pure classification core is tested unconditionally in fan-out-key-test.rkt;
;; this file is the environment-coupled half (and the only place the parquet key
;; source, which needs DuckDB, is exercised), kept separate for that reason.

(require rackunit
         "beeatlas.rkt"
         "fan-out-key.rkt")

;; the keyed 'dir terminals whose fan-out has been wired (st-tul, st-5jt)
(define KEYED-TASKS '(places-maps species-maps))

;; reference = the scratch out-dir a prior --build/--run populates
(define reference (build-path (find-system-path 'temp-dir) "stelis-out"))

;; (built dir . key-source file) each keyed terminal needs present in the reference
(define REQUIRED '(("place-maps" . "places.json") ("species-maps" . "species.parquet")))

(define (reference-usable?)
  (and (file-exists? beeatlas-db)                          ; beeatlas checkout present
       (for/and ([r (in-list REQUIRED)])
         (and (directory-exists? (build-path reference (car r)))  ; the built dir set
              (file-exists? (build-path reference (cdr r)))))))   ; its key source

(cond
  [(reference-usable?)
   (test-case "place-maps + species-maps are sound data-dependent sets (files ⊆ input keys)"
     (check-true
      (verify-fan-out-keys beeatlas-graph KEYED-TASKS beeatlas-path reference)
      "every produced file keys to a real input entity; filtered entities reported, not failed"))]
  [else
   (printf "fan-out-key integration: SKIPPED — no usable reference at ~a\n" reference)
   (printf "  (run e.g. `racket src/main.rkt --run places-maps` and `--run species-maps` first)\n")])
