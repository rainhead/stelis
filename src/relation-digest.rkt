#lang racket/base

;; Content-addressing for db-relation inputs (st-d5d).
;;
;; A file input is hashed by reading its bytes (cache.rkt). A db-relation input
;; has no file — it is a schema.table (or a few of them) inside the shared
;; beeatlas.duckdb. This module gives such a relation a content hash by asking
;; DuckDB for an order-independent digest of its rows, so input-addressing — and
;; therefore early cutoff (st-8ig) — reaches the pre-dbt graph, not just the file
;; edges around dbt-build.
;;
;; The digest is READ-ONLY metadata, not a transformation: it reads what a loader
;; already wrote and never changes it (Horizon 0 keeps transformations external).
;; It runs between tasks, when no loader/dbt holds the db's write lock.
;;
;; Shape (see st-d5d design):
;;   * per row: md5_number_lower(to_json(row)) — a 64-bit hash of the row's JSON
;;   * combined by sum(), which is order-INDEPENDENT (a+b = b+a): the digest is
;;     the same no matter what order DuckDB's (possibly parallel) scan returns
;;     rows in. sum treats the table as a MULTISET, so duplicate rows each count
;;     (bit_xor would cancel identical rows — wrong for ingested data).
;;   * dlt bookkeeping columns (_dlt_id, _dlt_load_id, ...) are EXCLUDED, so a
;;     re-ingest of identical logical content hashes identically and cutoff can
;;     fire. Exclusion is by prefix at query time (not a static EXCLUDE list,
;;     which hard-errors on a relation that happens to carry no _dlt columns).
;;   * a relation spanning several tables combines their per-table digests in
;;     sorted order — order-independent across the table set too.
;;
;; This is the row-coherent digest the cache decision consumes. Per-column
;; digests (the substrate for future attribute-level provenance) are a separate
;; slice; the single-table query is shaped so they can be added there.

(require racket/string
         racket/list
         file/sha1
         "duckdb.rkt"
         "written.rkt")

(provide relation-digest relation-columns relation-row-count
         make-relation-observer
         (struct-out sqlite-db))

;; A relation's database: a DuckDB file (a path, as always), or a SQLite file (sqlite-db),
;; attached read-only under `alias' so its tables are named "<alias>.<table>" exactly as a
;; DuckDB file's "<schema>.<table>" are. A SQLite file's bytes move when its rows don't
;; (page layout, free lists), so a mirror written by a task is addressed by its rows, the
;; same row-coherent digest as any relation, never by the file (salishsea decision 061:
;; each upstream source's mirror is a SQLite file a boundary task writes, st-ml9.3).
(struct sqlite-db (path alias) #:transparent)

;; query-db : (or/c path-string sqlite-db) string -> (or/c string #f)
;; duckdb-query over either kind of database: a SQLite file is attached into a transient
;; in-memory DuckDB first. A missing file is #f, as a missing DuckDB file already is.
(define (query-db db sql)
  (cond
    [(sqlite-db? db)
     (define file (sqlite-db-path db))
     (and (file-exists? file)
          (regexp-match? sql-identifier? (sqlite-db-alias db))
          (duckdb-query #f (string-append
                            "ATTACH '" (string-replace (if (path? file) (path->string file) file) "'" "''")
                            "' AS " (sqlite-db-alias db) " (TYPE sqlite, READ_ONLY);\n" sql)))]
    [else (duckdb-query db sql)]))

;; A qualified table name we are willing to interpolate into SQL (duckdb.rkt's
;; shared gate): the mapping in beeatlas.rkt is trusted, but a strict shape makes a
;; typo fail loudly rather than produce odd SQL.
(define qualified-name? sql-qualified-name?)

;; table-digest-subquery : string -> string
;; A scalar subquery yielding "<rows>:<sum-of-row-hashes>", stable ('0:0') for an
;; empty table (sum over no rows is NULL). starts_with(col,'_dlt_') drops dlt's
;; per-load bookkeeping. The inner SELECT projects the kept columns; to_json(x)
;; serialises each surviving row as one JSON string to hash.
(define (table-digest-subquery qualified)
  (string-append
   "(SELECT count(*)::VARCHAR || ':' || "
   "coalesce(sum(md5_number_lower(to_json(x)::VARCHAR))::VARCHAR, '0') "
   "FROM (SELECT COLUMNS(lambda c: NOT starts_with(c, '_dlt_')) FROM "
   qualified ") x)"))

;; relation-query : (listof string) -> string
;; The whole relation as one query: one "<table>=<digest>" row per table, sorted,
;; so the CLI output is already canonical and we can hash it directly.
(define (relation-query tables)
  (string-append
   "SELECT tbl || '=' || d FROM (\n"
   (string-join
    (for/list ([t (in-list tables)])
      (string-append "  SELECT '" t "' AS tbl, " (table-digest-subquery t) " AS d"))
    "\n  UNION ALL\n")
   "\n) ORDER BY tbl;"))

;; relation-digest : path-string (listof string) -> (or/c string #f)
;; The content hash of the logical relation made of `tables', or #f if it can't
;; be read (duckdb.rkt's #f-on-absence contract). Order-independent in rows (sum)
;; and in tables (ORDER BY tbl).
(define (relation-digest db tables)
  (and (pair? tables)
       (andmap (lambda (t) (regexp-match? qualified-name? t)) tables)
       (let ([out (query-db db (relation-query tables))])
         (and out (sha1 (open-input-string out))))))

;; --- Per-column digests (st-7vz) ----------------------------------------------
;; The ATTRIBUTE-level refinement of relation-digest: each column's own
;; order-independent multiset digest plus its non-null count. Recorded as an
;; observation for downstream provenance queries ("which COLUMN changed?"); it is
;; NOT the skip signal — per-column multiset digests alone false-skip on a
;; cross-row value swap (two rows exchange a value: every column's multiset is
;; unchanged, yet the relation changed). The row-coherent `relation-digest' stays
;; the identity, exactly as st-d5d proved; this rides alongside it.
;;
;; A SEPARATE query from relation-digest — deliberately, so the proven combined
;; digest is never perturbed. Column enumeration comes from information_schema;
;; each column's value is the "<table>.<col>" part key, its content "<digest>:<count>"
;; so a change to EITHER the values or the null-count shows as a changed part.

;; relation-columns : path-string (listof string)
;;   -> (or/c (listof (cons string string)) #f)
;; Sorted ("<schema>.<table>.<column>" -> "<digest>:<count>") pairs across all
;; `tables', or #f if the relation can't be read. Order-independent (sum per
;; column, sorted part keys). Each table also contributes a distinguished
;; "<schema>.<table>.*" part whose value is its row COUNT — the metric the
;; integrity gate (st-0vz) reads across builds. "*" is not a legal column name,
;; so the row-count part never collides with a real column.
(define (relation-columns db tables)
  (and (pair? tables)
       (andmap (lambda (t) (regexp-match? qualified-name? t)) tables)
       (let loop ([ts tables] [acc '()])
         (cond
           [(null? ts) (sort acc string<? #:key car)]
           [else
            (define qualified (car ts))
            (define cols (table-columns db qualified))
            (define rows (and cols (table-rowcount db qualified)))
            (cond
              [(not cols) #f]   ; a table we couldn't read -> whole relation #f
              [(not rows) #f]   ; count(*) failed -> treat as unreadable
              [else
               (define col-out (and (pair? cols) (query-db db (columns-query qualified cols))))
               (cond
                 [(and (pair? cols) (not col-out)) #f]  ; columns unreadable
                 [else
                  (define rowpart (cons (string-append qualified ".*") rows))
                  (define colparts (if col-out (parse-column-lines col-out) '()))
                  (loop (cdr ts) (cons rowpart (append colparts acc)))])])]))))

;; table-rowcount : path-string string -> (or/c string #f)
;; A table's count(*) as a decimal string, or #f if unreadable — the integrity
;; gate's baseline metric, recorded per build alongside the per-column digests.
(define (table-rowcount db qualified)
  (define out (query-db db (string-append "SELECT count(*) FROM " qualified ";")))
  (and out (let ([s (string-trim out)])
             (and (regexp-match? #px"^[0-9]+$" s) s))))

;; relation-row-count : path-string (listof string) -> (or/c exact-nonnegative-integer #f)
;; The relation's total record count NOW (sum of count(*) over its tables), or #f
;; if any table can't be read. The integrity gate's live "current" reading, the
;; twin of the ".*" parts recorded in history — both built on table-rowcount, so
;; current and baseline are the same measurement.
(define (relation-row-count db tables)
  (and (pair? tables)
       (andmap (lambda (t) (regexp-match? qualified-name? t)) tables)
       (let ([counts (map (lambda (t) (table-rowcount db t)) tables)])
         (and (andmap values counts)
              (apply + (map string->number counts))))))

;; table-columns : path-string string -> (or/c (listof string) #f)
;; A table's provenance-eligible column names (non-dlt, safe to interpolate as a
;; bare identifier), sorted; #f when the table can't be read. information_schema
;; doesn't error on a missing table (unlike the digest query), so absence shows as
;; an EMPTY raw column list — and a real table always has ≥1 column, so empty ⇒
;; absent ⇒ #f, preserving relation-digest's #f-on-absence contract. Odd-named
;; columns (not a bare identifier) are dropped from the refinement — metadata, not
;; the correctness digest, so a rare exotic name costs a column here, never a build.
(define (table-columns db qualified)
  (define parts (string-split qualified "."))
  (define schema (car parts))
  (define table (cadr parts))
  ;; An attached SQLite file is a catalog whose tables sit in its `main' schema.
  (define where
    (if (sqlite-db? db)
        (string-append "table_catalog = '" schema "' AND table_schema = 'main'")
        (string-append "table_schema = '" schema "'")))
  (define sql
    (string-append
     "SELECT column_name FROM information_schema.columns "
     "WHERE " where " AND table_name = '" table "' "
     "ORDER BY column_name;"))
  (define out (query-db db sql))
  (and out
       (let ([all (map string-trim
                       (filter non-empty-string? (string-split out "\n")))])
         (and (pair? all)   ; empty ⇒ no such table ⇒ #f
              (filter (lambda (c) (and (not (string-prefix? c "_dlt_"))
                                       (regexp-match? sql-identifier? c)))
                      all)))))

;; columns-query : string (listof string) -> string
;; One "<table>.<col>=<digest>:<count>" row per column. Per column: the
;; order-independent sum of md5 row hashes (coalesced to '0' for an all-null
;; column) and count() (non-null count). Column names are pre-gated identifiers.
(define (columns-query qualified cols)
  (string-append
   "SELECT c || '=' || d || ':' || n FROM (\n"
   (string-join
    (for/list ([col (in-list cols)])
      (string-append
       "  SELECT '" qualified "." col "' AS c, "
       "coalesce(sum(md5_number_lower(to_json(" col ")::VARCHAR))::VARCHAR, '0') AS d, "
       "count(" col ")::VARCHAR AS n FROM " qualified))
    "\n  UNION ALL\n")
   "\n) ORDER BY c;"))

;; parse-column-lines : string -> (listof (cons string string))
;; "<part>=<digest>:<count>" lines -> (part . "<digest>:<count>") pairs. Split on
;; the FIRST '=' only (part keys are dotted identifiers, never contain '=').
(define (parse-column-lines out)
  (for/list ([line (in-list (string-split out "\n"))]
             #:when (non-empty-string? (string-trim line)))
    (define i (for/first ([ch (in-string line)] [k (in-naturals)] #:when (char=? ch #\=)) k))
    (cons (substring line 0 i) (substring line (add1 i)))))

;; --- Batched observation (st-ml9.6) -------------------------------------------
;; relation-digest and relation-columns cost a CLI launch per query, several per
;; table (the digest, the column list, the row count, the column digests), and each
;; launch opens the database file: on salishsea's Fly machine that was ~35 s of a
;; 68 s build that changed nothing, ~40 tables in a 330 MB snapshot. The observer
;; below answers the same two questions for every relation of one database in TWO
;; launches — the column lists, then every digest at once — and remembers the
;; answers until a task writes the relation (written.rkt).
;;
;; The values are the same strings the one-relation functions compute, assembled
;; from per-table pieces in the order those functions' SQL sorts them, so a
;; recorded history stays comparable across the change (pinned in
;; relation-digest-test). Anything the batch can't answer — a launch that fails, a
;; database not there yet — falls back to the one-relation functions, so the
;; observer never knows less than they did.

;; One table's observation: its digest "<rows>:<sum>", its row count, and its
;; per-column parts ("<table>.<column>" . "<digest>:<count>"), or 'absent.
(struct table-obs (digest rows columns))

;; batch-columns-query : db (listof string) -> string
;; "<table>|<column>" for every column of every table, in table-columns' order.
(define (batch-columns-query db tables)
  (define qualified
    (if (sqlite-db? db)
        "table_catalog || '.' || table_name"
        "table_schema || '.' || table_name"))
  (string-append
   "SELECT " qualified ", column_name FROM information_schema.columns WHERE "
   (if (sqlite-db? db) "table_schema = 'main' AND " "")
   qualified " IN ("
   (string-join (for/list ([t (in-list tables)]) (string-append "'" t "'")) ", ")
   ") ORDER BY 1, column_name;"))

;; batch-values-query : (listof (cons string (listof string))) -> string
;; "D|<table>|<rows>:<sum>" per table, "N|<table>|<count>" per table, and
;; "C|<table>.<column>|<digest>:<count>" per column: the expressions of
;; table-digest-subquery, table-rowcount and columns-query, unchanged.
;;
;; Capped, as salishsea's scripts are, for a 1 GB machine with Racket resident
;; beside it: uncapped, DuckDB scans the whole database with every core and keeps
;; what it read, 417 MB at peak over salishsea's 330 MB snapshot; at 128 MB and one
;; thread, 206 MB and 2.5 s. The aggregates are sums and counts, so the cap only
;; bounds the cache. Neither setting changes a value.
(define (batch-values-query table-cols)
  (string-append
   "SET memory_limit = '128MB'; SET threads = 1;\n"
   (string-join
    (append*
     (for/list ([tc (in-list table-cols)])
       (define t (car tc))
       (append
        (list (string-append "SELECT 'D|" t "|' || " (table-digest-subquery t))
              (string-append "SELECT 'N|" t "|' || count(*)::VARCHAR FROM " t))
        (for/list ([col (in-list (cdr tc))])
          (string-append
           "SELECT 'C|" t "." col "|' || "
           "coalesce(sum(md5_number_lower(to_json(" col ")::VARCHAR))::VARCHAR, '0') || ':' || "
           "count(" col ")::VARCHAR FROM " t)))))
    "\nUNION ALL\n")
   ";"))

;; observe-tables : db (listof string) -> (or/c (hash string -> (or/c table-obs 'absent)) #f)
;; Every table's observation in two launches, or #f when either launch fails.
(define (observe-tables db tables)
  (define col-out (query-db db (batch-columns-query db tables)))
  (and col-out
       (let* ([cols-of
               (for/fold ([h (hash)]) ([line (in-list (string-split col-out "\n"))]
                                       #:when (non-empty-string? (string-trim line)))
                 (define parts (string-split line "|"))
                 (hash-update h (car parts) (lambda (cs) (cons (cadr parts) cs)) '()))]
              ;; table-columns' filter, over its order (the CLI's ORDER BY column_name)
              [present
               (for/list ([t (in-list tables)] #:when (hash-has-key? cols-of t))
                 (cons t (filter (lambda (c) (and (not (string-prefix? c "_dlt_"))
                                                  (regexp-match? sql-identifier? c)))
                                 (reverse (hash-ref cols-of t)))))]
              [val-out (if (null? present) "" (query-db db (batch-values-query present)))])
         (and val-out
              (let ([values-of
                     (for/hash ([line (in-list (string-split val-out "\n"))]
                                #:when (non-empty-string? (string-trim line)))
                       (define l (string-split line "|"))
                       (values (cons (car l) (cadr l)) (caddr l)))])
                (define (value kind key) (hash-ref values-of (cons kind key) #f))
                (define result
                  (for/hash ([t (in-list tables)])
                    (define cols (assoc t present))
                    (values
                     t
                     (if cols
                         (table-obs (value "D" t)
                                    (value "N" t)
                                    (for/list ([c (in-list (cdr cols))])
                                      (define part (string-append t "." c))
                                      (cons part (value "C" part))))
                         'absent))))
                ;; every value the query should have printed, or no answer at all
                (and (for/and ([o (in-hash-values result)])
                       (or (eq? o 'absent)
                           (and (table-obs-digest o) (table-obs-rows o)
                                (andmap cdr (table-obs-columns o)))))
                     result))))))

;; obs->digest : (listof string) (listof table-obs) -> string
;; relation-digest's value: the sha1 of relation-query's CLI output, one
;; "<table>=<digest>" line per table, sorted by table.
(define (obs->digest tables obs)
  (sha1 (open-input-string
         (apply string-append
                (for/list ([to (in-list (sort (map cons tables obs) string<? #:key car))])
                  (string-append (car to) "=" (table-obs-digest (cdr to)) "\n"))))))

;; obs->columns : (listof string) (listof table-obs) -> (listof (cons string string))
;; relation-columns' value: each table's row-count part and column parts, sorted.
(define (obs->columns tables obs)
  (sort (append*
         (for/list ([t (in-list tables)] [o (in-list obs)])
           (cons (cons (string-append t ".*") (table-obs-rows o)) (table-obs-columns o))))
        string<? #:key car))

;; make-relation-observer :
;;   (listof symbol) (symbol -> (or/c db #f)) (symbol -> (or/c (listof string) #f))
;;   -> (values (symbol -> (or/c string #f))
;;              (symbol -> (or/c (listof (cons string string)) #f)))
;; A project's two relation resolvers (resolve-relation, resolve-relation-columns)
;; over the db-relation artifacts `relations', which `db-of' places in a database
;; and `tables-of' maps to tables. Asked about one relation, it observes every
;; relation of that database whose answer it doesn't hold, in one batch, and holds
;; each answer until a task writes that relation, or any relation sharing a table
;; with it: a write is to tables, and the task declares only its own artifact.
(define (make-relation-observer relations db-of tables-of)
  ;; artifact -> (vector generation digest columns)
  (define memo (make-hasheq))
  ;; artifact -> the relations sharing a table with it, itself included
  (define overlaps (make-hasheq))
  (define (overlapping a)
    (hash-ref! overlaps a
               (lambda ()
                 (define mine (or (tables-of a) '()))
                 (cons a (for/list ([r (in-list relations)]
                                    #:when (and (not (eq? r a))
                                                (for/or ([t (in-list (or (tables-of r) '()))])
                                                  (member t mine))))
                           r)))))
  (define (generation a)
    (for/sum ([r (in-list (overlapping a))]) (write-generation r)))
  (define (current? a)
    (define m (hash-ref memo a #f))
    (and m (= (vector-ref m 0) (generation a))))
  (define (fill! a)
    (define db (db-of a))
    (when db
      (define wanted
        (for/list ([r (in-list relations)]
                   #:when (and (not (current? r)) (equal? (db-of r) db) (tables-of r)))
          r))
      (define gens (for/list ([r (in-list wanted)]) (generation r)))
      (define all-tables (remove-duplicates (append* (map tables-of wanted))))
      (define ok-tables (filter (lambda (t) (regexp-match? qualified-name? t)) all-tables))
      (define batch (and (pair? ok-tables) (observe-tables db ok-tables)))
      (for ([r (in-list wanted)] [g (in-list gens)])
        (define tables (tables-of r))
        (define obs (and batch (pair? tables)
                         (for/list ([t (in-list tables)]) (hash-ref batch t #f))))
        (cond
          [(and obs (andmap table-obs? obs))
           (hash-set! memo r (vector g (obs->digest tables obs) (obs->columns tables obs)))]
          [(and obs (andmap values obs))
           ;; a table isn't there: what the one-relation functions answer then
           (hash-set! memo r (vector g #f #f))]
          [else
           (hash-set! memo r (vector g (relation-digest db tables) (relation-columns db tables)))]))))
  (define (lookup a i)
    (unless (current? a) (fill! a))
    (define m (hash-ref memo a #f))
    (and m (current? a) (vector-ref m i)))
  (values (lambda (a) (lookup a 1))
          (lambda (a) (lookup a 2))))
