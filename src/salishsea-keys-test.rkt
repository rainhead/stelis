#lang racket/base

;; What each of salishsea's keyed relations is keyed by (st-wn4), run for real: a
;; tiny DuckDB holding each relation as the snapshot does, one `doc' JSON column, with
;; rows shaped like the live ones (sampled from salishsea's Fly machine, 2026-10-25).
;; A key expression that names a field the rows don't carry would group every row
;; under the empty key, and key-blame would say "everything moved" — so each relation
;; is checked against the keys its rows should give. Skips without the duckdb CLI.

(require rackunit
         racket/file
         racket/list
         racket/port
         racket/string
         "relation-digest.rkt"
         "salishsea.rkt")

(define duckdb (find-executable-path "duckdb"))

;; table -> its rows' docs
(define fixture
  '(("snapshot.individuals"
     "{\"id\":1,\"sex\":\"female\",\"entity_id\":\"SSA:0010000\",\"mother_id\":null,\"primary_designation\":\"T002B\"}"
     "{\"id\":226,\"sex\":\"male\",\"entity_id\":\"SSA:0010225\",\"mother_id\":1,\"primary_designation\":\"T069C\"}")
    ("snapshot.designations"
     "{\"id\":1,\"code\":\"AM3\",\"scheme\":\"alaska\",\"individual_id\":1}"
     "{\"id\":2,\"code\":\"T002B\",\"scheme\":\"bc_wa\",\"individual_id\":1}"
     "{\"id\":3,\"code\":\"T069C\",\"scheme\":\"bc_wa\",\"individual_id\":226}")
    ("snapshot.nicknames"
     "{\"id\":1,\"name\":\"D'Arcy\",\"individual_id\":373,\"social_group_id\":null}"
     "{\"id\":2,\"name\":\"The T69s\",\"individual_id\":null,\"social_group_id\":18}")
    ("snapshot.parties"
     "{\"id\":1,\"url\":null,\"kind\":\"organization\",\"name\":\"VanAqua\"}")
    ("snapshot.social_groups"
     "{\"id\":1,\"kind\":\"ecotype\",\"entity_id\":\"SSA:0000002\",\"designation\":\"Biggs\"}"
     "{\"id\":4,\"kind\":\"matriline\",\"entity_id\":\"SSA:0002001\",\"designation\":\"T007\"}")
    ("snapshot.group_parents"
     "{\"group_id\":10000020,\"parent_group_id\":10000010}")
    ("snapshot.matriline_members"
     "{\"group_id\":10000030,\"individual_id\":10000101,\"innermost_group_id\":10003012}"
     "{\"group_id\":10003012,\"individual_id\":10000101,\"innermost_group_id\":10003012}")
    ("snapshot.animal_names"
     "{\"entity_id\":\"SSA:0000002\",\"common_name\":\"Bigg's killer whale\"}")
    ("snapshot.haulouts"
     "{\"id\":170,\"name\":\"Waadah Island\",\"location\":{\"lat\":48.38217,\"lon\":-124.59167}}")
    ("build.individual_occurrences"
     "{\"code\":\"T69s\",\"individual_id\":226,\"occurrence_id\":\"01a15d40\",\"observed_at\":\"2026-09-26T03:08:00+00:00\"}"
     "{\"code\":\"T69s\",\"individual_id\":226,\"occurrence_id\":\"01a15d41\",\"observed_at\":\"2026-09-27T03:08:00+00:00\"}")
    ("build.group_occurrences"
     "{\"code\":\"T34s\",\"social_group_id\":18,\"occurrence_id\":\"01977c2a\"}")
    ("build.ecotype_occurrences"
     "{\"ecotype_id\":1,\"occurrence_id\":\"01977c2a\"}")
    ("build.haulout_occurrences"
     "{\"haulout_id\":170,\"occurrence_id\":\"inat-410615783\"}")))

;; artifact -> the keys its fixture rows must give, sorted as relation-keys sorts them
(define expected
  '((individuals-snapshot "1" "226")
    (designations-snapshot "1" "226")
    (nicknames-snapshot "group:18" "individual:373")
    (parties-snapshot "1")
    (social-groups-snapshot "1" "4")
    (group-parents-snapshot "10000020")
    (matriline-members-snapshot "10000101")
    (animal-names-snapshot "SSA:0000002")
    (haulouts-snapshot "170")
    (build.individual_occurrences "226")
    (build.group_occurrences "18")
    (build.ecotype_occurrences "1")
    (build.haulout_occurrences "170")))

(test-equal? "every keyed relation but the occurrences is checked here"
             (sort (remove 'build.occurrences (hash-keys salishsea-keyed-relations)) symbol<?)
             (sort (map car expected) symbol<?))

(cond
  [(not duckdb)
   (printf "salishsea-keys-test: duckdb not on PATH — skipping.\n")]
  [else
   (define tmp (make-temporary-directory "stelis-salishsea-keys-~a"))
   (define db (build-path tmp "read-path.duckdb"))
   (define (sql-string s) (string-append "'" (string-replace s "'" "''") "'"))
   (define ddl
     (string-append
      "CREATE SCHEMA snapshot; CREATE SCHEMA build;"
      (string-append*
       (for/list ([t (in-list fixture)])
         (format "CREATE TABLE ~a (doc VARCHAR); INSERT INTO ~a VALUES ~a;"
                 (car t) (car t)
                 (string-join (for/list ([d (in-list (cdr t))]) (format "(~a)" (sql-string d)))
                              ", "))))))
   (define-values (p _o _i e) (subprocess #f #f #f duckdb (path->string db) "-c" ddl))
   (subprocess-wait p)
   (unless (zero? (subprocess-status p)) (error 'fixture "duckdb: ~a" (port->string e)))

   (for ([x (in-list expected)])
     (define spec (hash-ref salishsea-keyed-relations (car x)))
     (test-equal? (format "~a is keyed by its rows' subject" (car x))
                  (map car (relation-keys db (car spec) (cdr spec)))
                  (cdr x)))

   (define (counts artifact)
     (define spec (hash-ref salishsea-keyed-relations artifact))
     (for/list ([part (in-list (relation-keys db (car spec) (cdr spec)))])
       (last (string-split (cdr part) ":"))))
   (test-equal? "two sightings of one individual are one key, counting both"
                (counts 'build.individual_occurrences) '("2"))
   (test-equal? "an individual's memberships are one key"
                (counts 'matriline-members-snapshot) '("2"))

   (delete-directory/files tmp)])
