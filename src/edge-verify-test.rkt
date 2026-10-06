#lang racket/base

;; Unit tests for the edge-verification harness's PURE core (st-qp7). The
;; integration driver (verify-edges) shells into the real runtimes against a
;; reference build and is exercised separately (see edge-verify.rkt's header);
;; here we test the filesystem-free classification and the EXPORT_DIR predicate,
;; which is where the harness's judgement actually lives.

(require rackunit
         racket/set
         racket/file
         racket/port
         "edge-verify.rkt"
         "model.rkt"
         "exec.rkt"
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

;; --- classify-mutations: inputs the run wrote to (st-8vm) -----------------

(check-equal? (classify-mutations (hash 'a "1" 'b "2") (hash 'a "1" 'b "2")) '()
              "unchanged inputs are not mutated")
(check-equal? (classify-mutations (hash 'b "2" 'a "1") (hash 'a "X" 'b "Y"))
              '("a" "b")
              "every rewritten input is named, sorted")
(check-equal? (classify-mutations (hash 'a "1") (hash 'a #f)) '("a")
              "an input the task deleted is mutated")
(check-equal? (classify-mutations (hash 'a #f) (hash 'a "1")) '("a")
              "an input absent beforehand that the task created is mutated")
(check-equal? (classify-mutations (hash 'a #f) (hash 'a #f)) '()
              "an input absent before and after is not")

;; --- verify-edge end to end, on /bin/sh: no beeatlas, so CI runs it too ------
;; The beeatlas-hyq shape: declares raw.geojson in and clean.geojson out, writes
;; clean.geojson honestly, and ALSO renames a tmp over its own input, exactly as
;; topology_postprocess.py's _run_mapshaper did. Before st-8vm this verified clean.
;; `extra' (the seed's path -> script text) is appended to the script; seed.csv
;; is a fixed-path, AMBIENT input.
(define (run-shaped extra)
  (define ref (make-temporary-directory))
  (define fixed (make-temporary-directory))
  (define seed (build-path fixed "seed.csv"))
  (display-to-file "ORIGINAL-GEOMETRY\n" (build-path ref "raw.geojson"))
  (display-to-file "synonym,accepted_name\n" seed)
  (define script (build-path fixed "job.sh"))
  (display-to-file
   (string-append "set -e\n"
                  "cat \"$EXPORT_DIR/raw.geojson\" > \"$EXPORT_DIR/clean.geojson\"\n"
                  (extra (path->string seed)))
   script)
  (define g
    (build-graph
     (list (make-task 'simplify 'transform
                      #:inputs '(raw.geojson seed.csv) #:outputs '(clean.geojson)
                      #:invoke (recipe 'sh (list (path->string script)))))
     (list (make-artifact 'raw.geojson 'file #:provenance 'upstream)
           (make-artifact 'seed.csv 'file #:provenance 'authoritative)
           (make-artifact 'clean.geojson 'file #:provenance 'derived))))
  (define (resolve a export-dir)
    (case a
      [(raw.geojson) (build-path export-dir "raw.geojson")]
      [(clean.geojson) (build-path export-dir "clean.geojson")]
      [(seed.csv) seed]
      [else #f]))
  (define v
    (parameterize ([current-output-port (open-output-nowhere)])
      (verify-edge g 'simplify (hash 'sh (runtime 'sh '("/bin/sh") "sh"))
                   resolve ref)))
  (delete-directory/files ref)
  (delete-directory/files fixed)
  v)

(let ([v (run-shaped (lambda (_) ""))])
  (check-true (edge-verdict-clean? v) "a task that only reads its inputs verifies clean")
  (check-equal? (edge-verdict-mutated v) '()))

(let ([v (run-shaped
          (lambda (_)
            (string-append
             "echo SIMPLIFIED-AGAIN > \"$EXPORT_DIR/raw.geojson.tmp\"\n"
             "mv \"$EXPORT_DIR/raw.geojson.tmp\" \"$EXPORT_DIR/raw.geojson\"\n")))])
  (check-false (edge-verdict-clean? v)
               "a task renaming over its own seeded input is NOT clean (the hyq shape)")
  (check-equal? (edge-verdict-mutated v) '("raw.geojson") "and the input is named")
  (check-equal? (edge-verdict-undeclared v) '()
                "it is not an undeclared output — the file was supposed to be there"))

(let ([v (run-shaped (lambda (seed) (format "echo extra,row >> '~a'\n" seed)))])
  (check-equal? (edge-verdict-mutated v) '("seed.csv")
                "an AMBIENT fixed-path input the task rewrites is caught too"))

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
