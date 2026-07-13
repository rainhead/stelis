#lang racket/base

;; Integration validation for the fan-out-key harness (st-tul): check the declared
;; fan-out of place-maps against a reference build. Like edge-verify's integration
;; half (and determinism.rkt), it needs beeatlas plus a POPULATED reference
;; EXPORT_DIR — here, the built place-maps/ directory and its key input places.json.
;; GATED: absent that reference (a bare checkout / CI), it prints a skip note and
;; passes, keeping `raco test src/*-test.rkt` green. Locally, after building
;; places-maps, it asserts the directory is a SOUND data-dependent set.
;;
;; The pure classification core is tested unconditionally in fan-out-key-test.rkt;
;; this file is the environment-coupled half, kept separate for that reason.

(require rackunit
         "beeatlas.rkt"
         "fan-out-key.rkt")

;; the keyed 'dir terminal(s) whose fan-out has been wired (st-tul)
(define KEYED-TASKS '(places-maps))

;; reference = the scratch out-dir a prior --build/--run populates
(define reference (build-path (find-system-path 'temp-dir) "stelis-out"))

(define (reference-usable?)
  (and (file-exists? beeatlas-db)                          ; beeatlas checkout present
       (directory-exists? (build-path reference "place-maps")) ; the built dir set
       (file-exists? (build-path reference "places.json"))))   ; its key input

(cond
  [(reference-usable?)
   (test-case "place-maps is a sound data-dependent set (files ⊆ places.json slugs)"
     (check-true
      (verify-fan-out-keys beeatlas-graph KEYED-TASKS beeatlas-path reference)
      "every produced map keys to a real place; filtered places are reported, not failed"))]
  [else
   (printf "fan-out-key integration: SKIPPED — no usable reference at ~a\n" reference)
   (printf "  (run e.g. `racket src/main.rkt --run places-maps` first)\n")])
