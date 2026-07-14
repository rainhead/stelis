#lang racket/base

;; A read-only DuckDB CLI query runner, shared by the between-tasks readers that
;; content-address already-written state: relation-digest.rkt (db-relation digests)
;; and fan-out-key.rkt (distinct-column key sets from parquet, st-5jt).
;;
;; The CLI is taken from ambient PATH, not a hermetic runtime like the uv/uvx task
;; runtimes: these are between-tasks READS of state a task already wrote (no task's
;; hermeticity depends on them), and the #f-on-absence contract keeps a missing CLI
;; (or db, or unreadable input) from ever failing a build — the caller degrades to
;; "unresolvable", which only forces a conservative rerun. If total hermeticity is
;; later wanted, pin duckdb as a runtime.

(require racket/port
         racket/system)

(provide duckdb-query sql-identifier? sql-qualified-name?)

;; Shapes a name must match before we interpolate it into SQL. The names come from
;; hand-authored, trusted mappings (no external input), but gating on a strict shape
;; makes a typo fail loudly rather than produce odd SQL. A bare column identifier,
;; and a schema.table qualified name.
(define sql-identifier? #px"^[A-Za-z_][A-Za-z0-9_]*$")
(define sql-qualified-name? #px"^[A-Za-z_][A-Za-z0-9_]*\\.[A-Za-z_][A-Za-z0-9_]*$")

;; duckdb-query : (or/c path-string #f) string -> (or/c string #f)
;; Run `sql' read-only and return the CLI's -noheader -list output (rows on
;; newlines, columns separated by '|'), or #f when duckdb is absent, the db is
;; missing/locked, or the query errors. db #f = a transient in-memory database, for
;; querying read_parquet()/read_json() over files directly (no db to open).
(define (duckdb-query db sql)
  (define exe (find-executable-path "duckdb"))
  (and exe
       (with-handlers ([exn:fail? (lambda (_) #f)])
         (define args
           (append (list "-noheader" "-list")
                   ;; a real db opens read-only; in-memory (#f) takes no db arg and
                   ;; no -readonly (there is no persistent file to protect).
                   (if db (list "-readonly" (if (path? db) (path->string db) db)) '())
                   (list "-c" sql)))
         (define-values (sp out in err) (apply subprocess #f #f #f exe args))
         (close-output-port in)
         (define text (port->string out))
         (port->string err) ; drain so the child can't block on a full stderr pipe
         (subprocess-wait sp)
         (and (eqv? 0 (subprocess-status sp)) text))))
