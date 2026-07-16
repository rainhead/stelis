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
         "duckdb.rkt")

(provide relation-digest relation-columns relation-row-count)

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
       (let ([out (duckdb-query db (relation-query tables))])
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
               (define col-out (and (pair? cols) (duckdb-query db (columns-query qualified cols))))
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
  (define out (duckdb-query db (string-append "SELECT count(*) FROM " qualified ";")))
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
  (define sql
    (string-append
     "SELECT column_name FROM information_schema.columns "
     "WHERE table_schema = '" schema "' AND table_name = '" table "' "
     "ORDER BY column_name;"))
  (define out (duckdb-query db sql))
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
