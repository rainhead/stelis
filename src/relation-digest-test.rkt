#lang racket/base

;; Tests for db-relation content-addressing (st-d5d): the DuckDB digest itself,
;; and its end-to-end effect on the cache decision (unchanged relation -> skip,
;; changed relation -> rerun). Hermetic: each test builds its own tiny .duckdb in
;; a temp dir via the duckdb CLI. If duckdb isn't on PATH the suite no-ops with a
;; note rather than failing (the mechanism is unexercisable without it).

(require rackunit
         racket/system
         racket/port
         racket/file
         racket/string
         "model.rkt"
         "cache.rkt"
         "relation-digest.rkt"
         "written.rkt")

(define duckdb (find-executable-path "duckdb"))

(cond
  [(not duckdb)
   (printf "relation-digest-test: duckdb not on PATH — skipping.\n")]
  [else

   ;; run a setup/DDL statement against `db'; error if the CLI fails.
   (define (ddl! db sql)
     (define-values (sp out in err)
       (subprocess #f #f #f duckdb (path->string db) "-c" sql))
     (close-output-port in)
     (port->string out)
     (define e (port->string err))
     (subprocess-wait sp)
     (unless (eqv? 0 (subprocess-status sp))
       (error 'ddl "duckdb failed: ~a" e)))

   (define tmp (make-temporary-file "stelis-reldigest-~a" 'directory))
   (define db (build-path tmp "t.duckdb"))

   ;; a relation with dlt-style bookkeeping columns and a couple of rows
   (ddl! db (string-append
             "CREATE SCHEMA s;"
             "CREATE TABLE s.r (_dlt_id VARCHAR, _dlt_load_id VARCHAR, k INTEGER, v VARCHAR);"
             "INSERT INTO s.r VALUES ('a','1',1,'x'),('b','1',2,'y'),('c','1',3,'z');"))

   (define d0 (relation-digest db '("s.r")))
   (test-true "digest of a readable relation is a string" (string? d0))

   ;; --- order independence: reinsert the same rows in a different order -------
   (ddl! db "DELETE FROM s.r;")
   (ddl! db "INSERT INTO s.r VALUES ('c','1',3,'z'),('a','1',1,'x'),('b','1',2,'y');")
   (test-equal? "row order does not change the digest"
                (relation-digest db '("s.r")) d0)

   ;; --- dlt bookkeeping is excluded: change only _dlt_* -> same digest --------
   (ddl! db "UPDATE s.r SET _dlt_load_id = '2', _dlt_id = _dlt_id || '!';")
   (test-equal? "dlt bookkeeping columns are excluded from the digest"
                (relation-digest db '("s.r")) d0)

   ;; --- sensitivity: change one real value -> digest changes ------------------
   (ddl! db "UPDATE s.r SET v = 'CHANGED' WHERE k = 2;")
   (define d1 (relation-digest db '("s.r")))
   (test-true "a real value change changes the digest" (not (equal? d1 d0)))

   ;; --- per-column digests (st-7vz): attribute-level refinement --------------
   ;; a fresh table so these are independent of s.r's mutation history above.
   (ddl! db (string-append
             "CREATE TABLE s.c (_dlt_id VARCHAR, k INTEGER, v VARCHAR);"
             "INSERT INTO s.c VALUES ('a',1,'x'),('b',2,'y'),('c',3,NULL);"))
   (define c0 (relation-columns db '("s.c")))
   (test-equal? "per-column parts + a distinguished .* row-count part, sorted, dlt dropped"
                (map car c0) '("s.c.*" "s.c.k" "s.c.v"))
   (test-equal? "the .* part carries count(*) (three rows)"
                (cdr (assoc "s.c.*" c0)) "3")
   (test-equal? "non-null count rides in each column's value (v has one NULL)"
                (cdr (assoc "s.c.v" c0)) (string-append
                                          (car (string-split (cdr (assoc "s.c.v" c0)) ":"))
                                          ":2"))
   (test-equal? "a fully-populated column counts every row"
                (cadr (string-split (cdr (assoc "s.c.k" c0)) ":")) "3")

   ;; order independence: reinsert the same rows in a different order
   (ddl! db "DELETE FROM s.c;")
   (ddl! db "INSERT INTO s.c VALUES ('c',3,NULL),('a',1,'x'),('b',2,'y');")
   (test-equal? "row order does not change per-column digests"
                (relation-columns db '("s.c")) c0)

   ;; sensitivity is LOCAL: changing v leaves k's column digest untouched
   (ddl! db "UPDATE s.c SET v = 'CHANGED' WHERE k = 2;")
   (define c1 (relation-columns db '("s.c")))
   (test-equal? "an untouched column keeps its digest"
                (assoc "s.c.k" c1) (assoc "s.c.k" c0))
   (test-true "the changed column's digest moves"
              (not (equal? (assoc "s.c.v" c1) (assoc "s.c.v" c0))))

   (test-false "an unreadable relation has no per-column digests"
               (relation-columns db '("s.nope")))

   ;; --- unreadable relation -> #f (caller treats as unresolvable) -------------
   (test-false "missing table digests to #f"
               (relation-digest db '("s.nope")))
   (test-false "malformed table name digests to #f"
               (relation-digest db '("not a table")))

   ;; --- end to end: the cache decision skips an unchanged relation ------------
   ;; A one-task graph consuming a db-relation. resolve (files) never matches;
   ;; resolve-relation supplies the DuckDB digest.
   (define g
     (build-graph
      (list (make-task 'xform 'transform #:inputs '(rel) #:outputs '(out)
                       #:invoke 'recipe))
      (list (make-artifact 'rel 'db-relation #:provenance 'upstream)
            (make-artifact 'out 'file))))
   (define cache-dir (build-path tmp "cache"))
   (define out-path (build-path tmp "out"))
   (display-to-file "built" out-path #:exists 'replace)
   (define (resolve a _export) (case a [(out) out-path] [else #f]))
   (define rr (lambda (a) (case a [(rel) (relation-digest db '("s.r"))] [else #f])))
   (define env (make-build-env resolve tmp cache-dir #:resolve-relation rr))

   (define snap (input-snapshot g 'xform (lambda (a) (resolve a tmp)) rr))
   (test-true "a db-relation input yields a snapshot, not unresolvable"
              (snapshot? snap))

   ;; store the current state, then a fresh decision must be a skip
   (cache-store! cache-dir 'xform snap (list out-path) (output-snapshot g 'xform env))
   (define-values (dec _s) (decision+snapshot g 'xform env))
   (test-eq? "unchanged relation -> cache skip" (decision-verdict dec) 'skip)

   ;; mutate the relation; the next decision must be a rerun naming the input
   (ddl! db "UPDATE s.r SET v = 'again' WHERE k = 1;")
   (define-values (dec2 _s2) (decision+snapshot g 'xform env))
   (test-eq? "changed relation -> rerun" (decision-verdict dec2) 'run)
   (test-equal? "rerun reason names the changed relation"
                (decision-reason dec2) 'input-changed)

   ;; --- A SQLite file (sqlite-db), as a task-written mirror is (salishsea decision 061) ---
   ;; Addressed by its rows, not its bytes: the same rows written into a fresh file, in
   ;; another order, digest the same; one changed row digests differently; no file is #f.
   (define (sqlite! file rows)
     (when (file-exists? file) (delete-file file))
     (define mem (build-path tmp "scratch.duckdb"))
     (when (file-exists? mem) (delete-file mem))
     (ddl! mem (string-append
                "ATTACH '" (path->string file) "' AS m (TYPE sqlite);"
                "CREATE TABLE m.bouts (id TEXT PRIMARY KEY, title TEXT, lon REAL);"
                "INSERT INTO m.bouts VALUES " rows ";")))
   (define sq (build-path tmp "mirror.sqlite"))
   (sqlite! sq "('b1', 'J pod', -122.5), ('b2', NULL, -123.25)")
   (define first-digest (relation-digest (sqlite-db sq "orcasound") '("orcasound.bouts")))
   (test-true "a SQLite relation digests" (string? first-digest))
   (sqlite! sq "('b2', NULL, -123.25), ('b1', 'J pod', -122.5)")
   (test-equal? "the same rows in a fresh file, another order: the same digest"
                (relation-digest (sqlite-db sq "orcasound") '("orcasound.bouts")) first-digest)
   (sqlite! sq "('b2', NULL, -123.25), ('b1', 'K pod', -122.5)")
   (test-false "one changed row: a different digest"
               (equal? (relation-digest (sqlite-db sq "orcasound") '("orcasound.bouts")) first-digest))
   (test-equal? "its row count" (relation-row-count (sqlite-db sq "orcasound") '("orcasound.bouts")) 2)
   (test-equal? "its columns, each with a digest, and the row-count part"
                (map car (relation-columns (sqlite-db sq "orcasound") '("orcasound.bouts")))
                '("orcasound.bouts.*" "orcasound.bouts.id" "orcasound.bouts.lon" "orcasound.bouts.title"))
   (test-false "no file: unresolvable, as a missing DuckDB file is"
               (relation-digest (sqlite-db (build-path tmp "absent.sqlite") "orcasound") '("orcasound.bouts")))

   ;; --- The batched observer (st-ml9.6) ----------------------------------------
   ;; The same answers the one-relation functions give — byte for byte, so recorded
   ;; history stays comparable — for every relation of a database at once, held until
   ;; a task writes the relation.
   (ddl! db (string-append
             "CREATE TABLE s.only_dlt (_dlt_id VARCHAR);"
             "INSERT INTO s.only_dlt VALUES ('a');"))
   (define rels
     (hash 'r '("s.r") 'c '("s.c") 'both '("s.r" "s.c") 'gone '("s.c" "s.nope")
           'dlt '("s.only_dlt") 'bad '("not a table")))
   (define-values (obs-digest obs-columns)
     (make-relation-observer (hash-keys rels) (lambda (_) db) (lambda (a) (hash-ref rels a))))
   (for ([(a tables) (in-hash rels)])
     (test-equal? (format "~a: the observer's digest is relation-digest's" a)
                  (obs-digest a) (relation-digest db tables))
     (test-equal? (format "~a: the observer's columns are relation-columns'" a)
                  (obs-columns a) (relation-columns db tables)))
   (define held (obs-digest 'r))
   (ddl! db "UPDATE s.r SET v = 'unseen' WHERE k = 1;")
   (test-equal? "a write no task made isn't seen: the answer is held"
                (obs-digest 'r) held)
   (note-written! '(c))
   (test-equal? "nor does writing another relation release it"
                (obs-digest 'r) held)
   (note-written! '(r))
   (test-equal? "once a task has written the relation, it is observed afresh"
                (obs-digest 'r) (relation-digest db '("s.r")))
   (test-false "and the answer moved" (equal? (obs-digest 'r) held))
   (test-equal? "a multi-table relation over it moves too"
                (obs-digest 'both) (relation-digest db '("s.r" "s.c")))

   (define-values (sq-digest sq-columns)
     (make-relation-observer '(bouts) (lambda (_) (sqlite-db sq "orcasound"))
                             (lambda (_) '("orcasound.bouts"))))
   (test-equal? "a SQLite relation, batched: relation-digest's digest"
                (sq-digest 'bouts) (relation-digest (sqlite-db sq "orcasound") '("orcasound.bouts")))
   (test-equal? "and relation-columns' columns"
                (sq-columns 'bouts) (relation-columns (sqlite-db sq "orcasound") '("orcasound.bouts")))
   (define-values (none-digest _nc)
     (make-relation-observer '(r) (lambda (_) #f) (lambda (_) '("s.r"))))
   (test-false "no database yet: no answer" (none-digest 'r))

   (delete-directory/files tmp)])
