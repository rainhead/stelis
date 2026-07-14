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
         file/sha1
         "duckdb.rkt")

(provide relation-digest)

;; A qualified table name we are willing to interpolate into SQL. The mapping in
;; beeatlas.rkt is trusted (hand-authored, no external input), but we still gate
;; on a strict shape so a typo fails loudly rather than producing odd SQL.
(define qualified-name? #px"^[A-Za-z_][A-Za-z0-9_]*\\.[A-Za-z_][A-Za-z0-9_]*$")

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
