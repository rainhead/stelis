#lang racket/base

;; Per-canonical_name content-addressing of the authoritative notes STORE
;; (st-... H2.2a) — the ingestion-boundary read that turns a CRUD on one note into
;; a KEYED change, the first step of subsuming beeatlas's ADR 0013 notes worker
;; into the general engine.
;;
;; notes.json is Record<canonical_name, Note[]> over status='approved' notes
;; (beeatlas notes_harvest, D-10/D-13); species with zero approved notes are absent
;; as keys. This digests EXACTLY those — approved notes, grouped by canonical_name,
;; hashing only the fields that flow into notes.json (id, author_id, body_html, the
;; two timestamps) — so adding/editing/removing one note moves only its species'
;; key, and unapproving the last note for a species drops the key. The value shape
;; is "<digest>:<count>", the same as relation-digest.rkt's per-column parts, so it
;; rides the existing per-key observation / delta machinery unchanged.
;;
;; Built on the shared read-only DuckDB runner (duckdb.rkt) via its SQLite scanner
;; (ATTACH ... TYPE sqlite, READ_ONLY), reusing relation-digest's order-independent
;; count:sum idiom (sum over per-row hashes is commutative -> row-order-independent).
;; The #f-on-absence contract is duckdb.rkt's: a missing CLI/db or a query error
;; yields #f, which upstream reads as "unresolvable" (a conservative rerun), never
;; a failure.

(require racket/string
         "duckdb.rkt")

(provide notes-store-keys)

;; notes-store-keys : (or/c path-string #f) -> (or/c (listof (cons string string)) #f)
;; The store's per-canonical_name observation: sorted (canonical_name -> "<digest>:
;; <count>") pairs over approved notes, or #f when the store can't be read. '() (not
;; #f) for a readable store with no approved notes — no keys, exactly as notes.json
;; would have none. Order-independent in rows (sum) and in keys (ORDER BY).
(define (notes-store-keys db)
  (and db
       (let ([out (duckdb-query #f (notes-keys-query db))])
         (and out (parse-key-lines out)))))

;; The query runs against an in-memory DuckDB (db #f) that ATTACHes the SQLite
;; store READ_ONLY — the store file is never the DuckDB database itself. The digest
;; hashes a struct of only the note-content fields, so the group key (canonical_name)
;; and the filter column (status) never enter the hash.
(define (notes-keys-query db)
  (string-append
   "ATTACH '" (sql-quote (path-string->string db)) "' AS s (TYPE sqlite, READ_ONLY);\n"
   "SELECT canonical_name || chr(9) ||\n"
   "  coalesce(sum(md5_number_lower(to_json({"
   "'id':id,'author_id':author_id,'html':body_html,"
   "'created':created_at,'updated':updated_at})::VARCHAR))::VARCHAR, '0')\n"
   "  || ':' || count(*)::VARCHAR\n"
   "FROM s.notes WHERE status='approved'\n"
   "GROUP BY canonical_name ORDER BY canonical_name;"))

;; parse-key-lines : string -> (listof (cons string string))
;; Each -list line is "<canonical_name>\t<digest>:<count>"; split on the first TAB
;; (a scientific name never contains one, but may contain spaces/'|'/':', so TAB is
;; the safe delimiter). Blank lines (an empty result) drop out -> '().
(define (parse-key-lines out)
  (for*/list ([line (in-list (string-split out "\n"))]
              [trimmed (in-value (string-trim line #:left? #f))]
              #:unless (string=? "" trimmed)
              [tab (in-value (for/first ([c (in-string trimmed)]
                                         [i (in-naturals)]
                                         #:when (char=? c #\tab)) i))]
              #:when tab)
    (cons (substring trimmed 0 tab) (substring trimmed (add1 tab)))))

;; SQL string-literal escaping: double any single quote (a path is trusted config,
;; but this keeps an apostrophe in a path from breaking the ATTACH).
(define (sql-quote s) (string-replace s "'" "''"))

(define (path-string->string p) (if (path? p) (path->string p) p))
