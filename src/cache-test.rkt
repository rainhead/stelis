#lang racket/base

;; Unit tests for the cache decision core (cache.rkt, st-yg7.1): the pure
;; `decide' over constructed snapshots and entries, then the IO round trip —
;; store, hit, change an input, lose an output — over a tiny synthetic graph
;; with real files in a scratch directory.

(require rackunit
         racket/file
         "model.rkt"
         "cache.rkt")

;; --- decide: the pure core ---------------------------------------------------

(define snap-a (snapshot "r1" (hash 'x "hx" 'y "hy")))
;; an entry as read-cache-entry returns it (input-hashes is a sorted alist)
(define (entry #:recipe [r "r1"] #:inputs [ins '((x . "hx") (y . "hy"))])
  (hash 'version 2 'recipe-hash r 'input-hashes ins 'outputs '()))

(define (reason d) (decision-reason d))

(check-equal? (decide snap-a (entry) '())
              (decision 'skip 'cached '())
              "same recipe, same inputs, outputs present -> cached")
(check-equal? (decide snap-a #f '())
              (decision 'run 'no-cache-entry '())
              "no usable entry -> run")
(check-equal? (decide snap-a (entry #:recipe "r0") '())
              (decision 'run 'recipe-changed '())
              "the command itself changed -> run")
(check-equal? (decide snap-a (entry #:inputs '((x . "OLD") (y . "hy"))) '())
              (decision 'run 'input-changed '(x))
              "a changed input is named")
(check-equal? (decide snap-a (entry #:inputs '((x . "hx"))) '())
              (decision 'run 'input-changed '(y))
              "an input the entry never saw counts as changed")
(check-equal? (decide snap-a (entry #:inputs '((x . "OLD") (y . "hy") (z . "hz"))) '())
              (decision 'run 'input-changed '(x z))
              "changed + removed inputs, in stable sorted order")
(check-equal? (decide snap-a (entry) '("out.db"))
              (decision 'run 'output-missing '("out.db"))
              "unchanged inputs but a recorded output is gone -> run")
(check-equal? (reason (decide snap-a (entry #:inputs '((x . "OLD") (y . "hy"))) '("out.db")))
              'input-changed
              "content change outranks missing output as the reason")

;; --- the IO round trip over a synthetic graph --------------------------------

(define tmp (make-temporary-file "stelis-cache-test-~a" 'directory))
(define cache-dir (build-path tmp "cache"))
(define raw-path  (build-path tmp "raw.csv"))
(define out-path  (build-path tmp "out.db"))
(define (resolve a)
  (case a [(raw) raw-path] [(out) out-path] [else #f]))

(define (graph-with-invoke invoke)
  (build-graph
   (list (make-task 'ingest      'boundary  #:outputs '(raw))
         (make-task 'xform       'transform #:inputs '(raw) #:outputs '(out)
                    #:invoke invoke)
         (make-task 'needs-token 'transform #:inputs '(raw token) #:outputs '(out2)))
   (list (make-artifact 'raw 'file) (make-artifact 'out 'file)
         (make-artifact 'out2 'file) (make-artifact 'token 'token))))
(define g (graph-with-invoke "v1"))

(display-to-file "a,b\n1,2\n" raw-path)
(display-to-file "db-bytes" out-path)

(check-equal? (task-decision g 'ingest resolve cache-dir '())
              (decision 'run 'boundary '())
              "boundary tasks are never content-skipped")
(check-equal? (task-decision g 'needs-token resolve cache-dir '())
              (decision 'run 'inputs-unresolvable '(token))
              "an unresolvable input is named")
(check-equal? (task-decision g 'xform resolve cache-dir (list out-path))
              (decision 'run 'no-cache-entry '())
              "first sight of a task -> run")

;; store, then ask again: a hit, through both the decision and boolean APIs
(define snap-1 (input-snapshot g 'xform resolve))
(check-pred snapshot? snap-1 "xform's inputs all resolve to files")
(cache-store! cache-dir 'xform snap-1 (list out-path))
(check-equal? (task-decision g 'xform resolve cache-dir (list out-path))
              (decision 'skip 'cached '())
              "stored + unchanged + outputs present -> cached")
(check-true (cache-hit? cache-dir 'xform snap-1 (list out-path))
            "cache-hit? agrees with the decision verdict")

;; change the input's content -> the changed input is named
(display-to-file "a,b\n9,9\n" raw-path #:exists 'replace)
(check-equal? (task-decision g 'xform resolve cache-dir (list out-path))
              (decision 'run 'input-changed '(raw))
              "a content change to raw is attributed to raw")

;; restore the input, lose the output
(display-to-file "a,b\n1,2\n" raw-path #:exists 'replace)
(delete-file out-path)
(check-equal? (task-decision g 'xform resolve cache-dir (list out-path))
              (decision 'run 'output-missing (list out-path))
              "inputs unchanged but the output is gone")
(display-to-file "db-bytes" out-path)

;; a different recipe against the same stored entry
(check-equal? (task-decision (graph-with-invoke "v2") 'xform resolve cache-dir
                             (list out-path))
              (decision 'run 'recipe-changed '())
              "editing the recipe invalidates the entry")

;; an old-format (v1) entry is a miss, never an error
(call-with-output-file (build-path cache-dir "xform.rktd") #:exists 'replace
  (lambda (o) (write (hash 'version 1 'input-fp "deadbeef" 'outputs '()) o)))
(check-equal? (task-decision g 'xform resolve cache-dir (list out-path))
              (decision 'run 'no-cache-entry '())
              "other-version entry reads as no entry")

(delete-directory/files tmp)
