#lang racket/base

;; Tests for notes-store per-canonical_name content-addressing (st-... H2.2a). The
;; properties that matter: keys are the APPROVED-note species only (removed/pending
;; excluded, matching the harvest keyset); the digest is order-independent and stable; a
;; single-note edit moves ONLY its species' key; adding a note under a new species
;; adds a key; unapproving a species' last note drops the key. Hermetic — builds a
;; tiny SQLite store with the sqlite3 CLI and reads it with duckdb; if either CLI is
;; absent the suite no-ops (same gate as relation-digest-test).

(require rackunit
         racket/file
         racket/system
         racket/port
         "notes-digest.rkt")

(define sqlite3 (find-executable-path "sqlite3"))
(define duckdb  (find-executable-path "duckdb"))

(cond
  [(not (and sqlite3 duckdb))
   (printf "notes-digest-test: ~a not on PATH — skipping.\n"
           (if sqlite3 "duckdb" "sqlite3"))]
  [else
   (define tmp (make-temporary-file "stelis-notes-~a" 'directory))
   (define db (build-path tmp "notes.db"))

   ;; run one SQL statement-batch against the store via the sqlite3 CLI.
   (define (sql! stmt)
     (define-values (sp out in err)
       (subprocess #f #f #f sqlite3 (path->string db) stmt))
     (close-output-port in)
     (port->string out)   ; drain so the child can't block on a full pipe
     (port->string err)
     (subprocess-wait sp)
     (unless (eqv? 0 (subprocess-status sp))
       (error 'sql "sqlite3 failed for: ~a" stmt)))

   ;; a minimal shape of beeatlas notes_store/models.py — notes + the users it
   ;; INNER-JOINs (notes-store-keys mirrors notes_harvest's join, st-pd1).
   (sql! (string-append
          "CREATE TABLE users (id INTEGER PRIMARY KEY, inat_login VARCHAR NOT NULL);"
          "INSERT INTO users (id, inat_login) VALUES (100,'alice'),(101,'bob');"
          "CREATE TABLE notes (id INTEGER PRIMARY KEY, canonical_name VARCHAR NOT NULL,"
          " author_id INTEGER NOT NULL, body TEXT NOT NULL, body_html TEXT NOT NULL,"
          " status VARCHAR NOT NULL DEFAULT 'approved',"
          " created_at DATETIME NOT NULL, updated_at DATETIME NOT NULL);"))
   (define (add id species author html status ts)
     (sql! (format (string-append
                    "INSERT INTO notes (id,canonical_name,author_id,body,body_html,status,created_at,updated_at)"
                    " VALUES (~a,'~a',~a,'b','~a','~a','~a','~a');")
                   id species author html status ts ts)))
   (add 1 "apis mellifera"      100 "<p>one</p>"   "approved" "2026-07-01 00:00:00")
   (add 2 "apis mellifera"      101 "<p>two</p>"   "approved" "2026-07-02 00:00:00")
   (add 3 "osmia lignaria"      100 "<p>three</p>" "approved" "2026-07-03 00:00:00")
   (add 4 "bombus vosnesenskii" 100 "<p>four</p>"  "removed"  "2026-07-04 00:00:00")
   ;; author 404 has NO users row: notes_harvest INNER-JOINs users, so this note —
   ;; and a species with only such notes — is excluded; the digest must match.
   (add 6 "andrena orphan"      404 "<p>orphan</p>" "approved" "2026-07-06 00:00:00")

   (define (keys) (notes-store-keys db))
   (define (val k ks) (cond [(assoc k ks) => cdr] [else #f]))

   ;; approved species only; a removed-only species is absent (matches the harvest)
   (define k0 (keys))
   (check-equal? (map car k0) '("apis mellifera" "osmia lignaria")
                 "keys are the approved-note species, sorted; removed-only absent")
   (check-false (assoc "andrena orphan" k0)
                "a species whose only note has an orphan author_id is absent (INNER JOIN users)")
   (check-regexp-match #px"^[0-9]+:2$" (val "apis mellifera" k0)
                       "apis mellifera: <digest>:<count>, count 2")
   (check-regexp-match #px"^[0-9]+:1$" (val "osmia lignaria" k0) "osmia: count 1")

   ;; determinism: same store digests identically
   (check-equal? (keys) k0 "re-reading the same store gives identical keys")

   ;; a single-note edit moves ONLY that species' key
   (sql! "UPDATE notes SET body_html='<p>edited</p>', updated_at='2026-07-09 00:00:00' WHERE id=3;")
   (define k1 (keys))
   (check-equal? (val "apis mellifera" k1) (val "apis mellifera" k0)
                 "an edit to osmia's note leaves apis untouched")
   (check-not-equal? (val "osmia lignaria" k1) (val "osmia lignaria" k0)
                     "...and moves osmia's key")

   ;; adding a note under a NEW species adds a key
   (add 5 "megachile perihirta" 100 "<p>new</p>" "approved" "2026-07-10 00:00:00")
   (check-equal? (map car (keys)) '("apis mellifera" "megachile perihirta" "osmia lignaria")
                 "a note under a new species adds that key")

   ;; unapproving a species' only approved note drops the key
   (sql! "UPDATE notes SET status='removed' WHERE id=3;")
   (check-false (assoc "osmia lignaria" (keys))
                "unapproving osmia's last note drops the species key")

   (delete-directory/files tmp)])
