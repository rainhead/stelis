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

;; --- dbt's sources vs. dbt-build's declared inputs (st-7hw) --------------------
;;
;; dbt-build is the graph's one opaque task: nine mart outputs from a `run.sh build'
;; that Stelis cannot see into. Its #:inputs are therefore hand-transcribed from what
;; dbt's models actually read, and that transcription silently rotted — it named 14 of
;; the 22 source() tables, and the eight it missed included the geography three of its
;; own marts are made of. Nothing failed. maderas served counties simplified 15x past
;; what the source supports for weeks, and a reload of that geography would have
;; cache-skipped because no declared input moved.
;;
;; So: derive the expectation from dbt instead of trusting the transcription — the
;; py-imports/rkt-imports move (st-6ga, st-egh), where hand-listing was likewise the
;; thing that broke. dbt already declares its reads in source() calls; this makes them
;; the authority and the #:inputs list the thing under test.
;;
;; This does NOT check the reverse direction. An input declared here that dbt never
;; reads is over-declaration: it costs a spurious rebuild, never a wrong skip, and the
;; gates and tokens in the list have no source() to match anyway.

(define dbt-models-dir (build-path BEEATLAS "data" "dbt" "models"))

;; The qualified `schema.table' of every source() call across dbt's models, deduped.
;; Regex, for the same reason as above: dbt's own parse needs the whole project loaded
;; under a 3.13 interpreter, and the call shape is fixed and machine-written.
(define (dbt-source-tables)
  (remove-duplicates
   (for*/list ([f (in-list (find-files (lambda (p) (regexp-match? #px"\\.sql$" p))
                                       dbt-models-dir))]
               [m (in-list (regexp-match* #px"source\\(\\s*'([a-z_]+)'\\s*,\\s*'([a-z_]+)'\\s*\\)"
                                          (file->string f)
                                          #:match-select cdr))])
     (string-append (car m) "." (cadr m)))))

;; Which artifacts of this graph OCCUPY a given physical table. Deliberately a list:
;; canonical_to_taxon_id, checklist_resolved and inactive_remaps all name the same
;; table, so "is this table in the input address?" is satisfied by ANY of them.
(define (artifacts-occupying table)
  (for/list ([a (in-hash-keys (graph-artifacts beeatlas-graph))]
             #:when (member table (or (beeatlas-relation-tables a) '())))
    a))

(cond
  [(not (directory-exists? dbt-models-dir))
   (printf "SKIP beeatlas-contract-test (dbt sources): no beeatlas checkout at ~a\n" BEEATLAS)]
  [else
   (define tables (dbt-source-tables))
   (define declared (task-inputs (hash-ref (graph-tasks beeatlas-graph) 'dbt-build)))

   (check-true (>= (length tables) 15)
               (format "parsed ~a source() table(s) out of ~a — a near-empty result \
means the call shape changed and this check went blind, not that dbt stopped reading \
sources" (length tables) dbt-models-dir))

   (for ([table (in-list (sort tables string<?))])
     (define occupants (artifacts-occupying table))
     (check-pred pair? occupants
                 (format "dbt reads ~a, but no artifact in the graph maps to it — add \
a case arm to beeatlas-relation-tables, or dbt-build can never hash this table" table))
     (when (pair? occupants)
       (check-true (for/or ([a (in-list occupants)]) (and (memq a declared) #t))
                   (format "dbt reads ~a — held by ~a — but dbt-build declares none of \
them, so a change to that table is a WRONG SKIP, not a rebuild" table occupants))))])
