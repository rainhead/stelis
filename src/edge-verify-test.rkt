#lang racket/base

;; Unit tests for the edge-verification harness's PURE core (st-qp7). The
;; integration driver (verify-edges) shells into the real runtimes against a
;; reference build and is exercised separately (see edge-verify.rkt's header);
;; here we test the filesystem-free classification and the EXPORT_DIR predicate,
;; which is where the harness's judgement actually lives.

(require rackunit
         racket/set
         "edge-verify.rkt"
         "beeatlas.rkt")

;; --- classify-outputs: declared vs appeared basenames -----------------------

;; exact match -> nothing missing, nothing undeclared
(let-values ([(missing undeclared)
              (classify-outputs (set "places.json" "places.geojson")
                                (set "places.json" "places.geojson"))])
  (check-equal? missing '() "all declared outputs appeared")
  (check-equal? undeclared '() "nothing beyond the declared outputs appeared"))

;; an undeclared write (the place_details.json bug) is surfaced
(let-values ([(missing undeclared)
              (classify-outputs (set "places.json" "places.geojson")
                                (set "places.json" "places.geojson" "place_details.json"))])
  (check-equal? missing '() "declared outputs present")
  (check-equal? undeclared '("place_details.json")
                "an output the edge failed to declare is reported as undeclared"))

;; a declared output that never got written is surfaced
(let-values ([(missing undeclared)
              (classify-outputs (set "places.json" "places.geojson")
                                (set "places.json"))])
  (check-equal? missing '("places.geojson") "a declared-but-unwritten output is missing")
  (check-equal? undeclared '() "nothing undeclared"))

;; results are sorted (deterministic report ordering)
(let-values ([(missing _u)
              (classify-outputs (set "c.json" "a.json" "b.json") (set))])
  (check-equal? missing '("a.json" "b.json" "c.json") "missing list is sorted"))

;; --- export-dir-artifact?: EXPORT_DIR reads vs fixed-path reads --------------

;; @export copies and terminal outputs vary with export-dir -> EXPORT_DIR
(check-true (export-dir-artifact? beeatlas-path 'occurrences.parquet@export)
            "@export mart copy is an EXPORT_DIR artifact")
(check-true (export-dir-artifact? beeatlas-path 'places.json)
            "a terminal export target is an EXPORT_DIR artifact")

;; sandbox marts, raw inputs, and db-relations do NOT vary with export-dir
(check-false (export-dir-artifact? beeatlas-path 'occurrences.parquet)
             "the sandbox mart is a fixed-path (ambient) input")
(check-false (export-dir-artifact? beeatlas-path 'taxa.csv.gz)
             "a raw input is fixed-path")
(check-false (export-dir-artifact? beeatlas-path 'geographies_places)
             "a db-relation resolves to #f — not an EXPORT_DIR file")
