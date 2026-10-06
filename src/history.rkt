#lang racket/base

;; The build HISTORY (st-sds): an append-only, content-addressed record of every
;; --build, under .stelis/. It retires trace.rkt's single `last-build.rktd` — the
;; last build is now just history's tail — and gives freshness a MEMORY: each
;; build's per-task OBSERVATIONS (artifact→hash) accumulate into a timeline the
;; delta substrate (st-066) will later fold over.
;;
;; THE LINE WE HOLD (DESIGN, st-sds): history records build SEQUENCE (append
;; order) for BROWSING only. Freshness never consults the sequence — only content
;; hashes + the dependency graph, exactly as cache.rkt already does. There is no
;; clock here and no monotonic event-id; naming/traversing whole build states is a
;; separate story (ROADMAP H3). So this file grows forward and is read in order,
;; but "is X current?" is answered elsewhere, from hashes alone.
;;
;; Same discipline as the cache sidecars and the old trace: DERIVED, DISPOSABLE
;; state, format-VERSIONED. Each appended build is one self-contained, versioned
;; datum on its own line; a line that fails to parse or carries a stale version is
;; SKIPPED, never fatal — a bad record never nukes the history around it. Deleting
;; .stelis/ only forgets the timeline; the next build starts a fresh one.
;;
;; STORAGE, not an index: builds are a flat .rktd log, projected into the Datalog
;; fact layer (provenance-datalog.rkt) for queries. SQLite waits until a query
;; outgrows in-memory Datalog (DESIGN: defer it). The log is READ A LINE AT A TIME,
;; from either end, and never held whole (st-6gv): a project that builds every five
;; minutes has a log of hundreds of megabytes at its retention, on a machine that
;; is also serving its site.

(require racket/file
         (only-in racket/port copy-port)
         racket/list
         racket/path
         racket/set
         racket/string
         "model.rkt"
         "cache.rkt"    ; read-versioned — the shared versioned-file reader
         "blockstore.rkt"
         (only-in "keyed-block.rkt" keyed-tree-blocks keyed-node? keyed-node-links)
         "trace.rkt")

(provide (struct-out build-record)
         (struct-out observation)
         (struct-out key-observation)
         history-append!
         history-prune!
         history-pruned-count
         history-load
         history-fold
         history-tail
         history-last
         history-last-number
         history-find
         history-last-source-report
         history-observations
         history-key-observations
         history-key-fold
         history-graph
         history-foreign-projects
         LEGACY-PROJECT
         publish-receipts-load
         publish-receipt-append!)

;; Bump when the envelope or record shape changes; older lines then read as
;; (skipped) misses, exactly like a stale cache sidecar. v2: records carry
;; per-key observations (st-6dv). v3: records carry input-key-hashes — the
;; ingestion-boundary CRUD-snapshot of keyed store inputs (st-2k9).
(define HISTORY-VERSION 3)

;; One build's persisted result.
;;   target     : symbol — the artifact this build was asked to produce
;;   graph-hash : string — the topology it ran against (graph-digest); the full
;;                snapshot lives once in the block store, under its own CID
;;   epoch      : string — the build's SOURCE_DATE_EPOCH (source snapshot clock);
;;                sequence metadata for BROWSING, never consulted for freshness
;;   records    : (listof trace-record) — per task, in build order
;;   number     : exact-positive-integer — its 1-based number in the whole history,
;;                pruned builds included (history-prune!), so a build keeps its
;;                number when older ones are dropped
(struct build-record (target graph-hash epoch records number) #:transparent)

;; One artifact observed at one build: the timeline point history-observations
;; walks. `record' is the producing task's trace-record — its snapshot is the
;; observation's BASIS (which input hashes it was derived from), the seam the
;; delta substrate (st-066) will use to attribute change.
;;   build  : exact-positive-integer — 1-based position in the history
;;   hash   : string — the artifact's content hash at that build
;;   record : trace-record — the producing task's record
(struct observation (build hash record) #:transparent)

;; The finer, PER-KEY point (st-6dv): one 'dir artifact's whole (path -> hash) map
;; at one build. Consecutive key-observations differ in which KEYS changed — the
;; caller diffs them to name the fan-out members that moved, without ever reading
;; an input relation.
;;   build  : exact-positive-integer — 1-based position in the history
;;   keys   : (listof (cons string string)) — sorted (relative-path -> hash) pairs
;;   record : trace-record — the producing task's record
(struct key-observation (build keys record) #:transparent)

(define (history-file state-dir) (build-path state-dir "history.rktd"))

;; --- Which project a history belongs to (st-z1c) ------------------------------
;; A build record names its PROJECT, so a state dir can refuse builds that aren't
;; its own. Before a second graph existed there was nothing to name, and a shared
;; dir would have interleaved two timelines into one log with nothing to separate
;; them — --history and --why would then read across both, confidently. Separate
;; dirs per project are the convention, but convention fails silently on one
;; misconfigured STELIS_STATE_DIR; a record that says whose it is fails loudly.
;;
;; The field is additive, not a HISTORY-VERSION bump: a bump would make every
;; existing line read as a stale miss and throw away the whole timeline to add one
;; symbol. A line WITHOUT the field was written before this existed, when beeatlas
;; was the only graph — so keyless means beeatlas, as a fact about the past rather
;; than a default about the future.
(define LEGACY-PROJECT 'beeatlas)

;; history-foreign-projects : path-string symbol -> (listof symbol)
;; The projects OTHER than `project' that have builds recorded under `state-dir',
;; sorted; '() when the dir is empty, missing, or wholly `project''s. Any version
;; counts — a stale-version line is still a record of SOME project's build, and a
;; dir that holds one is still that project's dir.
;;
;; Asked of the OLDEST and NEWEST builds only, because this check runs before every
;; append: once a dir holds one project's builds, another project's build is refused
;; rather than written, so the projects in a log can only change where it began
;; (a legacy keyless log a new project was pointed at) or where it ends (a log
;; another project wrote last). Reading every line answered the same question in
;; time and memory that grew with the log — on salishsea's Fly machine, a whole
;; parse of a history that reaches ~200 MB at its retention, before every build.
(define (history-foreign-projects state-dir project)
  (define f (history-file state-dir))
  (cond
    [(not (file-exists? f)) '()]
    [else
     (define (project-of line)
       (define e (with-handlers ([exn:fail? (lambda (_) #f)]) (read (open-input-string line))))
       (and (hash? e) (not (pruned-header? e)) (hash-ref e 'project LEGACY-PROJECT)))
     (define seen
       (filter values (list (first-line-where f project-of) (last-line-where f project-of))))
     (sort (remove-duplicates (remove* (list project) seen))
           symbol<?)]))

;; --- Reading a log without loading it ------------------------------------------
;; Racket strings hold four bytes a character, so `file->lines' on a history of N
;; bytes costs ~4N of memory: on salishsea's 1 GB machine, a log near its 30-day
;; retention would not fit (st-6gv: ~25 KB a build, 288 builds a day, 30 days —
;; ~200 MB of text, ~800 MB as strings, beside the site it serves). So nothing here
;; holds the log: every reader walks it a line at a time, from whichever end its
;; question is nearer, and keeps only the builds it was asked for.

;; first-line-where : path (string -> (or/c X #f)) -> (or/c X #f)
;; The first non-#f answer of `f' over the file's lines, in order, reading only as
;; far as it.
(define (first-line-where path f)
  (call-with-input-file path
    (lambda (in)
      (let loop ()
        (define line (read-line in 'linefeed))
        (cond
          [(eof-object? line) #f]
          [(string=? "" (string-trim line)) (loop)]
          [(f line) => values]
          [else (loop)])))))

;; call-with-backward-lines : path ((-> (or/c string eof)) -> X) -> X
;; Hands `proc' a reader of the file's non-blank lines from the LAST backwards, one
;; a call, reading the file from its end in blocks and holding at most one block of
;; lines plus the partial line before it.
(define (call-with-backward-lines path proc)
  (define block 65536)
  (call-with-input-file path
    (lambda (in)
      ;; `ready': complete lines not yet handed out, newest first. `end': where the
      ;; unread part of the file ends. `tail': the bytes after the last newline of
      ;; the unread part — the start of a line whose end has been read.
      (define ready '())
      (define end (file-size path))
      (define tail #"")
      (define (refill!)
        (let loop ()
          (define start (max 0 (- end block)))
          (file-position in start)
          (define chunk (bytes-append (read-bytes (- end start) in) tail))
          (define pieces (regexp-split #rx#"\n" chunk))
          (set! end start)
          ;; the first piece may be partial unless the chunk starts the file
          (cond
            [(zero? start) (set! tail #"") (set! ready (reverse pieces))]
            [else (set! tail (car pieces)) (set! ready (reverse (cdr pieces)))])
          (when (and (null? ready) (positive? end)) (loop))))
      (define (next)
        (let loop ()
          (cond
            [(pair? ready)
             (define line (bytes->string/utf-8 (car ready) #\?))
             (set! ready (cdr ready))
             (if (string=? "" (string-trim line)) (loop) line)]
            [(zero? end) eof]
            [else (refill!) (loop)])))
      (proc next))))

;; last-line-where : path (string -> (or/c X #f)) -> (or/c X #f)
;; The first non-#f answer of `f' over the file's lines, from the LAST backwards,
;; reading only as far as it.
(define (last-line-where path f)
  (call-with-backward-lines path
    (lambda (next)
      (let loop ()
        (define line (next))
        (cond
          [(eof-object? line) #f]
          [(f line) => values]
          [else (loop)])))))

;; --- Build numbers (st-6gv) ----------------------------------------------------
;; A build's number is its 1-based position among the readable builds of the whole
;; history, pruned ones included (history-prune! keeps the count it dropped in a
;; header line). It used to be COUNTED at every read, which meant reading every line
;; to number the last one. A line written since st-6gv carries its number, assigned
;; at append as one more than the newest build's, so a reader working back from the
;; end knows each build's number without counting. A line without one — written
;; before this — is numbered from its neighbour: one less than the next newer
;; build's, or, when it is the newest line of all, by the old count. The two rules
;; agree wherever both apply, so a history that is part numbered and part not reads
;; the same forward and backward. Additive, like 'project: no version bump.

(define (entry-number e)
  (define n (hash-ref e 'number #f))
  (and (exact-positive-integer? n) n))

;; count-builds : path -> exact-nonnegative-integer
;; The number of the newest build by counting: the header's pruned count plus every
;; readable build line. Reads the whole log a line at a time; the fallback for a log
;; whose newest line carries no number.
(define (count-builds f)
  (call-with-input-file f
    (lambda (in)
      (for/fold ([n (pruned-count-of f)]) ([line (in-lines in 'linefeed)])
        (if (and (not (string=? "" (string-trim line))) (line->entry line)) (add1 n) n)))))

;; for-each-entry-backward : path (hash exact-positive-integer -> any) -> void
;; `proc' is handed each readable build's entry and number, newest first, and walks
;; on while it returns true.
(define (for-each-entry-backward f proc)
  (call-with-backward-lines f
    (lambda (next)
      (let loop ([newer #f])
        (define line (next))
        (unless (eof-object? line)
          (define e (line->entry line))
          (cond
            [(not e) (loop newer)]
            [else
             (define n (or (entry-number e)
                           (if newer (sub1 newer) (count-builds f))))
             (when (proc e n) (loop n))]))))))

;; for-each-entry-forward : path (hash exact-positive-integer -> any) -> void
;; Every readable build's entry and number, oldest first.
(define (for-each-entry-forward f proc)
  (call-with-input-file f
    (lambda (in)
      (for/fold ([n (pruned-count-of f)] #:result (void)) ([line (in-lines in 'linefeed)])
        (define e (and (not (string=? "" (string-trim line))) (line->entry line)))
        (cond
          [(not e) n]
          [else
           (define number (or (entry-number e) (add1 n)))
           (proc e number)
           number])))))

;; history-last-number : path-string -> (or/c exact-positive-integer #f)
;; The newest readable build's number; #f for an empty or missing history. Reads the
;; log's end, and all of it only when that line predates numbering.
(define (history-last-number state-dir)
  (define f (history-file state-dir))
  (and (file-exists? f)
       (let ([found #f])
         (for-each-entry-backward f (lambda (_e n) (set! found n) #f))
         found)))

;; history-append! : path-string symbol graph string (listof trace-record)
;;                   [#:project symbol] -> string
;; Append one build to the log (creating .stelis/ as needed), storing the topology
;; snapshot and each record's keyed maps as blocks. Returns the graph-hash it
;; recorded. Append-only: existing lines are never rewritten.
;;
;; The snapshot needs no envelope of its own — no 'version or 'graph-hash beside
;; the payload — because the version is a field INSIDE the snapshot value
;; (model.rkt's GRAPH-SNAPSHOT-VERSION) and the hash is the filename, verifiable by
;; re-hashing the bytes rather than by trusting a field that sits next to them.
(define (history-append! state-dir target g epoch records
                         #:project [project LEGACY-PROJECT]
                         #:recorded-at [recorded-at (current-seconds)])
  (define h (block-put! state-dir (graph->drisl g)))
  (make-directory* state-dir)
  (define number (add1 (or (history-last-number state-dir) (history-pruned-count state-dir))))
  (call-with-output-file (history-file state-dir) #:exists 'append
    (lambda (o)
      ;; one build per line: `write' emits no interior newlines for these
      ;; symbol/string/list values, so line-oriented reading can skip a single
      ;; corrupt build without losing the rest.
      (write (hash 'version HISTORY-VERSION
                   'project project
                   'number number
                   'target target
                   'graph-hash h
                   'epoch epoch
                   'recorded-at recorded-at
                   'records (for/list ([r (in-list records)])
                              (externalize-keyed state-dir (trace-record->datum r))))
             o)
      (newline o)))
  h)

;; --- Keyed maps as blocks (st-1e5) --------------------------------------------
;; A record's two keyed layers — output-key-hashes and input-key-hashes — used to
;; ride INLINE in the log line, so every build that re-produced `notes/` rewrote a
;; line naming every species even when none of them moved. They now live in the
;; block store and the line names them by CID, so two builds that observed the same
;; map share one block.
;;
;; The swap happens at SERIALIZATION, not in the struct: trace-record still carries
;; real maps, so no reader — delta.rkt, --moved-keys, explain — learns about blocks.
;; trace.rkt stays pure (DESIGN: effects at the boundary); the state directory is
;; history's business, and this is the only place that knows both.
;;
;; The datum positions come FROM trace.rkt (KEYED-DATUM-POSITIONS), which owns the
;; shape — counting them here would be a second copy of a fact that already has an
;; owner, and swapping the two would mislabel an input map as an output one with no
;; contract downstream to catch it.

(define (update-positions datum positions f)
  (for/list ([x (in-list datum)] [i (in-naturals)])
    (if (memv i positions) (f x) x)))

;; Each (artifact . pairs) entry becomes (artifact . "<cid>"). The block is exactly
;; keyed-block.rkt's, so for a 'dir output this CID is the SAME string as the
;; artifact's recorded digest — the map is stored once no matter which side names it.
;;
;; A failure to store falls back to writing the pairs INLINE, the pre-st-1e5 shape
;; the reader still accepts. This runs AFTER a build has already succeeded, so the
;; one thing it must not do is lose the record: a producer that emitted a duplicate
;; key (keyed-block refuses it) or a disk that filled would otherwise take the whole
;; build's history with it, which is a far worse outcome than a fat log line.
(define (externalize-keyed state-dir datum)
  (update-positions datum KEYED-DATUM-POSITIONS
                    (lambda (entries)
                      (for/list ([e (in-list entries)])
                        (cons (car e)
                              (with-handlers ([exn:fail? (lambda (_) (cdr e))])
                                ;; every block of the map's tree; the root's CID names it
                                (car (for/list ([b (in-list (keyed-tree-blocks (cdr e)))])
                                       (block-put! state-dir b)))))))))

;; The inverse. Tolerant of BOTH shapes on purpose: a pre-st-1e5 line carries its
;; pairs inline and is read as-is, so the accumulated history survives the change
;; without a HISTORY-VERSION bump — which would have discarded the very timeline
;; this layer exists to keep.
;;
;; AN UNRESOLVABLE BLOCK IS MARKED, NOT DROPPED, and the distinction is load-bearing.
;; Dropping the entry would make the artifact look UNOBSERVED at that build, which is
;; the signature of a cache-skip — and build-key-delta reads that as 'not-produced,
;; i.e. "nothing moved", an ANSWER. So a single lost block for the LAST build would
;; make `--moved-keys` exit 0 in silence for a build where keys did move, and a
;; caller that rebuilds per key would publish stale output. That is precisely the
;; failure delta.rkt's 'no-basis exists to prevent. `unresolved-keys` says "there was
;; an observation here and we cannot read it", which history-key-observations turns
;; into a refusal. A map a reader chose NOT to read (see `current-keyed') carries the
;; same mark: observed, not read, never an answer.
(define unresolved-keys 'unresolved)

;; Which maps a load reads: 'all, 'none, or one artifact's. The rest are marked.
(define current-keyed (make-parameter 'all))
(define (read-keyed? artifact)
  (define k (current-keyed))
  (or (eq? k 'all) (eq? k artifact)))

;; internalize-keyed : path-string (symbol -> boolean) -> (datum -> datum)
;; The reader for one record datum: each keyed entry's map is read from its block
;; when `read?' says so, and marked otherwise.
(define ((internalize-keyed state-dir [read? read-keyed?]) datum)
  (update-positions datum KEYED-DATUM-POSITIONS
                    (lambda (entries)
                      (for/list ([e (in-list entries)])
                        (cons (car e)
                              (if (read? (car e))
                                  (or (resolve-keyed state-dir (cdr e)) unresolved-keys)
                                  unresolved-keys))))))

;; resolve-keyed : path-string any -> (or/c (listof (cons string string)) #f)
(define (resolve-keyed state-dir v)
  (cond
    [(list? v) v]                                   ; pre-st-1e5: inline pairs
    [(string? v) (let ([pairs (tree-pairs state-dir v)])
                   (and pairs (sort pairs string<? #:key car)))]
    [else #f]))

;; tree-pairs : path-string string -> (or/c (listof (cons string string)) #f)
;; A keyed map stored as a tree (keyed-block.rkt, st-ml9.7), gathered back into its
;; pairs, unsorted; #f when any block of it is missing or unreadable — a map with a
;; bucket gone is not a smaller map, and must not read as one.
(define (tree-pairs state-dir cid)
  (define v (decode state-dir cid))
  (cond
    [(not v) #f]
    [(keyed-node? v)
     (let loop ([children (keyed-node-links v)] [acc '()])
       (cond
         [(null? children) acc]
         [else (define sub (tree-pairs state-dir (car children)))
               (and sub (loop (cdr children) (append sub acc)))]))]
    [(hash? v) (for/list ([(k x) (in-hash v)]) (cons (intern k) (intern x)))]
    [else #f]))

;; Within one load, each block is decoded once and each key or value string is held
;; once. A keyed artifact's map barely changes from build to build, so a history of
;; them is mostly the same strings and, once chunked, mostly the same buckets. Decoded
;; afresh, salishsea's ~180 days/ maps of 4,398 entries took `--history days` to 788 MB
;; and an OOM kill on Fly; interning brought it to ~540 MB while those maps are still
;; the flat blocks written before chunking (st-ml9.7), which share nothing by CID and
;; age out under retention. One timeline query also reads only its artifact's maps
;; (history-fold's #:keyed).
(define current-decoded (make-parameter #f))
(define current-interned (make-parameter #f))
;; the blocks the build being read has reached, for history-fold to keep
(define current-touched (make-parameter #f))
(define (decode state-dir cid)
  (define memo (current-decoded))
  (define touched (current-touched))
  (when touched (set-add! touched cid))
  (if memo
      (hash-ref! memo cid (lambda () (block-ref state-dir cid)))
      (block-ref state-dir cid)))
(define (intern s)
  (define table (current-interned))
  (if (and table (string? s)) (hash-ref! table s s) s))

;; One load's scope: the block memo, the string table, and which maps it reads.
(define (call-with-load keyed thunk)
  (parameterize ([current-decoded (make-hash)] [current-interned (make-hash)]
                 [current-keyed keyed] [current-touched #f])
    (thunk)))

;; --- Loading builds, bounded ---------------------------------------------------
;; Each reader below holds what it answers with and nothing more. The log is never
;; read whole into memory; the one reader that walks all of it (history-fold) hands
;; each build to its caller and lets go of it.

;; history-fold : path-string (build-record X -> X) X [#:keyed (or/c 'all 'none symbol)]
;;                -> X
;; Fold `proc' over every readable build, oldest first, holding one at a time. A
;; line that fails to parse or carries a wrong version is dropped; the surrounding
;; builds still load. Missing history ⇒ `init'. #:keyed says which keyed maps are
;; read from their blocks (default none — a caller wanting an artifact's per-key
;; timeline names it, and nothing else's maps are decoded to look at it).
(define (history-fold state-dir proc init #:keyed [keyed 'none])
  (define f (history-file state-dir))
  (cond
    [(not (file-exists? f)) init]
    [else
     (call-with-load keyed
       (lambda ()
         (define acc init)
         ;; The block memo is trimmed as the fold goes: after each build, the
         ;; blocks it did not reach are dropped. Consecutive maps of one artifact
         ;; share nearly every bucket (keyed-block.rkt's tree), which is the
         ;; sharing the memo exists for; a block no recent build names is one
         ;; the stream has moved past. Unbounded, the memo held every map ever
         ;; decoded, and a streamed timeline cost what the list did.
         (define memo (current-decoded))
         (define touched (mutable-set))
         (parameterize ([current-touched touched])
           (for-each-entry-forward
            f (lambda (e n)
                (define br (entry->build-record e (internalize-keyed state-dir) n))
                (when br (set! acc (proc br acc)))
                (for ([cid (in-list (hash-keys memo))] #:unless (set-member? touched cid))
                  (hash-remove! memo cid))
                (set-clear! touched))))
         acc))]))

;; history-load : path-string [#:keyed-for symbol] -> (listof build-record)
;; Every readable build, in append (build) order, keyed maps read — the whole
;; history as a list, for a reader that genuinely needs all of it (tests; a small
;; project's state). A reader of one artifact's timeline passes #:keyed-for, so only
;; that artifact's maps are decoded; a reader of recent builds wants history-tail.
(define (history-load state-dir #:keyed-for [keyed-for #f])
  (reverse (history-fold state-dir cons '() #:keyed (or keyed-for 'all))))

;; history-last : path-string [#:keyed (or/c 'all 'none symbol)] -> (or/c build-record #f)
;; The most recent readable build — "what did the last build do?". #f when the
;; history is empty or wholly unreadable. Reads from the end, one build.
(define (history-last state-dir #:keyed [keyed 'all])
  (define f (history-file state-dir))
  (and (file-exists? f)
       (call-with-load keyed
         (lambda ()
           (define found #f)
           (for-each-entry-backward
            f (lambda (e n)
                (set! found (entry->build-record e (internalize-keyed state-dir) n))
                (not found)))
           found))))

;; history-find : path-string exact-positive-integer [#:keyed ...] -> (or/c build-record #f)
;; The build numbered `number', or #f when the history has no readable build by it
;; (expired, never reached, or unreadable). Reads from the end down to it.
(define (history-find state-dir number #:keyed [keyed 'none])
  (define f (history-file state-dir))
  (and (file-exists? f)
       (call-with-load keyed
         (lambda ()
           (define found #f)
           (for-each-entry-backward
            f (lambda (e n)
                (cond
                  [(= n number) (set! found (entry->build-record e (internalize-keyed state-dir) n)) #f]
                  [(< n number) #f]
                  [else #t])))
           found))))

;; history-tail : path-string exact-nonnegative-integer [#:basis? boolean]
;;                -> (listof build-record)
;; The last k readable builds, oldest first, keyed maps read. With #:basis?, before
;; them, the older builds that hold each of those maps' artifacts' LATEST earlier
;; map — the basis a delta at the oldest of the k is taken against (delta.rkt diffs
;; a production with the previous one, however long ago that was) — with that map
;; read and every other map of theirs marked. The walk back stops as soon as every
;; artifact has its basis, or at the start of the log for one first produced within
;; the k. For a reader that shows only recent builds, the operator build log: a full
;; load decoded every build's maps, and on salishsea's Fly machine, 370 builds of a
;; 4,400-key days/ map took the engine from 136 MB to 528 MB after every build.
(define (history-tail state-dir k #:basis? [basis? #f])
  (define f (history-file state-dir))
  (cond
    [(not (file-exists? f)) '()]
    [else
     (call-with-load 'all
       (lambda ()
         (define tail '())
         (define prior '())
         (define taken 0)
         ;; the artifacts whose basis is still wanted
         (define needed (mutable-seteq))
         (for-each-entry-backward
          f (lambda (e n)
              (cond
                [(< taken k)
                 (define br (entry->build-record e (internalize-keyed state-dir) n))
                 (when br
                   (set! taken (add1 taken))
                   (set! tail (cons br tail))
                   (when basis?
                     (for* ([rec (in-list (build-record-records br))]
                            [pair (in-list (trace-record-keyed rec))])
                       (set-add! needed (car pair)))))
                 #t]
                [(set-empty? needed) #f]
                [else
                 ;; an older build: read the maps still wanted, mark the rest
                 (define hit? #f)
                 (define (wanted? a)
                   (and (set-member? needed a)
                        (begin (set-remove! needed a) (set! hit? #t) #t)))
                 (define br (entry->build-record e (internalize-keyed state-dir wanted?) n))
                 (when (and br hit?) (set! prior (cons br prior)))
                 (not (set-empty? needed))])))
         (append prior tail)))]))

;; --- Publish receipts (st-8x1) ------------------------------------------------
;; What the engine cannot know: whether a build's data actually went LIVE. The
;; publish decision happens downstream, in beeatlas's nightly / note-write
;; scripts, after the build record is written — so those scripts report the
;; outcome BACK, as an append-only sidecar beside the history. A receipt is the
;; publish path writing forward-only operational state next to the engine's
;; record of itself: a writer outside the graph, ADR 0013's 'authoritative
;; reading, and the deliberate first step into st-s8i's "what was published vs
;; what was built" — one self-reported bit plus its stage, no destination
;; observation.
;;
;; A receipt names its build POSITIVELY: build number AND that build's source
;; epoch. The number alone is a live index, not an identity — history-load skips
;; unreadable and stale-version lines, so a HISTORY-VERSION bump renumbers the
;; survivors (v2→v3 already happened once) and position-only receipts would
;; silently reattach to the wrong builds. Readers JOIN on both and drop
;; mismatches; a dropped receipt renders as absence, which stays honest.
;;   version     : PUBLISH-RECEIPT-VERSION
;;   build       : exact-positive-integer — 1-based position at write time
;;   build-epoch : string — that build's SOURCE_DATE_EPOCH (the join key)
;;   outcome     : 'published | 'not-published
;;   stage       : string — how far the run got ("integration-gate",
;;                 "site-root-absent", "merge-swap", …) so an expected skip
;;                 never renders like the alarm this feature exists for
;;   path        : 'nightly | 'note — which publish contract reported
(define PUBLISH-RECEIPT-VERSION 1)
(define (publish-log-file state-dir) (build-path state-dir "publish.log"))

;; publish-receipts-load : path-string -> (listof hash)
;; All readable receipts, append order. Unreadable or other-version lines are
;; skipped, never errors — same tolerance as the history log itself.
(define (publish-receipts-load state-dir)
  (define f (publish-log-file state-dir))
  (cond
    [(not (file-exists? f)) '()]
    [else
     (for*/list ([line (in-list (file->lines f))]
                 #:unless (string=? "" (string-trim line))
                 [v (in-value (with-handlers ([exn:fail? (lambda (_e) #f)])
                                (read (open-input-string line))))]
                 #:when (and (hash? v)
                             (equal? PUBLISH-RECEIPT-VERSION (hash-ref v 'version #f))))
       v)]))

;; publish-receipt-append! : path-string exact-positive-integer string
;;                           (or/c 'published 'not-published) string
;;                           (or/c 'nightly 'note) -> void
;; Append one receipt. Validation (range, epoch match, double-mark refusal) is
;; the CALLER's business — main.rkt's --mark-publish — because it needs the
;; loaded history; this module only owns the format.
(define (publish-receipt-append! state-dir build build-epoch outcome stage path)
  (make-directory* state-dir)
  (call-with-output-file (publish-log-file state-dir) #:exists 'append
    (lambda (o)
      (write (hash 'version PUBLISH-RECEIPT-VERSION
                   'build build
                   'build-epoch build-epoch
                   'outcome outcome
                   'stage stage
                   'path path)
             o)
      (newline o))))

;; history-last-source-report : path-string symbol -> (or/c source-report? #f)
;; The source report `task' produced on its MOST RECENT RUN (st-8bj) — the basis
;; for the prospective, history-flavored 'boundary line in --explain/--why. Walks
;; builds newest-first for the first one in which the task actually RAN (outcome
;; 'ok — a boundary that was blocked/skipped that build wrote no receipt and must
;; not mask an older run's report), and returns that run's report; #f when it wrote
;; none (re-ingested, or not a probing boundary) or the task has never run.
;; Deliberately that run's report, not the last NON-#f one anywhere: if the most
;; recent RUN re-ingested, a stale "unchanged" from before would misreport the
;; current source state. Reads from the end, stopping at that run.
(define (history-last-source-report state-dir task)
  (define f (history-file state-dir))
  (and (file-exists? f)
       (call-with-load 'none
         (lambda ()
           (define found #f)
           (for-each-entry-backward
            f (lambda (e n)
                (define br (entry->build-record e (internalize-keyed state-dir) n))
                (define rec
                  (and br (findf (lambda (rec) (and (eq? (trace-record-task rec) task)
                                                    (eq? (trace-record-outcome rec) 'ok)))
                                 (build-record-records br))))
                (cond
                  [rec (set! found (trace-record-source-report rec)) #f]
                  [else #t])))
           found))))

;; observe-timeline : path-string symbol (trace-record -> alist) (nat any trace-record -> X)
;;                    (or/c 'none symbol) -> (listof X)
;; The shared walk behind both timelines: over the history (by build number), pull
;; `artifact's entry from each record via `field', and build a point with `make'
;; from (build-index, that entry's value, the producing record). A build whose
;; producer cache-skipped carries no entry, so it contributes no point — which is
;; what makes consecutive points genuine re-productions. Streams: only the points
;; are held, and only the maps `keyed' names are read — none for a hash timeline,
;; which never looks inside a map.
(define (observe-timeline state-dir artifact field make keyed)
  (reverse
   (history-fold state-dir
                 (lambda (br acc)
                   (for/fold ([acc acc]) ([rec (in-list (build-record-records br))])
                     (define pair (assq artifact (field rec)))
                     (if pair
                         (cons (make (build-record-number br) (cdr pair) rec) acc)
                         acc)))
                 '()
                 #:keyed keyed)))

;; history-observations : path-string symbol -> (listof observation)
;; Every point at which `artifact' was (re)produced, in build order — its
;; content-hash timeline. Consecutive points with the same hash mark genuine
;; re-productions to identical content; a differing hash marks a change.
(define (history-observations state-dir artifact)
  (observe-timeline state-dir artifact trace-record-output-hashes observation 'none))

;; history-key-fold : path-string symbol (key-observation X -> X) X -> X
;; The per-key timeline as a STREAM: `proc' is handed each point — the artifact's
;; full (part -> hash) map at a build that observed it, with the producing or
;; consuming record — oldest first, and only the fold's accumulator is held. A
;; point whose map could not be read carries history's mark (a non-list) in place
;; of the map; the printer says so for that build and the list-building reader
;; below refuses the whole timeline. For a reader that needs each map only against
;; the one before it (`--history <artifact>`), so a timeline of thousands of maps of
;; thousands of keys costs two maps at a time rather than all of them.
(define (history-key-fold state-dir artifact proc init)
  (history-fold state-dir
                (lambda (br acc)
                  (for/fold ([acc acc]) ([rec (in-list (build-record-records br))])
                    (define pair (assq artifact (trace-record-keyed rec)))
                    (if pair
                        (proc (key-observation (build-record-number br) (cdr pair) rec) acc)
                        acc)))
                init
                #:keyed artifact))

;; history-key-observations : path-string symbol [#:last exact-positive-integer]
;;                            -> (listof key-observation)
;; The per-KEY timeline for a keyed artifact — per-path for a 'dir output, per-
;; column for a db-relation output, or per-key for a keyed STORE input (the notes
;; store, st-2k9): its full (part -> hash) map at each build that observed it, in
;; build order. Diffing consecutive maps yields exactly the parts that changed. '()
;; for an artifact that never recorded a per-part layer.
;;
;; #:last n reads only the NEWEST n points, from the end of the log, stopping
;; there (st-6gv): a delta at the last build is two maps, a baseline is one, and
;; neither needs the thousands before them read. The whole timeline is for a
;; reader that walks it (key-blame).
;;
;; ONE LOST OBSERVATION POISONS THE WHOLE TIMELINE, deliberately. If any recorded
;; point cannot be read back (its block is missing, damaged, or mis-addressed), this
;; returns '() rather than the surviving subset. A thinned timeline is worse than no
;; timeline: build-key-delta reads a gap at the build in question as 'not-produced —
;; "nothing moved" — and a caller that rebuilds per key would then skip work it
;; needed to do. '() instead yields 'no-basis, which refuses and makes the caller
;; rebuild in full. Losing precision is recoverable; answering "nothing moved" when
;; something did is not, and the next build re-records the timeline anyway.
(define (history-key-observations state-dir artifact #:last [n #f])
  (define points
    (if n
        (last-key-observations state-dir artifact n)
        (reverse (history-key-fold state-dir artifact cons '()))))
  (if (for/or ([p (in-list points)]) (not (list? (key-observation-keys p))))
      '()
      points))

;; last-key-observations : path-string symbol exact-positive-integer -> (listof key-observation)
;; The newest n points of the artifact's per-key timeline, oldest first, read from
;; the end of the log and no further.
(define (last-key-observations state-dir artifact n)
  (define f (history-file state-dir))
  (cond
    [(not (file-exists? f)) '()]
    [else
     (call-with-load artifact
       (lambda ()
         (define points '())
         (for-each-entry-backward
          f (lambda (e number)
              (define br (entry->build-record e (internalize-keyed state-dir) number))
              (when br
                ;; a build's records in reverse, so consing restores build order
                (for ([rec (in-list (reverse (build-record-records br)))])
                  (define pair (assq artifact (trace-record-keyed rec)))
                  (when pair
                    (set! points (cons (key-observation number (cdr pair) rec) points)))))
              (< (length points) n)))
         (if (> (length points) n) (take-right points n) points)))]))

;; trace-record-keyed : trace-record -> (listof (cons symbol (listof (cons string string))))
;; A record's per-key observations from BOTH sides — outputs the task produced and
;; keyed STORE inputs it consumed. An artifact is only ever one or the other (a
;; store has no producer; an output has no store resolver), so the two never
;; collide and a plain append is the union.
(define (trace-record-keyed r)
  (append (trace-record-output-key-hashes r)
          (trace-record-input-key-hashes r)))

;; history-graph : path-string string -> (or/c list #f)
;; The persisted topology snapshot (graph->datum shape) for a graph-hash, or #f
;; when absent/unreadable — reconstruct a past build's graph without Racket.
;; A v2 snapshot (`<sha1>.rktd`, a versioned s-expression) is not looked up at all
;; and so reads as absent, which is the same answer a corrupt block gives.
(define (history-graph state-dir h)
  (define v (block-ref state-dir h))
  (and v (drisl->graph-datum v)))

;; --- Parsing (a bad line is a miss, never an error) ---------------------------

;; line->entry : string -> (or/c hash #f)
;; A history line as its datum, or #f when it doesn't parse or is another version.
(define (line->entry line)
  (define e (with-handlers ([exn:fail? (lambda (_) #f)])
              (read (open-input-string line))))
  (and (hash? e)
       (equal? (hash-ref e 'version #f) HISTORY-VERSION)
       (list? (hash-ref e 'records #f))
       e))

;; entry->build-record : hash (datum -> datum) exact-positive-integer -> (or/c build-record #f)
;; `internalize' turns each record datum's keyed entries back into maps (or marks).
(define (entry->build-record e internalize number)
  (with-handlers ([exn:fail? (lambda (_) #f)])
    (build-record (hash-ref e 'target)
                  (hash-ref e 'graph-hash #f)
                  (hash-ref e 'epoch #f)
                  (for/list ([r (in-list (hash-ref e 'records))])
                    (datum->trace-record (internalize r)))
                  number)))

;; --- Retention (st-ml9.7) -----------------------------------------------------
;; A project that builds every few minutes can't keep every build: salishsea's Fly
;; volume would fill within months. So a project may set a retention, and after each
;; build the history drops the builds recorded longer ago than that, then deletes the
;; blocks no remaining build names.
;;
;; What is dropped is always a PREFIX, and the count of builds dropped is kept in a
;; header line at the top of the log, so every remaining build keeps its NUMBER: a
;; publish receipt joins on number and epoch (st-8x1), and renumbering the survivors
;; would silently detach every receipt from its build. Readers past the horizon get
;; the existing honest answers: the first remaining production of an artifact has
;; no prior, so a delta there is 'no-basis, which refuses rather than claims nothing
;; moved.
;;
;; The age of a build is the wall-clock time its line was recorded ('recorded-at).
;; That is the one clock in this file, and it is housekeeping only: freshness never
;; reads it, any more than it reads the sequence. A line written before retention
;; existed carries no time; it counts as older than every dated line, so it goes
;; once the first dated build has aged out.

;; The header line: a hash with 'pruned, never a build (it has no 'records).
(define (pruned-header? e) (and (hash? e) (hash-has-key? e 'pruned)))

;; lines-pruned-count : (listof string) -> exact-nonnegative-integer
(define (lines-pruned-count lines)
  (or (for*/first ([line (in-list lines)]
                   [e (in-value (with-handlers ([exn:fail? (lambda (_) #f)])
                                  (read (open-input-string line))))]
                   #:when (pruned-header? e))
        (let ([n (hash-ref e 'pruned 0)]) (and (exact-nonnegative-integer? n) n)))
      0))

;; history-pruned-count : path-string -> exact-nonnegative-integer
;; How many builds retention has dropped from the front of the history: the build
;; numbers below the first remaining one.
(define (history-pruned-count state-dir)
  (define f (history-file state-dir))
  (if (file-exists? f) (pruned-count-of f) 0))

;; pruned-count-of : path -> exact-nonnegative-integer
;; The header's count. The header, when there is one, is the first line:
;; history-prune! writes it there.
(define (pruned-count-of f)
  (or (first-line-where f (lambda (line) (lines-pruned-count (list line)))) 0))

;; history-prune! : path-string exact-nonnegative-integer [#:now exact-integer]
;;                  -> (values exact-nonnegative-integer exact-nonnegative-integer)
;; Drop every build recorded more than `keep-seconds' before `now' (and the undated
;; ones before them), then delete the blocks no remaining line names. Returns how
;; many builds and how many blocks went. The log is rewritten whole, beside itself,
;; and renamed over, so a reader sees the old history or the new one.
;; Retention prunes in BATCHES: only once the oldest build is `slack' past the
;; horizon, and then everything aged out goes at once. Pruning rewrites the whole
;; log and re-reads every surviving line to find the blocks they still name, so at a
;; build every five minutes, pruning the one build that aged out each time cost a
;; full rewrite and parse per build; with a day's slack it costs one a day. The log
;; then holds between `keep-seconds' and `keep-seconds' + `slack' of builds.
;; Whether to prune at all is read off the oldest dated line alone.
(define (history-prune! state-dir keep-seconds #:now [now (current-seconds)]
                        #:slack [slack 0])
  (define f (history-file state-dir))
  (define horizon (- now keep-seconds))
  (define (recorded-at line)
    (define e (with-handlers ([exn:fail? (lambda (_) #f)]) (read (open-input-string line))))
    (and (hash? e) (not (pruned-header? e))
         (let ([t (hash-ref e 'recorded-at #f)]) (and (exact-integer? t) t))))
  (cond
    [(not (file-exists? f)) (values 0 0)]
    ;; nothing has aged out by more than the slack: no build before the first dated
    ;; one can go (an undated line goes only once a dated one before the horizon
    ;; does), and the first dated one is not old enough
    [(let ([oldest (first-line-where f recorded-at)])
       (or (not oldest) (>= oldest (- horizon slack))))
     (values 0 0)]
    [else (prune-before! state-dir f horizon recorded-at)]))

;; prune-before! : the rewrite itself, reading the log a line at a time.
;; The aged-out PREFIX ends at the last line recorded before the horizon that no line
;; inside the window precedes; everything up to it goes (undated lines among them
;; too). Only a prefix, never "the last old line anywhere" (st-ml9.10): recorded-at
;; is wall clock, and a clock stepped backwards — NTP, a machine reset on redeploy —
;; can date a line earlier than its predecessors. Taking the last old line would then
;; drop the newer, correctly dated builds before it. So the first line inside the
;; window ends the prefix, and an out-of-order old line after it stays.
(define (prune-before! state-dir f horizon recorded-at)
  (define tmp (path-add-extension f #".pruning"))
  (define-values (pruned dropped)
    (call-with-input-file f
      (lambda (in)
        (call-with-output-file tmp #:exists 'truncate
          (lambda (o)
            ;; the count already dropped, from the old header; the new header is
            ;; written once the prefix has been read and the count it adds is known
            (define pruned
              (or (first-line-where f (lambda (line) (lines-pruned-count (list line)))) 0))
            ;; scan the prefix: lines up to the first inside the window
            (let loop ([pending '()] [gone 0])
              (define line (read-line in 'linefeed))
              (cond
                [(eof-object? line)
                 ;; every line was old or undated: the undated ones after the last
                 ;; old line stay
                 (write-header o pruned gone)
                 (for ([l (in-list (reverse pending))]) (write-string l o) (newline o))
                 (values pruned gone)]
                [(string=? "" (string-trim line)) (loop pending gone)]
                [(pruned-header? (with-handlers ([exn:fail? (lambda (_) #f)])
                                   (read (open-input-string line))))
                 (loop pending gone)]
                [else
                 (define t (recorded-at line))
                 (cond
                   [(and t (>= t horizon))
                    ;; the first line inside the window: it, the undated lines
                    ;; since the last old one, and everything after it stay
                    (write-header o pruned gone)
                    (for ([l (in-list (reverse pending))]) (write-string l o) (newline o))
                    (write-string line o) (newline o)
                    (copy-port in o)
                    (values pruned gone)]
                   ;; an old line: it and the undated lines before it go
                   [t (loop '() (+ gone (length (filter line->entry pending))
                                   (if (line->entry line) 1 0)))]
                   ;; undated: goes only if an old line follows it
                   [else (loop (cons line pending) gone)])])))))))
  (rename-file-or-directory tmp f #t)
  (values dropped (collect-blocks! state-dir f)))

(define (write-header o pruned gone)
  (write (hash 'version HISTORY-VERSION 'pruned (+ pruned gone)) o)
  (newline o))

;; collect-blocks! : path-string path -> exact-nonnegative-integer
;; Delete every block that none of the log `f''s lines reaches, as its topology snapshot or as a
;; keyed map (with the blocks below a chunked map's root); return how many. Only
;; history writes blocks (blockstore.rkt), so a block no build reaches is one nothing
;; can.
(define (collect-blocks! state-dir f)
  (define roots
    (call-with-input-file f
      (lambda (in)
        (for*/fold ([named (set)]) ([line (in-lines in 'linefeed)]
                                    [e (in-value (line->entry line))]
                                    #:when e)
          (for*/fold ([named (let ([g (hash-ref e 'graph-hash #f)]) (if (string? g) (set-add named g) named))])
                     ([r (in-list (hash-ref e 'records))]
                      [pos (in-list KEYED-DATUM-POSITIONS)]
                      #:when (and (list? r) (< pos (length r)) (list? (list-ref r pos)))
                      [entry (in-list (list-ref r pos))]
                      #:when (and (pair? entry) (string? (cdr entry))))
            (set-add named (cdr entry)))))))
  ;; a chunked map's root names its buckets, and they theirs
  (define named
    (let walk ([todo (set->list roots)] [named roots])
      (cond
        [(null? todo) named]
        [else
         (define v (block-ref state-dir (car todo)))
         (define children
           (if (keyed-node? v)
               (filter (lambda (c) (not (set-member? named c))) (keyed-node-links v))
               '()))
         (walk (append children (cdr todo)) (for/fold ([n named]) ([c children]) (set-add n c)))])))
  (define dir (build-path state-dir "blocks"))
  (if (directory-exists? dir)
      (for/sum ([b (in-list (directory-list dir))]
                #:unless (set-member? named (path->string b)))
        (delete-file (build-path dir b))
        1)
      0))
