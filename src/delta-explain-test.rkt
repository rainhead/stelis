#lang racket/base

;; Integration test for the impure adapter (st-2hh): input-key-deltas must read a
;; changed keyed input's LIVE on-disk map, diff it against that input's last
;; recorded key-observation in a real .stelis history, and name the moved subset.
;; This exercises the IO seam the pure delta-test can't — tree-hashes over a real
;; directory + a real history round-trip.

(require rackunit
         racket/file
         "model.rkt"
         "cache.rkt"
         "history.rkt"
         "trace.rkt"
         "tree-digest.rkt"
         "delta.rkt"
         "delta-explain.rkt")

;; a tiny graph: task `mk` produces the 'dir `maps`, task `use` consumes it.
(define g
  (build-graph
   (list (make-task 'mk  'transform #:outputs '(maps))
         (make-task 'use 'transform #:inputs '(maps)))
   (list (make-artifact 'maps 'dir))))

(define root  (make-temporary-file "stelis-dx-~a" 'directory))
(define state (build-path root ".stelis"))
(define live  (build-path root "maps"))          ; the live on-disk 'dir

;; the PREVIOUS state, hashed exactly as the history recorded it — build it, take
;; its tree-hashes, then that's what we persist as `maps`' key-observation.
(make-directory live)
(display-to-file "A"  (build-path live "a.svg"))
(display-to-file "B"  (build-path live "b.svg"))
(define prev-keys (tree-hashes live))            ; (("a.svg" . h) ("b.svg" . h))

;; record one build in which `mk` produced `maps` with those per-key hashes.
(void (history-append! state 'maps g "0"
                       (list (trace-record 'mk #f #f 'ok '() #f
                                           (list (cons 'maps "dir-digest"))
                                           (list (cons 'maps prev-keys))))))

;; now MUTATE the live dir: a.svg unchanged, b.svg edited, c.svg added.
(display-to-file "BB" (build-path live "b.svg") #:exists 'replace)
(display-to-file "C"  (build-path live "c.svg"))

;; env resolves 'maps to the live dir (its export-dir arg is unused here).
(define env (make-build-env (lambda (a _dir) (if (eq? a 'maps) live #f))
                            root (build-path state "cache")))

;; the decision `use` would get: run, inputs changed, naming `maps`.
(define d (decision 'run 'input-changed '(maps)))

(define deltas (input-key-deltas g d env state))
(check-equal? (length deltas) 1 "one changed keyed input -> one delta")
(define kd (car deltas))
(check-equal? (key-delta-artifact kd) 'maps)
(check-equal? (key-delta-to-build kd) 'pending "the live map is a pending build")
(check-equal? (key-delta-changed kd) '("b.svg") "edited file -> changed")
(check-equal? (key-delta-added kd)   '("c.svg") "new file -> added")
(check-equal? (key-delta-removed kd) '()        "nothing removed")
(check-equal? (key-delta-total kd)   3          "live map has 3 files")

;; a decision that isn't an 'input-changed run yields no deltas.
(check-equal? (input-key-deltas g (decision 'skip 'cached '()) env state) '()
              "a cached skip names no changed inputs")
(check-equal? (input-key-deltas g (decision 'run 'no-cache-entry '()) env state) '()
              "a non-input-changed run names none either")

;; the decorated renderer appends the subset line to the base reason.
(define reason->string (make-reason->string g env state))
(define rendered (reason->string d))
(check-true (regexp-match? #rx"inputs changed: maps" rendered) "keeps the base prose")
(check-true (regexp-match? #rx"maps → .*b\\.svg" rendered)     "adds the moved subset")

;; --- the db-relation path: per-COLUMN, not per-file ---------------------------
;; Same adapter, the other keyed kind: live columns come from the env's
;; resolve-relation-columns slot (not tree-hashes), and values are "digest:count"
;; strings. This pins the branch --history/--why share for db-relations.
(define g2
  (build-graph
   (list (make-task 'load 'transform #:outputs '(rel))
         (make-task 'use2 'transform #:inputs '(rel)))
   (list (make-artifact 'rel 'db-relation))))

(define state2 (build-path root ".stelis-rel"))

;; recorded per-column observation for `rel` at one build.
(define prev-cols (list (cons "col_a" "da:10") (cons "col_b" "db:5")))
(void (history-append! state2 'rel g2 "0"
                       (list (trace-record 'load #f #f 'ok '() #f
                                           (list (cons 'rel "rel-digest"))
                                           (list (cons 'rel prev-cols))))))

;; live columns: col_a's digest changed, col_b unchanged, col_c is new.
(define live-cols (list (cons "col_a" "dX:11") (cons "col_b" "db:5") (cons "col_c" "dc:3")))
(define env2 (make-build-env (lambda (_a _dir) #f)   ; a db-relation has no path
                             root (build-path state2 "cache")
                             #:resolve-relation-columns
                             (lambda (a) (if (eq? a 'rel) live-cols #f))))

(define rel-deltas (input-key-deltas g2 (decision 'run 'input-changed '(rel)) env2 state2))
(check-equal? (length rel-deltas) 1 "one changed keyed db-relation -> one delta")
(define rd (car rel-deltas))
(check-equal? (key-delta-artifact rd) 'rel)
(check-equal? (key-delta-changed rd) '("col_a") "re-digested column -> changed")
(check-equal? (key-delta-added rd)   '("col_c") "new column -> added")
(check-equal? (key-delta-removed rd) '()        "nothing removed")
(check-equal? (key-delta-total rd)   3          "3 live columns")
(check-equal? (key-delta->string rd) "2 of 3 keys: +col_c ~col_a"
              "prose names moved columns, same +/~/- grammar as 'dir")

(delete-directory/files root)
