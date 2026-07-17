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
(define (entry #:recipe [r "r1"] #:inputs [ins '((x . "hx") (y . "hy"))]
               #:out-hashes [outs '()])
  (hash 'version 3 'recipe-hash r 'input-hashes ins 'outputs '()
        'output-hashes outs))

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

;; stale db-relation outputs (st-84u): unchanged inputs, but a recorded db-relation
;; output no longer matches the current DuckDB -> rerun, not skip.
(check-equal? (decide snap-a (entry) '() '(rel))
              (decision 'run 'output-stale '(rel))
              "a stale db-relation output forces a rerun")
(check-equal? (reason (decide snap-a (entry) '("out.db") '(rel)))
              'output-missing
              "a missing file output outranks a stale relation")
(check-equal? (reason (decide snap-a (entry #:inputs '((x . "OLD") (y . "hy"))) '() '(rel)))
              'input-changed
              "a content change still outranks a stale relation")

;; stale-relation-outputs: which db-relation outputs no longer match the DuckDB.
(let* ([dummy (build-path "/tmp/cache-test-x")]
       [g (build-graph (list (make-task 'load 'transform #:outputs '(rel)))
                       (list (make-artifact 'rel 'db-relation)))]
       [env-now (make-build-env (lambda (_a _d) #f) dummy dummy
                                #:resolve-relation (lambda (a) (and (eq? a 'rel) "NOW")))]
       [env-gone (make-build-env (lambda (_a _d) #f) dummy dummy
                                 #:resolve-relation (lambda (_a) #f))]
       [env-none (make-build-env (lambda (_a _d) #f) dummy dummy)])
  (check-equal? (stale-relation-outputs g 'load env-now (entry #:out-hashes '((rel . "NOW")))) '()
                "current digest matches recorded -> not stale")
  (check-equal? (stale-relation-outputs g 'load env-now (entry #:out-hashes '((rel . "OLD")))) '(rel)
                "current digest differs (db mutated/swapped) -> stale")
  (check-equal? (stale-relation-outputs g 'load env-now (entry #:out-hashes '())) '(rel)
                "no recorded digest -> stale")
  (check-equal? (stale-relation-outputs g 'load env-gone (entry #:out-hashes '((rel . "NOW")))) '(rel)
                "table gone from the current db -> stale")
  (check-equal? (stale-relation-outputs g 'load env-none (entry #:out-hashes '((rel . "OLD")))) '()
                "no relation resolver -> nothing to check")
  (check-equal? (stale-relation-outputs g 'load env-now #f) '()
                "no cache entry -> nothing to check"))

;; --- compare-outputs: the pure cutoff question (st-8ig) -----------------------

(check-false (compare-outputs #f '((out . "h1")))
             "no prior entry — no basis to compare")
(check-false (compare-outputs (entry #:out-hashes '((out . "h1"))) '())
             "nothing hashable this run — no basis to compare")
(check-equal? (compare-outputs (entry #:out-hashes '((out . "h1"))) '((out . "h1")))
              (output-delta 'identical '(out))
              "rebuilt to identical content — the cutoff signal, outputs named")
(check-equal? (compare-outputs (entry #:out-hashes '((out . "h1"))) '((out . "h2")))
              (output-delta 'changed '(out))
              "a changed output is named")
(check-equal? (compare-outputs (entry #:out-hashes '((a . "h1"))) '((b . "h1")))
              (output-delta 'changed '(a b))
              "outputs present on only one side count as changed")

;; --- the IO round trip over a synthetic graph --------------------------------

(define tmp (make-temporary-file "stelis-cache-test-~a" 'directory))
(define cache-dir (build-path tmp "cache"))
(define raw-path  (build-path tmp "raw.csv"))
(define out-path  (build-path tmp "out.db"))
(define (resolve a)
  (case a [(raw) raw-path] [(out) out-path] [else #f]))
(define env (make-build-env (lambda (a _export-dir) (resolve a)) tmp cache-dir))

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

(check-equal? (task-decision g 'ingest env)
              (decision 'run 'boundary '())
              "boundary tasks are never content-skipped")
(check-equal? (task-decision g 'needs-token env)
              (decision 'run 'inputs-unresolvable '(token))
              "an unresolvable input is named")
(check-equal? (task-decision g 'xform env)
              (decision 'run 'no-cache-entry '())
              "first sight of a task -> run")

;; store, then ask again: a hit, through both the decision and boolean APIs
(define snap-1 (input-snapshot g 'xform resolve))
(check-pred snapshot? snap-1 "xform's inputs all resolve to files")
(cache-store! cache-dir 'xform snap-1 (list out-path) (output-snapshot g 'xform env))
(check-equal? (task-decision g 'xform env)
              (decision 'skip 'cached '())
              "stored + unchanged + outputs present -> cached")
(check-true (cache-hit? cache-dir 'xform snap-1 (list out-path))
            "cache-hit? agrees with the decision verdict")

;; --- output snapshots: what cutoff may hash (st-8ig) --------------------------

(check-equal? (map car (output-snapshot g 'xform env)) '(out)
              "a derived, resolvable, existing output is hashed")
(check-equal? (output-snapshot g 'needs-token env) '()
              "an unresolvable output has nothing to hash")
(define g-auth
  (build-graph
   (list (make-task 'xform 'transform #:inputs '(raw) #:outputs '(out)))
   (list (make-artifact 'raw 'file)
         (make-artifact 'out 'file #:provenance 'authoritative))))
(check-equal? (output-snapshot g-auth 'xform env) '()
              "an authoritative output is never cutoff-eligible")

;; the stored entry vs a fresh snapshot of unchanged outputs: the cutoff signal
(check-equal? (compare-outputs (read-cache-entry cache-dir 'xform)
                               (output-snapshot g 'xform env))
              (output-delta 'identical '(out))
              "rebuilt-to-identical reads back through the store as identical")

;; change the input's content -> the changed input is named
(display-to-file "a,b\n9,9\n" raw-path #:exists 'replace)
(check-equal? (task-decision g 'xform env)
              (decision 'run 'input-changed '(raw))
              "a content change to raw is attributed to raw")

;; restore the input, lose the output
(display-to-file "a,b\n1,2\n" raw-path #:exists 'replace)
(delete-file out-path)
(check-equal? (task-decision g 'xform env)
              (decision 'run 'output-missing (list out-path))
              "inputs unchanged but the output is gone")
(display-to-file "db-bytes" out-path)

;; a different recipe against the same stored entry
(check-equal? (task-decision (graph-with-invoke "v2") 'xform env)
              (decision 'run 'recipe-changed '())
              "editing the recipe invalidates the entry")

;; an old-format (v1) entry is a miss, never an error
(call-with-output-file (build-path cache-dir "xform.rktd") #:exists 'replace
  (lambda (o) (write (hash 'version 1 'input-fp "deadbeef" 'outputs '()) o)))
(check-equal? (task-decision g 'xform env)
              (decision 'run 'no-cache-entry '())
              "other-version entry reads as no entry")

;; --- a 'dir output: content-addressed as a whole tree (st-cly) ----------------
;; A task producing a directory artifact caches on the tree digest: present +
;; unchanged -> skip; a file changed anywhere inside -> run; the whole dir gone ->
;; run (output-missing sees the directory, not a file).
(define dir-out (build-path tmp "maps"))
(make-directory dir-out)
(display-to-file "svg-a" (build-path dir-out "a.svg"))
(define (dir-resolve a) (case a [(raw) raw-path] [(maps) dir-out] [else #f]))
(define dir-env (make-build-env (lambda (a _e) (dir-resolve a)) tmp cache-dir))
(define gdir
  (build-graph
   (list (make-task 'ingest 'boundary #:outputs '(raw))
         (make-task 'render 'transform #:inputs '(raw) #:outputs '(maps)
                    #:invoke "v1"))
   (list (make-artifact 'raw 'file) (make-artifact 'maps 'dir))))

(check-equal? (map car (output-snapshot gdir 'render dir-env)) '(maps)
              "a derived, resolvable, existing 'dir output is hashed")

(define snap-dir (input-snapshot gdir 'render dir-resolve))
(cache-store! cache-dir 'render snap-dir (list dir-out)
              (output-snapshot gdir 'render dir-env))
(check-equal? (task-decision gdir 'render dir-env)
              (decision 'skip 'cached '())
              "stored + dir present + inputs unchanged -> cached")

;; add a file inside the directory: the tree digest changes, cutoff would fire
(display-to-file "svg-b" (build-path dir-out "b.svg"))
(check-equal? (compare-outputs (read-cache-entry cache-dir 'render)
                               (output-snapshot gdir 'render dir-env))
              (output-delta 'changed '(maps))
              "a new file inside the dir changes its tree digest")

;; lose the whole directory: output-missing names the dir path, not a file
(delete-directory/files dir-out)
(check-equal? (task-decision gdir 'render dir-env)
              (decision 'run 'output-missing (list dir-out))
              "a 'dir output gone entirely -> run, output-missing")

(delete-directory/files tmp)
