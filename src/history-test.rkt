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
         "dasl.rkt"
         "drisl.rkt"
         "blockstore.rkt"
         (only-in "keyed-block.rkt" keyed-block-digest keyed-node?)
         (only-in "delta.rkt" build-key-delta key-delta-changed)
         "history.rkt")

(define tmp (make-temporary-file "stelis-history-test-~a" 'directory))

;; a tiny graph: raw -> derive -> mid. Its topology is what the snapshot pins.
(define g
  (build-graph
   (list (make-task 'derive 'transform #:inputs '(raw) #:outputs '(mid)))
   (list (make-artifact 'raw 'file #:provenance 'upstream) (make-artifact 'mid 'file))))

;; two builds: `mid' is first produced at hash m0, then rebuilt to m1 (a change).
;; `derive's snapshot is the basis — the input hashes mid was derived from.
(define (rec-derive input-hash mid-hash)
  (trace-record 'derive
                (decision 'run 'input-changed '(raw))
                (snapshot "recipe0" (hash 'raw input-hash))
                'ok '() #f
                (list (cons 'mid mid-hash))
                '()
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

(define snapshot-file (block-path tmp gh1))

(check-true (file-exists? snapshot-file)
            "the topology snapshot is a block, filed under its own CID")
(check-equal? (history-graph tmp gh1) (graph->datum g)
              "and reads back as the topology datum")
(check-false (history-graph tmp "deadbeef") "an unknown graph-hash is #f")

;; The filename is not a name BESIDE the content, it is a name OF the content
;; (st-b7v): re-addressing the bytes on disk must reproduce it, which is what makes
;; a silently-corrupted snapshot detectable rather than merely unparseable.
(check-equal? (cid->string (content->cid (file->bytes snapshot-file) 'drisl)) gh1
              "the snapshot's filename is the CID of its own bytes")

;; the snapshot is gated on GRAPH-SNAPSHOT-VERSION, not the build log's version —
;; so bumping the record shape can never orphan an unchanged topology snapshot.
;; The version now rides INSIDE the block rather than in an envelope beside it.
(check-equal? (hash-ref (drisl-decode (file->bytes snapshot-file)) "version")
              GRAPH-SNAPSHOT-VERSION
              "graph snapshots carry their own shape version, decoupled from history's")
(check-equal? (hash-ref (drisl-decode (file->bytes snapshot-file)) "format")
              "stelis-graph"
              "...and say what they are, so a foreign block is not mistaken for one")

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
   (list (make-artifact 'taxa 'file #:provenance 'upstream) (make-artifact 'species-maps 'dir))))
(define (rec-maps taxa-h keys)
  (trace-record 'maps (decision 'run 'input-changed '(taxa))
                (snapshot "r" (hash 'taxa taxa-h)) 'ok '() #f
                (list (cons 'species-maps "dir-digest"))
                (list (cons 'species-maps keys))
                '()))
(history-append! kd 'species-maps kg "1"
                 (list (rec-maps "t0" '(("genus/Bombus.svg" . "b0")
                                        ("genus/Apis.svg"   . "a0")))))
(history-append! kd 'species-maps kg "2"
                 (list (rec-maps "t1" '(("genus/Bombus.svg" . "b1")))))

(define kobs (history-key-observations kd 'species-maps))
(check-equal? (map key-observation-build kobs) '(1 2)
              "one per-key point per producing build")
;; Sorted by key: the map is stored as a block (st-1e5) and a block has no order
;; to preserve, so the timeline presents one canonical order rather than whichever
;; the producer happened to emit. diff-key-maps hashes both sides, so nothing
;; downstream can tell — and now nothing downstream can accidentally depend on it.
(check-equal? (key-observation-keys (first kobs))
              '(("genus/Apis.svg" . "a0") ("genus/Bombus.svg" . "b0"))
              "build 1's full (path -> hash) map, canonically ordered")
(check-equal? (key-observation-keys (second kobs))
              '(("genus/Bombus.svg" . "b1"))
              "build 2's map — Bombus changed, Apis dropped")
(check-equal? (history-key-observations kd 'taxa) '()
              "a 'file artifact has no per-key layer")

;; The payoff (st-1e5): a keyed map lives in the block store and the log line names
;; it, so a build that re-produced an UNCHANGED map costs no new storage. This is
;; the growth property the observation history needs — it is designed to grow
;; forever, and before this it rewrote every species on every build.
(let ([before (length (directory-list (blocks-dir kd)))])
  (history-append! kd 'species-maps kg "3"
                   (list (rec-maps "t1" '(("genus/Bombus.svg" . "b1")))))
  (check-equal? (length (directory-list (blocks-dir kd))) before
                "re-observing an identical map adds no block")
  (check-equal? (key-observation-keys (third (history-key-observations kd 'species-maps)))
                '(("genus/Bombus.svg" . "b1"))
                "...and the third build still has its own full observation"))

;; A LOST BLOCK MUST NOT READ AS "NOTHING MOVED". This is the dangerous shape: the
;; earlier build's observation survives and only the LAST one is gone. If the lost
;; point were merely dropped, the artifact would look UNOBSERVED at the last build —
;; the signature of a cache-skip — and build-key-delta would answer 'not-produced,
;; i.e. "nothing moved". `--moved-keys` would then exit 0 in silence for a build
;; where keys did move, and a caller that rebuilds per key would publish stale
;; output. The timeline must refuse instead.
(let ([kd2 (make-temporary-file "stelis-history-gone-~a" 'directory)])
  (history-append! kd2 'species-maps kg "1"
                   (list (rec-maps "t0" '(("genus/Apis.svg" . "a0")))))
  (history-append! kd2 'species-maps kg "2"
                   (list (rec-maps "t1" '(("genus/Apis.svg" . "a1")))))
  (check-equal? (length (history-key-observations kd2 'species-maps)) 2
                "both builds observed before anything is lost")
  ;; drop ONLY the second build's map block, leaving the first intact
  (delete-file (block-path kd2 (keyed-block-digest '(("genus/Apis.svg" . "a1")))))
  (check-equal? (history-key-observations kd2 'species-maps) '()
                "one unreadable point poisons the timeline rather than thinning it")
  (check-eq? (build-key-delta 'species-maps (history-key-observations kd2 'species-maps) 2)
             'no-basis
             "so the delta REFUSES — never 'not-produced, which means 'nothing moved'")
  (check-equal? (length (history-load kd2)) 2
                "and the builds themselves still load — records are not lost with it")
  (delete-directory/files kd2))

;; Storing a map can fail — a producer emitting a duplicate key is refused by
;; keyed-block — and this runs AFTER the build succeeded, so it must not cost the
;; record. It falls back to the pre-st-1e5 inline shape, which the reader accepts.
(let ([kd3 (make-temporary-file "stelis-history-inline-~a" 'directory)])
  (history-append! kd3 'species-maps kg "1"
                   (list (rec-maps "t0" '(("genus/Apis.svg" . "a0")
                                          ("genus/Apis.svg" . "a1")))))
  (check-equal? (length (history-load kd3)) 1 "the build record survives the failure")
  (check-equal? (key-observation-keys (first (history-key-observations kd3 'species-maps)))
                '(("genus/Apis.svg" . "a0") ("genus/Apis.svg" . "a1"))
                "...with its map written inline instead of as a block")
  (delete-directory/files kd3))

(delete-directory/files kd)

;; --- #:keyed-tail: the maps a recent-builds reader needs, and no others ---------
;; The build log shows the last k builds and diffs each production with the one
;; before it, however old. So: the last k builds' maps, and before them each
;; artifact's latest map; everything older is marked, never read as an answer.
(let ([kt (make-temporary-file "stelis-history-tail-~a" 'directory)])
  (define cache-skip
    (trace-record 'maps (decision 'skip 'inputs-unchanged '()) #f 'cached '() #f '() '() '()))
  (history-append! kt 'species-maps kg "1" (list (rec-maps "t0" '(("a" . "0")))))
  (history-append! kt 'species-maps kg "2" (list (rec-maps "t1" '(("a" . "1")))))
  (history-append! kt 'species-maps kg "3" (list cache-skip))
  (history-append! kt 'species-maps kg "4" (list (rec-maps "t2" '(("a" . "2")))))
  (define (keys-at builds n)
    (let ([p (assq 'species-maps
                   (trace-record-output-key-hashes (first (build-record-records (list-ref builds (sub1 n))))))])
      (and p (cdr p))))
  (define full (history-load kt))
  (define tail (history-load kt #:keyed-tail 1))
  (check-equal? (keys-at tail 4) '(("a" . "2")) "the tail's own map is read")
  (check-equal? (keys-at tail 2) '(("a" . "1"))
                "and the latest map before it — build 3 didn't produce, so build 2's — the delta's basis")
  (check-eq? (keys-at tail 1) 'unresolved "an older map is marked, not read")
  (check-equal? (map build-record-epoch tail) (map build-record-epoch full) "every build still loads")
  (define (kobs-of builds)
    (for*/list ([(br i) (in-indexed (in-list builds))]
                [r (in-list (build-record-records br))]
                [p (in-value (assq 'species-maps (trace-record-output-key-hashes r)))]
                #:when p)
      (key-observation (add1 i) (cdr p) r)))
  (check-equal? (build-key-delta 'species-maps (kobs-of tail) 4)
                (build-key-delta 'species-maps (kobs-of full) 4)
                "so the newest build's delta is the full load's")
  (delete-directory/files kt))

;; --- Retention (st-ml9.7): aged builds go, survivors keep their numbers ----------
(let ([rt (make-temporary-file "stelis-history-retention-~a" 'directory)])
  (define day 86400)
  (define t0 1790000000)
  ;; a build from before retention existed: its line carries no recorded-at
  (history-append! rt 'species-maps kg "0" (list (rec-maps "t" '(("a" . "legacy")))) #:project 'salishsea)
  (let* ([f (build-path rt "history.rktd")]
         [e (read (open-input-string (car (file->lines f))))])
    (call-with-output-file f #:exists 'truncate
      (lambda (o) (write (hash-remove e 'recorded-at) o) (newline o))))
  (for ([at (list t0 (+ t0 day) (+ t0 (* 40 day)) (+ t0 (* 41 day)))]
        [v (in-naturals 1)])
    (history-append! rt 'species-maps kg (number->string v)
                     (list (rec-maps "t" (list (cons "a" (format "v~a" v)))))
                     #:project 'salishsea #:recorded-at at))
  (define blocks-before (length (directory-list (build-path rt "blocks"))))
  (define-values (gone collected) (history-prune! rt (* 30 day) #:now (+ t0 (* 45 day))))
  (check-equal? gone 3 "the undated build and the two older than thirty days")
  (check-equal? collected 3 "and the three maps only they named; the graph snapshot stays")
  (check-equal? (length (directory-list (build-path rt "blocks"))) (- blocks-before 3))
  (define kept (history-load rt))
  (check-equal? (map build-record-number kept) '(4 5) "survivors keep the numbers they had")
  (check-equal? (map build-record-epoch kept) '("3" "4"))
  (check-equal? (history-pruned-count rt) 3)
  (check-equal? (map key-observation-build (history-key-observations rt 'species-maps)) '(4 5)
                "every map a survivor names still reads")
  (check-eq? (build-key-delta 'species-maps (history-key-observations rt 'species-maps) 4)
             'no-basis
             "the first production after the horizon has nothing to diff against, and says so")
  (check-equal? (history-foreign-projects rt 'salishsea) '()
                "the header line is not a build, so it is no other project's either")
  (define-values (none _c) (history-prune! rt (* 30 day) #:now (+ t0 (* 45 day))))
  (check-equal? none 0 "pruning again drops nothing")
  (history-append! rt 'species-maps kg "5" (list (rec-maps "t" '(("a" . "v5"))))
                   #:project 'salishsea #:recorded-at (+ t0 (* 46 day)))
  (check-equal? (map build-record-number (history-load rt)) '(4 5 6) "and the next build is #6")
  (delete-directory/files rt))

;; --- Chunked maps (st-ml9.7): stored as a tree, read back whole ---------------
(let ([ct (make-temporary-file "stelis-history-chunked-~a" 'directory)])
  (define big (for/list ([i (in-range 1000)]) (cons (format "days/~a.json" i) (format "h~a" i))))
  (define day 86400)
  (history-append! ct 'species-maps kg "1" (list (rec-maps "t0" big)) #:project 'salishsea #:recorded-at 0)
  (history-append! ct 'species-maps kg "2"
                   (list (rec-maps "t1" (cons '("days/0.json" . "moved") (cdr big))))
                   #:project 'salishsea #:recorded-at (* 40 day))
  (define (keys-at n)
    (key-observation-keys (list-ref (history-key-observations ct 'species-maps) (sub1 n))))
  (check-equal? (keys-at 1) (sort big string<? #:key car) "a chunked map reads back whole")
  (check-equal? (key-delta-changed (build-key-delta 'species-maps (history-key-observations ct 'species-maps) 2))
                '("days/0.json")
                "and the delta between two of them names the one key that moved")
  ;; the first build expires; its root goes, the second's buckets (shared or not) stay
  (define-values (gone _collected) (history-prune! ct (* 30 day) #:now (* 41 day)))
  (check-equal? gone 1)
  (check-equal? (keys-at 1) (sort (cons '("days/0.json" . "moved") (cdr big)) string<? #:key car)
                "pruning keeps every bucket a surviving root reaches")
  ;; a lost bucket makes the map unreadable, never smaller
  (define blocks (build-path ct "blocks"))
  (for ([b (in-list (directory-list blocks))]
        #:when (let ([v (block-ref ct (path->string b))])
                 (and (hash? v) (not (keyed-node? v)) (hash-has-key? v "days/0.json"))))
    (delete-file (build-path blocks b)))
  (check-equal? (history-key-observations ct 'species-maps) '()
                "a chunked map missing a bucket is unresolved, which poisons the timeline as one missing block does")
  (delete-directory/files ct))

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

;; --- publish receipts (st-8x1): the sidecar the publish path writes back -----
(check-equal? (publish-receipts-load tmp) '() "no publish.log ⇒ '()")
(publish-receipt-append! tmp 3 "1754000000" 'not-published "integration-gate" 'nightly)
(publish-receipt-append! tmp 4 "1754100000" 'published "merge-swap" 'note)
(let ([rs (publish-receipts-load tmp)])
  (check-equal? (length rs) 2 "append order, both readable")
  (check-equal? (hash-ref (first rs) 'build) 3)
  (check-equal? (hash-ref (first rs) 'outcome) 'not-published)
  (check-equal? (hash-ref (second rs) 'path) 'note))
;; corrupt and other-version lines drop, same tolerance as the history log
(call-with-output-file (build-path tmp "publish.log") #:exists 'append
  (lambda (o)
    (displayln "{ not a datum" o)
    (writeln (hash 'version 999 'build 9) o)))
(check-equal? (length (publish-receipts-load tmp)) 2
              "garbage and other-version receipts are skipped, never errors")

(delete-directory/files tmp)

;; --- which project a history belongs to (st-z1c) -------------------------------
;; A record names its project; a keyless record predates the field and is
;; beeatlas's, because beeatlas was the only graph when it was written.
(let ([dir (make-temporary-file "stelis-history-project-~a" 'directory)])
  (check-equal? (history-foreign-projects dir 'salishsea) '()
                "an empty dir belongs to nobody, so it refuses nobody")
  ;; a legacy line, exactly as every pre-st-z1c build wrote it: no 'project
  (with-output-to-file (build-path dir "history.rktd")
    (lambda ()
      (write (hash 'version 3 'target 'all 'graph-hash "g" 'epoch "1" 'records '()))
      (newline)))
  (check-equal? (history-foreign-projects dir 'beeatlas) '()
                "a keyless record is beeatlas's")
  (check-equal? (history-foreign-projects dir 'salishsea) '(beeatlas)
                "...so salishsea sees it as foreign")
  (history-append! dir 'mid g "2" build1 #:project 'salishsea)
  (check-equal? (history-foreign-projects dir 'salishsea) '(beeatlas)
                "a mixed dir still names the foreign project")
  (check-equal? (history-foreign-projects dir 'beeatlas) '(salishsea)
                "...from either side")
  (check-equal? (length (history-load dir)) 2
                "the key is additive: both lines still load as builds"))

(let ([dir (make-temporary-file "stelis-history-project-~a" 'directory)])
  (history-append! dir 'mid g "1" build1)
  (check-equal? (history-foreign-projects dir 'beeatlas) '()
                "history-append! without #:project writes a beeatlas record"))
