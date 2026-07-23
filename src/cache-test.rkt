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
;; task code (st-top): a changed script file is its own reason, 'code-changed,
;; with the file named; an entry from before the code layer reads as empty.
(check-equal? (decide (snapshot "r1" (hash 'x "hx" 'y "hy") (hash "s.py" "c2"))
                      (entry) '())
              (decision 'run 'code-changed '("s.py"))
              "a changed code file is named")
(check-equal? (reason (decide (snapshot "r1" (hash 'x "OLD" 'y "hy") (hash "s.py" "c2"))
                              (entry) '()))
              'code-changed
              "a code change outranks a data-input change as the reason")
(check-equal? (decide (snapshot "r9" (hash 'x "hx" 'y "hy") (hash "s.py" "c2"))
                      (entry) '())
              (decision 'run 'code-changed '("s.py"))
              "command + code changed together: the file is still named")
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

;; --- task code in the input address (st-top) ----------------------------------
;; A recipe's named script is hashed like an input: store, edit the script ->
;; rerun with the file named; delete it -> conservative (not addressable, named).
(define script-path (build-path tmp "script.py"))
(define script-str (path->string script-path))
(display-to-file "print('v1')" script-path)
(define gc
  (build-graph
   (list (make-task 'codegen 'transform #:inputs '(raw) #:outputs '(out)
                    #:invoke (recipe 'uv '("-c" "run()") (list script-str))))
   (list (make-artifact 'raw 'file) (make-artifact 'out 'file))))
(define snap-c (input-snapshot gc 'codegen resolve))
(check-pred snapshot? snap-c "a present script file resolves like any input")
(cache-store! cache-dir 'codegen snap-c (list out-path)
              (output-snapshot gc 'codegen env))
(check-equal? (task-decision gc 'codegen env)
              (decision 'skip 'cached '())
              "unchanged code + unchanged inputs -> cached")
(display-to-file "print('v2')" script-path #:exists 'replace)
(check-equal? (task-decision gc 'codegen env)
              (decision 'run 'code-changed (list script-str))
              "editing the script invalidates the cache, the file named (st-top)")
(delete-file script-path)
(check-equal? (task-decision gc 'codegen env)
              (decision 'run 'inputs-unresolvable (list script-str))
              "a missing script is conservative: not addressable, named")
(display-to-file "print('v2')" script-path)

;; a DIRECTORY code entry (st-0ql: dbt's models/) expands per-file, so the
;; decision names the exact file inside — edited, added, or removed.
(define code-dir (build-path tmp "models"))
(make-directory code-dir)
(display-to-file "select 1" (build-path code-dir "a.sql"))
(display-to-file "select 2" (build-path code-dir "b.sql"))
(define (dirfile name) (path->string (build-path code-dir name)))
(define gdc
  (build-graph
   (list (make-task 'dbtish 'transform #:inputs '(raw) #:outputs '(out)
                    #:invoke (recipe 'dbt '("build")
                                     (list (path->string code-dir)))))
   (list (make-artifact 'raw 'file) (make-artifact 'out 'file))))
(define snap-d (input-snapshot gdc 'dbtish resolve))
(check-pred snapshot? snap-d "a directory code entry resolves")
(check-equal? (sort (hash-keys (snapshot-code-hashes snap-d)) string<?)
              (list (dirfile "a.sql") (dirfile "b.sql"))
              "the directory expands to one entry per file inside")
(cache-store! cache-dir 'dbtish snap-d (list out-path)
              (output-snapshot gdc 'dbtish env))
(check-equal? (task-decision gdc 'dbtish env)
              (decision 'skip 'cached '())
              "unchanged tree -> cached")
(display-to-file "select 22" (build-path code-dir "b.sql") #:exists 'replace)
(check-equal? (task-decision gdc 'dbtish env)
              (decision 'run 'code-changed (list (dirfile "b.sql")))
              "an edited file inside the tree is named exactly")
(display-to-file "select 22" (build-path code-dir "b.sql") #:exists 'replace)
(display-to-file "select 3" (build-path code-dir "c.sql"))
(check-equal? (decision-details (task-decision gdc 'dbtish env))
              (list (dirfile "b.sql") (dirfile "c.sql"))
              "an added file surfaces as a key change, named alongside")
(delete-directory/files code-dir)
(check-equal? (task-decision gdc 'dbtish env)
              (decision 'run 'inputs-unresolvable (list (path->string code-dir)))
              "a missing code directory is conservative, named as the dir")

;; runtime identity (st-top): with a runtimes map on the env, the recipe hash
;; covers the RESOLVED argv, so a launch/pin change invalidates — with '()
;; details (the command moved, not the code).
(define (env-with rts)
  (make-build-env (lambda (a _d) (resolve a)) tmp cache-dir #:runtimes rts))
(define rts-314 (hash 'uv (runtime 'uv '("uv" "run" "python3.14") "uv/3.14")))
(define rts-315 (hash 'uv (runtime 'uv '("uv" "run" "python3.15") "uv/3.15")))
(define-values (dec-rt snap-rt) (decision+snapshot gc 'codegen (env-with rts-314)))
(cache-store! cache-dir 'codegen snap-rt (list out-path)
              (output-snapshot gc 'codegen (env-with rts-314)))
(check-equal? (task-decision gc 'codegen (env-with rts-314))
              (decision 'skip 'cached '())
              "same runtimes -> still a hit")
(check-equal? (task-decision gc 'codegen (env-with rts-315))
              (decision 'run 'recipe-changed '())
              "a runtime pin change invalidates like an args change")

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

;; --- a keyed 'file store input: addressed by key digests, NOT bytes (st-2k9) --
;; The WAL regression (found live, 2026-07-17): a long-running writer keeps the
;; SQLite store's committed rows in the -wal, so the main db file's bytes freeze
;; at the last checkpoint. If the decision hashed bytes, a committed note would
;; read "inputs unchanged" forever while the per-key observation layer saw the
;; change — the two layers must read the same boundary (like 'dir: tree-digest is
;; the roll-up of tree-hashes).
(define store-path (build-path tmp "store.db"))
(define store-out  (build-path tmp "notes.json"))
(display-to-file "frozen-main-file-bytes" store-path)
(display-to-file "{}" store-out)
(define store-keys (box '(("apis mellifera" . "d1:1"))))
(define (store-resolve a)
  (case a [(store) store-path] [(notes-out) store-out] [else #f]))
(define store-env
  (make-build-env (lambda (a _e) (store-resolve a)) tmp cache-dir
                  #:resolve-store-keys
                  (lambda (a) (and (eq? a 'store) (unbox store-keys)))))
(define gstore
  (build-graph
   (list (make-task 'harvest 'transform #:inputs '(store) #:outputs '(notes-out)
                    #:invoke "v1"))
   (list (make-artifact 'store 'file #:provenance 'authoritative)
         (make-artifact 'notes-out 'file))))

(define-values (dec-s0 snap-s0) (decision+snapshot gstore 'harvest store-env))
(cache-store! cache-dir 'harvest snap-s0 (list store-out)
              (output-snapshot gstore 'harvest store-env))
(check-equal? (task-decision gstore 'harvest store-env)
              (decision 'skip 'cached '())
              "keyed store stored + unchanged -> cached")

;; the WAL shape: file bytes untouched, a committed write adds a key
(set-box! store-keys '(("apis mellifera" . "d1:1") ("bombus fervidus" . "d9:1")))
(check-equal? (task-decision gstore 'harvest store-env)
              (decision 'run 'input-changed '(store))
              "a key change with frozen file bytes IS an input change (the WAL bug)")

;; converse: bytes churn (e.g. a checkpoint rewrites the file) with keys constant
(define-values (dec-s1 snap-s1) (decision+snapshot gstore 'harvest store-env))
(cache-store! cache-dir 'harvest snap-s1 (list store-out)
              (output-snapshot gstore 'harvest store-env))
(display-to-file "checkpoint-rewrote-these-bytes" store-path #:exists 'replace)
(check-equal? (task-decision gstore 'harvest store-env)
              (decision 'skip 'cached '())
              "byte churn with unchanged keys does NOT dirty the harvest")

;; a plain file (resolve-store-keys returns #f for it) still hashes by bytes:
;; xform's raw input has no key layer, and byte edits keep being attributed (the
;; earlier sections above already pin that behavior under a #f slot; this pins it
;; under a PRESENT slot that just doesn't know the artifact)
(define plain-env
  (make-build-env (lambda (a _e) (resolve a)) tmp cache-dir
                  #:resolve-store-keys (lambda (_a) #f)))
(define-values (dec-p0 snap-p0) (decision+snapshot g 'xform plain-env))
(cache-store! cache-dir 'xform snap-p0 (list out-path)
              (output-snapshot g 'xform plain-env))
(display-to-file "a,b\n5,5\n" raw-path #:exists 'replace)
(check-equal? (task-decision g 'xform plain-env)
              (decision 'run 'input-changed '(raw))
              "a plain file under a present-but-#f key slot hashes by bytes")

(delete-directory/files tmp)
