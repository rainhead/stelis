#lang racket/base

;; Unit tests for the declared fan-out key (st-tul). The pure core (template
;; matching, set classification) is filesystem-free; the IO (json-column-keys,
;; dir-relpaths, verify-fan-out-key) runs over tiny fixtures in a scratch dir.

(require rackunit
         racket/set
         racket/file
         json
         "fan-out-key.rkt")

;; write a jsexpr (list of hasheq objects) as JSON, like the real *.json exports
(define (write-json-file jsexpr path)
  (call-with-output-file path #:exists 'replace
    (lambda (o) (write-json jsexpr o))))

;; --- template-parts / file->key: the template inverse ------------------------

(let-values ([(pre post) (template-parts "{}.svg")])
  (check-equal? (list pre post) '("" ".svg") "flat template splits around {}"))
(let-values ([(pre post) (template-parts "genus/{}.svg")])
  (check-equal? (list pre post) '("genus/" ".svg") "nested template keeps the subdir prefix"))
(check-exn #rx"placeholder" (lambda () (template-parts "no-brace.svg"))
           "a template without {} is a declaration error")

(check-equal? (file->key "{}.svg" "alta-lake.svg") "alta-lake"
              "a flat file yields its key")
(check-equal? (file->key "genus/{}.svg" "genus/Andrena.svg") "Andrena"
              "a nested file yields its key, prefix stripped")
(check-false (file->key "genus/{}.svg" "subgenus/Foo.svg")
             "a wrong prefix does not match this branch")
(check-false (file->key "{}.svg" "notes.json")
             "a wrong suffix does not match")
(check-false (file->key "{}.svg" ".svg")
             "an empty key (suffix only) is not a match")

;; --- classify-fan-out: soundness (orphans) vs completeness (incomplete) -------

(let-values ([(orphans incomplete)
              (classify-fan-out (set "a" "b") (set "a" "b" "c" "d"))])
  (check-equal? orphans '() "filtered subset -> no orphans (sound)")
  (check-equal? incomplete '("c" "d") "unproduced input keys are reported, sorted"))
(let-values ([(orphans incomplete)
              (classify-fan-out (set "a" "ghost") (set "a" "b"))])
  (check-equal? orphans '("ghost") "a file whose key isn't an input key is an orphan")
  (check-equal? incomplete '("b") "and the uncovered input key is incomplete"))

;; --- IO over fixtures --------------------------------------------------------

(define tmp (make-temporary-file "stelis-fok-~a" 'directory))
(define (at . parts) (apply build-path tmp parts))

;; a JSON array-of-objects input, like places.json
(define places.json (at "places.json"))
(write-json-file
 (list (hasheq 'slug "alta-lake" 'name "Alta Lake")
       (hasheq 'slug "bee-hill"  'name "Bee Hill")
       (hasheq 'slug "cold-creek" 'name "Cold Creek")   ; filtered: no map produced
       (hasheq 'name "no-slug-here"))                    ; missing key -> skipped
 places.json)
(check-equal? (json-column-keys places.json "slug")
              (set "alta-lake" "bee-hill" "cold-creek")
              "json-column-keys pulls the column, skipping missing values")

;; a produced directory: two real maps + one nested file under a group prefix
(define maps (at "place-maps"))
(make-directory maps)
(display-to-file "svg" (build-path maps "alta-lake.svg"))
(display-to-file "svg" (build-path maps "bee-hill.svg"))
(check-equal? (list->set (dir-relpaths maps))
              (set "alta-lake.svg" "bee-hill.svg")
              "dir-relpaths lists regular files as posix relative paths")

;; --- verify-fan-out-key: the driver ------------------------------------------

(define (resolve a)
  (case a [(places.json) places.json] [else #f]))
(define branches (list (fan-out 'places.json "slug" "{}.svg")))

;; clean, filtered case: 2 of 3 places have maps -> sound, 1 incomplete
(let ([v (verify-fan-out-key branches maps resolve)])
  (check-true (fan-out-verdict-sound? v) "no orphans: every map is a real place")
  (check-equal? (fan-out-verdict-sound-files v) 2 "two produced files, both keyed to an input")
  (check-equal? (fan-out-verdict-incomplete v) '((places.json . "cold-creek"))
                "the filtered-out place is reported incomplete, not failed"))

;; an ORPHAN: a map whose slug is not in places.json -> unsound
(display-to-file "svg" (build-path maps "ghost-place.svg"))
(let ([v (verify-fan-out-key branches maps resolve)])
  (check-false (fan-out-verdict-sound? v) "an orphan map fails soundness")
  (check-equal? (fan-out-verdict-orphans v) '("ghost-place.svg")
                "the orphan file is named"))
(delete-file (build-path maps "ghost-place.svg"))

;; a file NO branch template explains is also an orphan
(display-to-file "x" (build-path maps "README.txt"))
(let ([v (verify-fan-out-key branches maps resolve)])
  (check-equal? (fan-out-verdict-orphans v) '("README.txt")
                "a file matching no branch template is an orphan"))
(delete-file (build-path maps "README.txt"))

;; --- multi-branch: a species-maps-shaped dir (slug + genus rank) -------------

(define species.json (at "species.json"))
(write-json-file
 (list (hasheq 'slug "Andrena/prunorum" 'genus "Andrena")
       (hasheq 'slug "Bombus/vosnesenskii" 'genus "Bombus"))
 species.json)
(define smaps (at "species-maps"))
(make-directory* (build-path smaps "Andrena"))
(make-directory* (build-path smaps "Bombus"))
(make-directory* (build-path smaps "genus"))
(display-to-file "svg" (build-path smaps "Andrena" "prunorum.svg"))   ; per-species
(display-to-file "svg" (build-path smaps "Bombus" "vosnesenskii.svg")) ; per-species
(display-to-file "svg" (build-path smaps "genus" "Andrena.svg"))       ; genus rank
;; note: no genus/Bombus.svg -> Bombus genus key is incomplete (allowed)
(define sbranches
  (list (fan-out 'species.json "slug" "{}.svg")
        (fan-out 'species.json "genus" "genus/{}.svg")))
(define (sresolve a) (case a [(species.json) species.json] [else #f]))
(let ([v (verify-fan-out-key sbranches smaps sresolve)])
  (check-true (fan-out-verdict-sound? v)
              "multi-branch: per-species AND genus files all key to species.json")
  (check-equal? (fan-out-verdict-sound-files v) 3 "three produced files (2 species + 1 genus), all sound")
  (check-equal? (fan-out-verdict-incomplete v) '((species.json . "Bombus"))
                "the missing Bombus genus map is reported incomplete"))

(delete-directory/files tmp)
