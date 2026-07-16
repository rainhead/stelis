#lang racket/base

;; Tests for the build history (history.rkt, st-sds): the append/load round trip,
;; the once-per-graph snapshot, the observation timeline, and the same
;; graceful-degradation contract the cache and trace hold — a corrupt build is
;; skipped, never fatal, and never takes the surrounding history with it.

(require rackunit
         racket/file
         racket/list
         "model.rkt"
         "cache.rkt"
         "trace.rkt"
         "history.rkt")

(define tmp (make-temporary-file "stelis-history-test-~a" 'directory))

;; a tiny graph: raw -> derive -> mid. Its topology is what the snapshot pins.
(define g
  (build-graph
   (list (make-task 'derive 'transform #:inputs '(raw) #:outputs '(mid)))
   (list (make-artifact 'raw 'file) (make-artifact 'mid 'file))))

;; two builds: `mid' is first produced at hash m0, then rebuilt to m1 (a change).
;; `derive's snapshot is the basis — the input hashes mid was derived from.
(define (rec-derive input-hash mid-hash)
  (trace-record 'derive
                (decision 'run 'input-changed '(raw))
                (snapshot "recipe0" (hash 'raw input-hash))
                'ok '() #f
                (list (cons 'mid mid-hash))
                '()))

(define build1 (list (rec-derive "r0" "m0")))
(define build2 (list (rec-derive "r1" "m1")))

;; --- append + load round trip ------------------------------------------------

(define gh1 (history-append! tmp 'mid g "1000" build1))
(define gh2 (history-append! tmp 'mid g "2000" build2))
(check-equal? gh1 gh2 "same topology ⇒ same graph-hash")
(check-equal? gh1 (graph-digest g) "the recorded hash is the graph digest")

(define builds (history-load tmp))
(check-equal? (length builds) 2 "both builds load")
(check-equal? (map build-record-target builds) '(mid mid) "targets survive")
(check-equal? (map build-record-epoch builds) '("1000" "2000")
              "the source-epoch rides along, in append order")
(check-equal? (build-record-graph-hash (first builds)) gh1 "graph-hash recorded")

;; records survive whole, snapshot (the basis) included
(let ([r (first (build-record-records (first builds)))])
  (check-equal? (trace-record-task r) 'derive "the record's task")
  (check-equal? (trace-record-output-hashes r) '((mid . "m0")) "the observation")
  (check-equal? (snapshot-input-hashes (trace-record-snapshot r)) (hash 'raw "r0")
                "the basis — which input hashes mid was derived from"))

(check-equal? (build-record-epoch (history-last tmp)) "2000"
              "history-last is the tail — the most recent build")

;; --- the graph snapshot ------------------------------------------------------

(check-true (file-exists? (build-path tmp "graphs" (format "~a.rktd" gh1)))
            "the topology snapshot is written under graphs/<hash>.rktd")
(check-equal? (history-graph tmp gh1) (graph->datum g)
              "and reads back as the topology datum")
(check-false (history-graph tmp "deadbeef") "an unknown graph-hash is #f")

;; the snapshot is gated on GRAPH-SNAPSHOT-VERSION, not the build log's version —
;; so bumping the record shape can never orphan an unchanged topology snapshot.
(check-equal? (hash-ref (call-with-input-file
                            (build-path tmp "graphs" (format "~a.rktd" gh1)) read)
                        'version)
              GRAPH-SNAPSHOT-VERSION
              "graph snapshots carry their own shape version, decoupled from history's")

;; --- the observation timeline ------------------------------------------------

(define obs (history-observations tmp 'mid))
(check-equal? (map observation-build obs) '(1 2) "one point per producing build")
(check-equal? (map observation-hash obs) '("m0" "m1") "mid's hash timeline, in order")
(check-equal? (map (lambda (o) (trace-record-task (observation-record o))) obs)
              '(derive derive) "each point names its producing task")
(check-equal? (history-observations tmp 'raw) '()
              "an external input is never observed — it isn't produced here")

;; --- per-key observations (st-6dv) -------------------------------------------

;; a fan-out 'dir producer: species-maps writes one file per genus. Between the
;; two builds, Bombus's map changes and Apis's is dropped — the per-key timeline
;; must let a diff of consecutive maps recover exactly that.
(define kd (make-temporary-file "stelis-history-keys-~a" 'directory))
(define kg
  (build-graph
   (list (make-task 'maps 'transform #:inputs '(taxa) #:outputs '(species-maps)))
   (list (make-artifact 'taxa 'file) (make-artifact 'species-maps 'dir))))
(define (rec-maps taxa-h keys)
  (trace-record 'maps (decision 'run 'input-changed '(taxa))
                (snapshot "r" (hash 'taxa taxa-h)) 'ok '() #f
                (list (cons 'species-maps "dir-digest"))
                (list (cons 'species-maps keys))))
(history-append! kd 'species-maps kg "1"
                 (list (rec-maps "t0" '(("genus/Bombus.svg" . "b0")
                                        ("genus/Apis.svg"   . "a0")))))
(history-append! kd 'species-maps kg "2"
                 (list (rec-maps "t1" '(("genus/Bombus.svg" . "b1")))))

(define kobs (history-key-observations kd 'species-maps))
(check-equal? (map key-observation-build kobs) '(1 2)
              "one per-key point per producing build")
(check-equal? (key-observation-keys (first kobs))
              '(("genus/Bombus.svg" . "b0") ("genus/Apis.svg" . "a0"))
              "build 1's full (path -> hash) map")
(check-equal? (key-observation-keys (second kobs))
              '(("genus/Bombus.svg" . "b1"))
              "build 2's map — Bombus changed, Apis dropped")
(check-equal? (history-key-observations kd 'taxa) '()
              "a 'file artifact has no per-key layer")
(delete-directory/files kd)

;; --- graceful degradation ----------------------------------------------------

;; a corrupt line in the middle is skipped; the builds around it still load
(define hfile (build-path tmp "history.rktd"))
(define good-lines (file->lines hfile))
(display-to-file
 (string-append (first good-lines) "\n"
                "{ this is not a readable datum\n"
                (second good-lines) "\n")
 hfile #:exists 'replace)
(check-equal? (length (history-load tmp)) 2
              "a corrupt build is skipped; the readable ones survive")

;; a wrong-version line is likewise dropped, not fatal
(display-to-file
 (string-append (first good-lines) "\n"
                "#hash((version . 999) (target . x) (records . ()))\n")
 hfile #:exists 'replace)
(check-equal? (length (history-load tmp)) 1
              "an other-version build is dropped like a stale cache entry")

;; missing history is empty, never an error
(check-equal? (history-load (build-path tmp "nowhere")) '() "no history ⇒ '()")
(check-false (history-last (build-path tmp "nowhere")) "no history ⇒ no last build")

(delete-directory/files tmp)
