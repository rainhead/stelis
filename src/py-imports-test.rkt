#lang racket/base

;; Tests for the Python import extractor (st-6ga).

(require rackunit
         racket/file
         racket/set
         "py-imports.rkt")

(define locals (set "config" "domain" "canonical_name" "inaturalist_pipeline"
                    "resolve_taxon_ids" "species_maps"))

;; --- parse-local-imports: shapes it must and must not catch -------------------

(test-case "plain `import x' and `from x import y', local only"
  (check-equal? (parse-local-imports "import config\nfrom domain import slugify\n"
                                     locals)
                '("config" "domain")))

(test-case "installed packages and stdlib are rejected by the membership test"
  ;; `notes_store' is a package, not a data/ file; `os'/`typing' are stdlib.
  (check-equal? (parse-local-imports
                 "import os\nfrom typing import List\nfrom notes_store.db import make_engine\n"
                 locals)
                '()))

(test-case "dotted local path keeps only the package root"
  (check-equal? (parse-local-imports "from config.sub import X\n" locals)
                '("config")))

(test-case "comma list and `as' aliases"
  (check-equal? (parse-local-imports "import config, domain as d\n" locals)
                '("config" "domain")))

(test-case "indented (lazy) imports inside a function ARE included"
  (check-equal? (parse-local-imports
                 "def f():\n    from resolve_taxon_ids import _pick_match\n"
                 locals)
                '("resolve_taxon_ids")))

(test-case "docstring prose does not false-positive"
  ;; Both real cases from the beeatlas source: a `from x.py (...' fragment (no
  ;; `import' keyword) and a `from <word> ...' sentence (word isn't a local module).
  (check-equal? (parse-local-imports
                 "\"\"\"reuse a helper from species_maps.py (RESEARCH note).\n    from the matched result's own rank field.\"\"\"\n"
                 locals)
                '()))

(test-case "distinct, duplicates collapsed (imports precede from-imports)"
  (check-equal? (parse-local-imports
                 "from domain import a\nimport config\nfrom domain import b\n"
                 locals)
                '("config" "domain")))

;; --- import-closure: transitivity (the config.py punt this fixes) ------------

;; A fake module set: places_maps -> species_maps -> config (config imports
;; nothing local). The hand list stopped at species_maps; the closure reaches
;; config too.
(define fake-src
  (hash "places_maps"  "from species_maps import _write_species_svg\n"
        "species_maps" "from config import STATE_FIPS\n"
        "config"       "import tomllib\n"))
(define fake-locals (list->set (hash-keys fake-src)))
(define (fake-read name) (hash-ref fake-src name #f))

(test-case "transitive closure reaches the second hop, excludes the entry"
  (check-equal? (import-closure fake-read fake-locals "places_maps")
                '("config" "species_maps")))

(test-case "an entry that imports nothing local has an empty closure"
  (check-equal? (import-closure fake-read fake-locals "config") '()))

(test-case "a cycle terminates (each module visited once)"
  (define cyc (hash "a" "from b import x\n" "b" "from a import y\n"))
  (check-equal? (import-closure (lambda (n) (hash-ref cyc n #f))
                                (list->set (hash-keys cyc)) "a")
                '("b")))

(test-case "a missing module reads as importing nothing"
  (check-equal? (import-closure (lambda (n) #f) (set "a" "b") "a") '()))

;; --- make-data-import-scan: direct (edges) vs closure (flattened), one read ---
;; st-whi authors task→helper inputs and helper→helper `imports' edges from the
;; DIRECT lookup; the closure half stays for flattened-list callers. Same fake
;; two-hop chain as above, on a real scratch directory.

(define scan-dir (make-temporary-file "stelis-py-scan-~a" 'directory))
(display-to-file "from species_maps import render\n" (build-path scan-dir "places_maps.py"))
(display-to-file "from config import STATE_FIPS\n"   (build-path scan-dir "species_maps.py"))
(display-to-file "import tomllib\n"                  (build-path scan-dir "config.py"))
(define-values (scan-direct scan-closure) (make-data-import-scan scan-dir))

(test-case "direct stops at the first hop; closure reaches the second"
  (check-equal? (scan-direct "places_maps") '("species_maps.py"))
  (check-equal? (scan-closure "places_maps") '("config.py" "species_maps.py")))

(test-case "a module with no local imports has no edges"
  (check-equal? (scan-direct "config") '())
  (check-equal? (scan-closure "config") '()))

(test-case "an unknown entry reads as importing nothing"
  (check-equal? (scan-direct "nope") '())
  (check-equal? (scan-closure "nope") '()))

(delete-directory/files scan-dir)

(test-case "an absent directory degrades to empty lookups (the CI shape)"
  (define-values (d c) (make-data-import-scan (build-path scan-dir "gone")))
  (check-equal? (d "places_maps") '())
  (check-equal? (c "places_maps") '()))
