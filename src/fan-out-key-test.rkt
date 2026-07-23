#lang racket/base

;; Unit tests for the declared fan-out key (st-tul, st-5jt). The pure core (template
;; arity, key-tuple extraction, set classification) is filesystem-free; the driver
;; (json-column-keys, verify-fan-out-key) runs over tiny JSON fixtures in a scratch
;; dir. The parquet key source is DuckDB-only and covered by the integration test.

(require rackunit
         racket/set
         racket/file
         json
         "fan-out-key.rkt")

;; write a jsexpr (list of hasheq objects) as JSON, like the real *.json exports
(define (write-json-file jsexpr path)
  (call-with-output-file path #:exists 'replace
    (lambda (o) (write-json jsexpr o))))

;; --- template arity + file->key: the template inverse (now tuple-valued) ------

(check-equal? (template-arity "{}.svg") 1 "one placeholder")
(check-equal? (template-arity "subgenus/{}/{}.svg") 2 "composite: two placeholders")

(check-equal? (file->key "{}.svg" "alta-lake.svg") '("alta-lake")
              "a flat file yields a 1-tuple")
(check-equal? (file->key "genus/{}.svg" "genus/Andrena.svg") '("Andrena")
              "a nested single-key file, prefix stripped")
(check-equal? (file->key "subgenus/{}/{}.svg" "subgenus/Andrena/Micrandrena.svg")
              '("Andrena" "Micrandrena")
              "a composite file yields the (genus, subgenus) tuple")
(check-equal? (file->key "{}.svg" "Andrena/prunorum.svg") '("Andrena/prunorum")
              "a slash inside a single-key slug stays in the one group")
(check-false (file->key "genus/{}.svg" "subgenus/Foo.svg")
             "a wrong prefix does not match this branch")
(check-false (file->key "{}.svg" "notes.json")
             "a wrong suffix does not match")

;; --- classify-fan-out: soundness (orphans) vs completeness (incomplete) -------

(let-values ([(orphans incomplete)
              (classify-fan-out (set '("a") '("b")) (set '("a") '("b") '("c") '("d")))])
  (check-equal? orphans '() "filtered subset -> no orphans (sound)")
  (check-equal? incomplete '(("c") ("d")) "unproduced input tuples are reported, sorted"))
(let-values ([(orphans incomplete)
              (classify-fan-out (set '("a") '("ghost")) (set '("a") '("b")))])
  (check-equal? orphans '(("ghost")) "a file tuple absent from the input is an orphan")
  (check-equal? incomplete '(("b")) "and the uncovered input tuple is incomplete"))

;; --- IO over fixtures ---------------------------------------------------------

(define tmp (make-temporary-file "stelis-fok-~a" 'directory))
(define (at . parts) (apply build-path tmp parts))

(define places.json (at "places.json"))
(write-json-file
 (list (hasheq 'slug "alta-lake" 'name "Alta Lake")
       (hasheq 'slug "bee-hill"  'name "Bee Hill")
       (hasheq 'slug "cold-creek" 'name "Cold Creek")   ; filtered: no map produced
       (hasheq 'name "no-slug-here"))                    ; missing key -> skipped
 places.json)
(check-equal? (json-column-keys places.json '("slug"))
              (set '("alta-lake") '("bee-hill") '("cold-creek"))
              "json-column-keys pulls a 1-column tuple set, skipping missing values")

;; composite: distinct (genus, subgenus) tuples, rows missing either are skipped
(define species.json (at "species.json"))
(write-json-file
 (list (hasheq 'genus "Andrena" 'subgenus "Micrandrena" 'slug "Andrena/prunorum")
       (hasheq 'genus "Andrena" 'subgenus "Micrandrena" 'slug "Andrena/wilkella") ; dup pair
       (hasheq 'genus "Bombus"  'subgenus "Pyrobombus"  'slug "Bombus/mixtus")
       (hasheq 'genus "Halictus" 'slug "Halictus/rubicundus"))                    ; no subgenus
 species.json)
(check-equal? (json-column-keys species.json '("genus" "subgenus"))
              (set '("Andrena" "Micrandrena") '("Bombus" "Pyrobombus"))
              "composite tuples are DISTINCT; a row missing a column is dropped")

;; --- verify-fan-out-key: single-branch driver (place-maps shape) --------------

(define maps (at "place-maps"))
(make-directory maps)
(display-to-file "svg" (build-path maps "alta-lake.svg"))
(display-to-file "svg" (build-path maps "bee-hill.svg"))
(define (presolve a) (case a [(places.json) places.json] [else #f]))
(define pbranches (list (fan-out 'places.json '("slug") "{}.svg")))

(let ([v (verify-fan-out-key pbranches maps presolve)])
  (check-true (fan-out-verdict-sound? v) "no orphans: every map is a real place")
  (check-equal? (fan-out-verdict-sound-files v) 2 "two produced files, both keyed")
  (check-equal? (fan-out-verdict-incomplete v) '((places.json . ("cold-creek")))
                "the filtered-out place is reported incomplete, not failed"))

(display-to-file "svg" (build-path maps "ghost-place.svg"))
(let ([v (verify-fan-out-key pbranches maps presolve)])
  (check-false (fan-out-verdict-sound? v) "an orphan map fails soundness")
  (check-equal? (fan-out-verdict-orphans v) '("ghost-place.svg") "the orphan file is named"))
(delete-file (build-path maps "ghost-place.svg"))

;; --- multi-branch composite driver (species-maps shape, JSON-sourced) ---------

(define smaps (at "species-maps"))
(make-directory* (build-path smaps "Andrena"))
(make-directory* (build-path smaps "Bombus"))
(make-directory* (build-path smaps "genus"))
(make-directory* (build-path smaps "subgenus" "Andrena"))
(display-to-file "svg" (build-path smaps "Andrena" "prunorum.svg"))         ; per-species slug
(display-to-file "svg" (build-path smaps "Bombus" "mixtus.svg"))            ; per-species slug
(display-to-file "svg" (build-path smaps "genus" "Andrena.svg"))            ; genus rank
(display-to-file "svg" (build-path smaps "subgenus" "Andrena" "Micrandrena.svg")) ; composite
(define (sresolve a) (case a [(species.json) species.json] [else #f]))
(define sbranches
  (list (fan-out 'species.json '("slug")             "{}.svg")
        (fan-out 'species.json '("genus")            "genus/{}.svg")
        (fan-out 'species.json '("genus" "subgenus") "subgenus/{}/{}.svg")))
(let ([v (verify-fan-out-key sbranches smaps sresolve)])
  (check-true (fan-out-verdict-sound? v)
              "per-species, genus, AND composite subgenus files all key to species.json")
  (check-equal? (fan-out-verdict-sound-files v) 4 "all four files explained"))

;; a composite orphan: a subgenus map for a (genus, subgenus) not in the input
(make-directory* (build-path smaps "subgenus" "Bombus"))
(display-to-file "svg" (build-path smaps "subgenus" "Bombus" "Ghostbombus.svg"))
(let ([v (verify-fan-out-key sbranches smaps sresolve)])
  (check-false (fan-out-verdict-sound? v) "a composite key absent from the input is an orphan")
  (check-equal? (fan-out-verdict-orphans v) '("subgenus/Bombus/Ghostbombus.svg")
                "the composite orphan is named by its relative path"))

;; --- declaration sanity: column count must match template placeholders --------

(check-exn #rx"columns but"
           (lambda ()
             (verify-fan-out-key (list (fan-out 'species.json '("genus") "subgenus/{}/{}.svg"))
                                 smaps sresolve))
           "1 column against a 2-placeholder template is a declaration error")

;; --- manifest file classification (st-q6i, the DB-free half) ------------------
;; produced files vs {manifest filenames ∪ singletons}: orphans on disk unexplained,
;; missing declared-but-absent. The filter_value↔column check needs DuckDB and is
;; covered by the integration test.
(let-values ([(orphans missing)
              (classify-manifest-files
               (list "collector-a.xml" "genus-b.xml" "index.json" "determinations.xml")
               (set "collector-a.xml" "genus-b.xml" "index.json" "determinations.xml"))])
  (check-equal? orphans '() "every on-disk file is indexed or a singleton")
  (check-equal? missing '() "every declared file is on disk"))
(let-values ([(orphans missing)
              (classify-manifest-files
               (list "collector-a.xml" "stray.xml" "index.json")     ; stray not indexed
               (set "collector-a.xml" "genus-b.xml" "index.json"))]) ; genus-b indexed, absent
  (check-equal? orphans '("stray.xml") "a file neither indexed nor a singleton is an orphan")
  (check-equal? missing '("genus-b.xml") "an indexed file not on disk is missing"))

;; --- template-fill: the substitution inverse of file->key ---------------------

(check-equal? (template-fill "{}.json" '("Bombus fervidus")) "Bombus fervidus.json"
              "a scalar key substitutes in, spaces intact")
(check-equal? (template-fill "subgenus/{}/{}.svg" '("Andrena" "Micrandrena"))
              "subgenus/Andrena/Micrandrena.svg" "composite tuples fill in order")
(check-exn #rx"does not fit"
           (lambda () (template-fill "{}.json" '("a" "b")))
           "a tuple wider than the template is a caller error")

;; --- verify-store-keyed: the identity gate (st-243, notes/ shape) -------------
;; The store keyset (via a fake resolve-store-keys — pairs shaped like
;; notes-store-keys' (canonical_name . "digest:count")) IS the expected fileset:
;; both directions gate.

(define notes (at "notes"))
(make-directory notes)
(display-to-file "[]" (build-path notes "Bombus fervidus.json"))
(display-to-file "[]" (build-path notes "Osmia lignaria.json"))
(define (store-resolve keys) (lambda (_a) (map (lambda (k) (cons k "d:1")) keys)))
(define sk (store-keyed 'notes-store.db "{}.json"))

(let ([v (verify-store-keyed sk notes (store-resolve '("Bombus fervidus" "Osmia lignaria")))])
  (check-true (fan-out-verdict-sound? v) "files == store keys: the identity holds")
  (check-equal? (fan-out-verdict-sound-files v) 2 "both files keyed")
  (check-equal? (fan-out-verdict-incomplete v) '() "identity leaves nothing merely-reported"))

;; a stale file for a retracted key (the un-pruned leftover a partial rebuild
;; could leave) is an orphan
(let ([v (verify-store-keyed sk notes (store-resolve '("Bombus fervidus")))])
  (check-false (fan-out-verdict-sound? v) "a file for a key not in the store fails")
  (check-equal? (fan-out-verdict-orphans v) '("Osmia lignaria.json") "…named by file"))

;; a store key with no file (a harvest that skipped one) ALSO gates — folded into
;; orphans with the manifest-style "missing:" prefix
(let ([v (verify-store-keyed sk notes
                             (store-resolve '("Andrena prunorum" "Bombus fervidus"
                                              "Osmia lignaria")))])
  (check-false (fan-out-verdict-sound? v) "a missing key fails, not just reports")
  (check-equal? (fan-out-verdict-orphans v) '("missing:Andrena prunorum.json")
                "the missing file is named via the template"))

;; a file the template doesn't explain is an orphan outright
(display-to-file "x" (build-path notes "README.txt"))
(let ([v (verify-store-keyed sk notes (store-resolve '("Bombus fervidus" "Osmia lignaria")))])
  (check-equal? (fan-out-verdict-orphans v) '("README.txt") "an unexplained file is an orphan")
  (check-equal? (fan-out-verdict-sound-files v) 2 "…and doesn't count as sound"))
(delete-file (build-path notes "README.txt"))

;; an unreadable store raises — the gate cannot vouch for what it cannot see
(check-exn #rx"could not read"
           (lambda () (verify-store-keyed sk notes (lambda (_a) #f)))
           "resolve-store-keys returning #f is an error, not a pass")

;; declaration sanity: store keys are scalar, so exactly one placeholder
(check-exn #rx"exactly one"
           (lambda () (verify-store-keyed (store-keyed 's "{}/{}.json") notes
                                          (store-resolve '())))
           "a composite template against a scalar store is a declaration error")

(delete-directory/files tmp)
