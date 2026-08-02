#lang racket/base

;; Cross-repo CONTRACT test (st-ljy): stelis's `precompressed-artifacts` names the
;; artifacts the precompress node compresses, and beeatlas's lib/runtime-artifacts.js
;; names the artifacts the CLIENT fetches. The first is supposed to mirror the second,
;; by hand — the node passes its list on argv precisely so that the GRAPH EDGE is
;; authoritative about what gets compressed, which is what keeps a directory from
;; changing without a declared input changing.
;;
;; That design makes drift SAFE and therefore SILENT. beeatlas publishes an artifact
;; stelis doesn't name: the publish compresses it in-process, slowly and correctly, and
;; says nothing. Stelis names one beeatlas no longer publishes: a sibling is written and
;; never copied. Neither fails; you just quietly stop getting the thing the node exists
;; for. Nothing else compares the two lists, so this does.
;;
;; GATED like the other environment-coupled suites (the CI-has-no-beeatlas idiom): with
;; no beeatlas checkout it prints a skip note and passes.

(require rackunit
         racket/file
         racket/list
         racket/string
         "model.rkt"
         "beeatlas.rkt")

(define runtime-artifacts-js (build-path BEEATLAS "lib" "runtime-artifacts.js"))

;; The `source:` values in beeatlas's RUNTIME_ARTIFACTS, in file order. A regex rather
;; than a JS parse: the file is a flat literal whose whole shape is
;; `key: { source: '<name>', basename: '<name>' },` — and if it stops being that, the
;; match count changes and this test says so instead of silently reading zero.
(define (beeatlas-runtime-sources)
  (for/list ([m (in-list (regexp-match* #px"source:\\s*'([^']+)'"
                                        (file->string runtime-artifacts-js)
                                        #:match-select cadr))])
    (string->symbol m)))

(cond
  [(not (file-exists? runtime-artifacts-js))
   (printf "SKIP beeatlas-contract-test: no beeatlas checkout at ~a\n" BEEATLAS)]
  [else
   (define beeatlas-sources (beeatlas-runtime-sources))

   (check-true (>= (length beeatlas-sources) 5)
               (format "parsed ~a source(s) out of runtime-artifacts.js — a near-empty \
result means the file's shape changed and this check went blind, not that beeatlas \
stopped publishing data" (length beeatlas-sources)))

   ;; SET equality, not list equality: neither side's ORDER means anything (stelis passes
   ;; them on argv, beeatlas iterates an object), so ordering differences are not drift.
   (check-equal? (sort (map symbol->string beeatlas-sources) string<?)
                 (sort (map symbol->string precompressed-artifacts) string<?)
                 "stelis's precompressed-artifacts must name exactly beeatlas's \
RUNTIME_ARTIFACTS sources — drift here is SILENT (the publish falls back to compressing \
in-process, or a sibling is written and never read), so nothing else would catch it")

   ;; …and each must be a real artifact this graph produces, or the node declares an
   ;; input nothing makes and fails at run time instead of at authoring time.
   (for ([a (in-list precompressed-artifacts)])
     (check-not-false (hash-ref (graph-artifacts beeatlas-graph) a #f)
                      (format "~a is precompressed but is not an artifact in the graph" a)))])
