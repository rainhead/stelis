#lang racket/base

;; Which database a project reads (st-az9): project.rkt's db-binding and its two
;; pure questions — how the banner names it, and whether an executing mode must
;; refuse it. main.rkt only adds `file-exists?' and the exit.

(require rackunit
         racket/string
         "project.rkt")

(define fallback (string->path "/repo/data/beeatlas.duckdb"))

;; --- env-db-binding: total, whatever the environment says --------------------

(define (bind env-value #:strict? [strict? #t])
  (parameterize ([current-environment-variables
                  (make-environment-variables)])
    (when env-value (putenv "DB_PATH" env-value))
    (env-db-binding "beeatlas DuckDB" "DB_PATH" fallback #:strict? strict?)))

(let ([b (bind #f)])
  (check-equal? (db-binding-path b) fallback "unset -> the fallback")
  (check-false (db-binding-from-env? b) "and says so"))
(let ([b (bind "/var/beeatlas.duckdb")])
  (check-equal? (db-binding-path b) (string->path "/var/beeatlas.duckdb"))
  (check-true (db-binding-from-env? b)))
(let ([b (bind "")])
  (check-equal? (db-binding-path b) fallback
                "an EMPTY value is unset — not the empty path, which would raise")
  (check-false (db-binding-from-env? b)))

;; --- db-binding-refusal: only the ambiguous case refuses ----------------------

(check-false (db-binding-refusal (bind "/var/beeatlas.duckdb") #t "--build")
             "chosen by the env var: nothing to refuse")
(check-false (db-binding-refusal (bind "/nowhere.duckdb") #f "--build")
             "an absent chosen file is not refused here (a first build creates it)")
(check-false (db-binding-refusal (bind #f) #f "--build")
             "an ABSENT fallback fails on its own; it is not the hazard")
(check-false (db-binding-refusal (bind #f #:strict? #f) #t "--build")
             "a non-strict binding keeps its fallback (salishsea's snapshot)")
(let ([why (db-binding-refusal (bind #f) #t "--build")])
  (check-true (string? why) "unset AND the fallback exists: refused")
  (check-true (string-contains? why "/repo/data/beeatlas.duckdb")
              "naming the file it would have read")
  (check-true (string-contains? why "DB_PATH=/repo/data/beeatlas.duckdb racket src/main.rkt --build")
              "and how to say that one is meant"))

;; --- db-binding-description: which file, and where the choice came from -------

(check-equal? (db-binding-description (bind "/var/beeatlas.duckdb") #t)
              "beeatlas DuckDB: /var/beeatlas.duckdb (from DB_PATH)")
(check-equal? (db-binding-description (bind #f) #t)
              "beeatlas DuckDB: /repo/data/beeatlas.duckdb — DB_PATH is unset, so this is the FALLBACK")
(check-equal? (db-binding-description (bind #f #:strict? #f) #t)
              "beeatlas DuckDB: /repo/data/beeatlas.duckdb — DB_PATH is unset, so this is the default"
              "not shouted where the fallback cannot be the wrong file")
(check-equal? (db-binding-description (bind "/nowhere.duckdb") #f)
              "beeatlas DuckDB: /nowhere.duckdb (from DB_PATH) — no such file"
              "a chosen file that is not there is said, not silently accepted")

;; --- a RELATIVE chosen path names two files (st-hs7) ---------------------------
;; The engine resolves it from its cwd; the tasks get the raw string and resolve it
;; from theirs. Executing modes refuse it, strict or not; read-only banners flag it.

(parameterize ([current-directory (string->path "/stelis/")])
  (let ([why (db-binding-refusal (bind "data/beeatlas.duckdb") #t "--build")])
    (check-true (string? why) "a relative DB_PATH is refused")
    (check-true (string-contains? why "/stelis/data/beeatlas.duckdb")
                "naming the absolute path the ENGINE would read")
    (check-true (string-contains? why "DB_PATH=/stelis/data/beeatlas.duckdb racket src/main.rkt --build")
                "and how to say it absolutely"))
  (check-true (string? (db-binding-refusal (bind "data/beeatlas.duckdb") #f "--build"))
              "refused whether or not the file exists: either way two files are meant")
  (check-true (string? (db-binding-refusal (bind "read-path.duckdb" #:strict? #f) #t "--build"))
              "non-strict too: salishsea's tasks take the snapshot path as argv, from their own cwd")
  (check-equal? (db-binding-description (bind "data/beeatlas.duckdb") #t)
                "beeatlas DuckDB: data/beeatlas.duckdb (from DB_PATH, relative to /stelis/)"
                "read-only modes still run, and the banner says what it is relative to"))
