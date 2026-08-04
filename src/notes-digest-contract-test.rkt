#lang racket/base

;; Cross-repo CONTRACT test (st-whm): stelis's notes-store-keys (notes-digest.rkt)
;; hardcodes beeatlas's `users` INNER JOIN, the status='approved' filter, and the
;; hashed field list — all MIRRORING beeatlas's notes_harvest.export_notes. Nothing
;; but this test ties the two: a field added to the harvest, or a filter changed on
;; either side, would silently drift the digest from the artifact it is supposed to
;; content-address.
;;
;; So we stand up ONE store from beeatlas's REAL SQLAlchemy models (via the
;; notes_contract_fixture.py driver, run in beeatlas's uv/3.14 runtime), run the
;; REAL export_notes over it, and assert notes-store-keys agrees on:
;;   1. KEYSET      — the species that get a digest key == the species that get a file
;;   2. COUNT       — each key's `:count` == the number of notes in that species' file
;;   3. SENSITIVITY — for each single-field edit of one note (body_html; and body with
;;                    body_html held fixed), the species whose HARVEST OUTPUT moved ==
;;                    the species whose DIGEST KEY moved
;; (1)+(2) catch status-filter / grouping drift; (3) catches the stated risk a keyset
;; check alone cannot — a field the harvest emits but the digest forgets to hash. The
;; body-only edit is st-8qj, where hashing the pre-rendered body_html as a PROXY for
;; body was unsound because markdown->HTML is many-to-one.
;;
;; The INNER JOIN users case (an orphan author) is NOT exercised here: notes.author_id
;; is a FK to users.id with foreign_keys=ON, so an orphan can't exist in a real store.
;; That branch is covered against a hand-rolled FK-less store in notes-digest-test.rkt.
;;
;; GATED like the other environment-coupled suites (the CI-has-no-beeatlas idiom): a
;; bare checkout / CI lacking beeatlas, uv, or duckdb prints a skip note and passes,
;; keeping `raco test src/*-test.rkt` green. Locally it is a real regression guard.

(require rackunit
         racket/file
         racket/port
         racket/system
         racket/list
         racket/runtime-path
         json
         "notes-digest.rkt")

(define BEEATLAS (or (getenv "BEEATLAS_DIR") "/Users/rainhead/dev/beeatlas"))
(define DATA (build-path BEEATLAS "data"))
(define-runtime-path fixture "notes_contract_fixture.py")
(define uv     (find-executable-path "uv"))
(define duckdb (find-executable-path "duckdb"))

;; the store built from the real models needs the notes_store package + notes_harvest
(define beeatlas-notes?
  (and (file-exists? (build-path DATA "notes_store" "models.py"))
       (file-exists? (build-path DATA "notes_harvest.py"))))

;; Run the fixture driver in beeatlas's uv runtime; return its parsed JSON summary:
;;   { "s0" -> (hash species -> (hash 'count N 'sha "..")), "s1" -> ... }
;; The driver writes s0/notes.db and s1/notes.db under out-dir, which we digest.
(define (run-fixture out-dir)
  (define argv (list "run" "--directory" (path->string DATA) "python"
                     (path->string fixture) (path->string DATA)
                     (path->string out-dir)))
  (define-values (sp stdout stdin stderr)
    (apply subprocess #f #f #f uv argv))
  (close-output-port stdin)
  (define out (port->string stdout))
  (define err (port->string stderr))
  (subprocess-wait sp)
  (unless (eqv? 0 (subprocess-status sp))
    (error 'run-fixture "fixture driver failed:\n~a" err))
  (string->jsexpr out))

;; notes-store-keys as a plain species->count hash, dropping the digest half — the
;; keyset and counts are what the harvest also determines (a file, and its length).
(define (digest-counts db)
  (for/hash ([kv (in-list (notes-store-keys db))])
    (define digest:count (cdr kv))
    (define n (cadr (regexp-match #px":([0-9]+)$" digest:count)))
    (values (car kv) (string->number n))))

;; the raw species->digest map, for the sensitivity comparison (which keys MOVED)
(define (digest-map db)
  (for/hash ([kv (in-list (notes-store-keys db))]) (values (car kv) (cdr kv))))

;; species whose value differs between two hashes (symmetric — added/removed/changed)
(define (moved-keys a b)
  (for/list ([k (in-list (remove-duplicates (append (hash-keys a) (hash-keys b))))]
             #:unless (equal? (hash-ref a k #f) (hash-ref b k #f)))
    k))

(cond
  [(not (and beeatlas-notes? uv duckdb))
   (printf "notes-digest-contract-test: ~a absent — skipping.\n"
           (cond [(not beeatlas-notes?) "beeatlas notes_store"]
                 [(not uv) "uv"]
                 [else "duckdb"]))]
  [else
   (define tmp (make-temporary-file "stelis-notes-contract-~a" 'directory))
   (define summary (run-fixture tmp))
   (define s0-db (build-path tmp "s0" "notes.db"))
   (define s1-db (build-path tmp "s1" "notes.db"))
   (define s2-db (build-path tmp "s2" "notes.db"))

   ;; harvest side: {species -> count} from the emitted files, per state
   (define (harvest-counts state)
     (for/hash ([(sp info) (in-hash (hash-ref summary state))])
       (values (symbol->string sp) (hash-ref info 'count))))
   ;; harvest side: which species' emitted FILE moved between s0 and s1 (by sha)
   (define (harvest-shas state)
     (for/hash ([(sp info) (in-hash (hash-ref summary state))])
       (values (symbol->string sp) (hash-ref info 'sha))))

   ;; --- (1) keyset + (2) count agreement, on the base state s0 --------------
   (define h0 (harvest-counts 's0))
   (define d0 (digest-counts s0-db))
   (check-equal? (sort (hash-keys d0) string<?) (sort (hash-keys h0) string<?)
                 "digest keyset == harvest's emitted-file species set")
   (check-equal? d0 h0
                 "each digest key's :count == the note count in that species' file")

   ;; sanity: the fixture actually exercised the discriminating rows (a green-by-
   ;; emptiness contract would be worthless).
   (check-equal? (hash-ref h0 "apis mellifera" #f) 2
                 "fixture built a multi-note species (guards count, not just keyset)")
   (check-false (hash-ref h0 "bombus vosnesenskii" #f)
                "a removed-only species yields no file and no key")
   (check-false (hash-ref h0 "megachile perihirta" #f)
                "a pending-only species yields no file and no key")

   ;; --- (3) field sensitivity: harvest-moved species == digest-moved species -
   ;; Each state is s0 with ONE note-content field of ONE note edited, so the harvest
   ;; output of exactly one species moves; the digest must move the same key.
   (define (check-sensitivity state db what)
     (define harvest-moved
       (sort (moved-keys (harvest-shas 's0) (harvest-shas state)) string<?))
     (define digest-moved
       (sort (moved-keys (digest-map s0-db) (digest-map db)) string<?))
     ;; first that the edit is REAL and single-species — otherwise the agreement
     ;; below would hold vacuously, both sides empty
     (check-equal? harvest-moved (list "apis mellifera")
                   (format "editing ~a moves the edited species' harvest output" what))
     (check-equal? digest-moved harvest-moved
                   (format (string-append "editing ~a moves exactly the species whose harvest "
                                          "output moved — the digest hashes the fields the "
                                          "harvest emits")
                           what)))

   (check-sensitivity 's1 s1-db "one note's body_html")
   ;; st-8qj: body_html is a STORED, pre-rendered column, and the digest used it as a
   ;; proxy for body. markdown->HTML is many-to-one, so a source-only edit can render
   ;; byte-identically — and the harvest emits body as body_md, so its file moves while
   ;; a body_html-only digest sits still and notes/<name>.json goes stale.
   (check-sensitivity 's2 s2-db "one note's body with its body_html held FIXED")

   (delete-directory/files tmp)])
