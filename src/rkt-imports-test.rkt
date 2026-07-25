#lang racket/base

;; The Racket local-require scan (st-egh). What it must get right is narrow but
;; load-bearing: a `derivation' node's code list is built from this, and anything
;; the scan misses is a module whose edit does NOT invalidate the node's cache —
;; a silent stale hit, the defect this exists to prevent.

(require rackunit
         racket/file
         racket/list
         racket/path
         racket/string
         "rkt-imports.rkt")

(define tmp (make-temporary-file "stelis-rktimports-~a" 'directory))
(define (write-module! name . lines)
  (define p (build-path tmp name))
  (display-to-file (string-join (cons "#lang racket/base" lines) "\n") p #:exists 'replace)
  p)
(define (names ps) (sort (map (lambda (p) (path->string (file-name-from-path p))) ps) string<?))

;; a -> b -> c, with a also pulling a collection module and a for-syntax require
(define a (write-module! "a.rkt"
                         "(require racket/list \"b.rkt\")"
                         "(require (for-syntax \"d.rkt\"))"
                         "(provide x) (define x 1)"))
(void (write-module! "b.rkt" "(require \"c.rkt\" (only-in racket/string string-trim))" "(provide y) (define y 2)"))
(void (write-module! "c.rkt" "(provide z) (define z 3)"))
(void (write-module! "d.rkt" "(provide w) (define w 4)"))

;; --- direct requires -------------------------------------------------------------

(check-equal? (names (module-local-requires a)) '("b.rkt" "d.rkt")
              "string requires are taken — including under for-syntax")
(check-false (memf (lambda (p) (regexp-match? #rx"racket" (path->string p)))
                   (module-local-requires a))
             "collection requires are NOT followed: they are pinned by the package install, not source here")
(check-equal? (names (module-local-requires (build-path tmp "b.rkt"))) '("c.rkt")
              "a string inside only-in is still the module path")

;; --- the closure -----------------------------------------------------------------

(check-equal? (names (rkt-import-closure a)) '("a.rkt" "b.rkt" "c.rkt" "d.rkt")
              "transitive, entry included — c.rkt is two hops away and MUST be hashed")
(check-equal? (rkt-import-closure a) (rkt-import-closure a)
              "stable order, so the recorded code list is byte-identical build to build")
(check-equal? (names (rkt-import-closure a (build-path tmp "c.rkt")))
              '("a.rkt" "b.rkt" "c.rkt" "d.rkt")
              "several entries union, without duplicating the shared tail")

;; --- degradation -------------------------------------------------------------------

(define cyc-a (write-module! "cyc-a.rkt" "(require \"cyc-b.rkt\")"))
(void (write-module! "cyc-b.rkt" "(require \"cyc-a.rkt\")"))
(check-equal? (names (rkt-import-closure cyc-a)) '("cyc-a.rkt" "cyc-b.rkt")
              "a require cycle terminates rather than looping")

(define ghost (write-module! "ghost.rkt" "(require \"missing.rkt\")"))
(check-equal? (names (rkt-import-closure ghost)) '("ghost.rkt" "missing.rkt")
              "a nonexistent require is KEPT — the cache then reports it unresolvable and reruns")

(display-to-file "#lang racket/base\n(require \"b.rkt\"" (build-path tmp "broken.rkt") #:exists 'replace)
(check-equal? (module-local-requires (build-path tmp "broken.rkt")) '()
              "an unreadable module yields no requires rather than taking down graph authoring")

;; --- the real thing ----------------------------------------------------------------
;; The concrete miss that motivated this: taxon-derive.rkt requires duckdb.rkt, and
;; the hand-listed code set did not include it, so changing how DuckDB is invoked
;; left the node cache-skipping on stale output.

(define seam (build-path (current-directory) "src" "taxon-derive.rkt"))
(when (file-exists? seam)
  (define closure (names (rkt-import-closure seam)))
  (for ([m (in-list '("taxon-derive.rkt" "taxon-inherit.rkt" "duckdb.rkt" "cache.rkt" "model.rkt"))])
    (check-true (and (member m closure) #t)
                (format "~a is in the real seam's closure" m))))

(delete-directory/files tmp)
