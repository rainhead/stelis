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
;; outgrows in-memory Datalog (DESIGN: defer it).

(require racket/file
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
         history-last
         history-last-source-report
         history-observations
         history-key-observations
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
;; sorted; '() when the dir is empty, missing, or wholly `project''s. Reads every
;; line regardless of version — a stale-version line is still a record of SOME
;; project's build, and a dir that holds one is still that project's dir.
(define (history-foreign-projects state-dir project)
  (define f (history-file state-dir))
  (cond
    [(not (file-exists? f)) '()]
    [else
     (define seen
       (for*/list ([line (in-list (file->lines f))]
                   [e (in-value (with-handlers ([exn:fail? (lambda (_) #f)])
                                  (read (open-input-string line))))]
                   #:when (and (hash? e) (not (pruned-header? e))))
         (hash-ref e 'project LEGACY-PROJECT)))
     (sort (remove-duplicates (remove* (list project) seen))
           symbol<?)]))

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
  (call-with-output-file (history-file state-dir) #:exists 'append
    (lambda (o)
      ;; one build per line: `write' emits no interior newlines for these
      ;; symbol/string/list values, so line-oriented reading can skip a single
      ;; corrupt build without losing the rest.
      (write (hash 'version HISTORY-VERSION
                   'project project
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
;; into a refusal.
(define unresolved-keys 'unresolved)

(define (internalize-keyed state-dir datum)
  (define only (current-keyed-for))
  (update-positions datum KEYED-DATUM-POSITIONS
                    (lambda (entries)
                      (for/list ([e (in-list entries)])
                        (cons (car e)
                              (if (and only (not (eq? (car e) only)))
                                  unresolved-keys
                                  (or (resolve-keyed state-dir (cdr e)) unresolved-keys)))))))

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
;; (#:keyed-for).
(define current-decoded (make-parameter #f))
(define current-interned (make-parameter #f))
(define (decode state-dir cid)
  (define memo (current-decoded))
  (if memo
      (hash-ref! memo cid (lambda () (block-ref state-dir cid)))
      (block-ref state-dir cid)))
(define (intern s)
  (define table (current-interned))
  (if (and table (string? s)) (hash-ref! table s s) s))

;; history-load : path-string [#:keyed-tail (or/c #f exact-nonnegative-integer)]
;;                -> (listof build-record)
;; Every readable build, in append (build) order. Missing history ⇒ '(). A line
;; that fails to parse or carries a wrong version is dropped; the surrounding
;; builds still load.
;;
;; #:keyed-tail k reads keyed maps from their blocks for the last k builds only,
;; and before them, for each artifact in each keyed position, only its LATEST map:
;; the basis a delta at the oldest of the k is taken against (delta.rkt diffs a
;; production with the previous one, however long ago that was). Every older map
;; is marked unresolved — observed, not read — so nothing can mistake it for an
;; answer. For a reader that shows only recent builds, the operator build log: a
;; full load decodes every build's maps, and on salishsea's Fly machine, 370
;; builds of a 4,400-key days/ map took the engine from 136 MB to 528 MB after
;; every build.
;;
;; #:keyed-for a reads keyed maps for artifact `a' only, leaving every other artifact's
;; marked unresolved: for a reader of one artifact's timeline, which would otherwise
;; decode every artifact's maps in every build to look at one.
(define (history-load state-dir #:keyed-tail [keyed-tail #f] #:keyed-for [keyed-for #f])
  (parameterize ([current-decoded (make-hash)] [current-interned (make-hash)] [current-keyed-for keyed-for])
    (history-load* state-dir keyed-tail)))

;; The one artifact whose maps a load reads, or #f for all.
(define current-keyed-for (make-parameter #f))

(define (history-load* state-dir keyed-tail)
  (define f (history-file state-dir))
  (cond
    [(not (file-exists? f)) '()]
    [else
     (define lines (file->lines f))
     (define pruned (lines-pruned-count lines))
     (define entries
       (for*/list ([line (in-list lines)]
                   #:unless (string=? "" (string-trim line))
                   [e (in-value (line->entry line))]
                   #:when e)
         e))
     (define cutoff (if keyed-tail (max 0 (- (length entries) keyed-tail)) 0))
     ;; newest first, so the first map met for an (artifact, position) before the
     ;; tail is its latest one
     (define seen (make-hash))
     (define (internalize-older r)
       (for/fold ([r r]) ([pos (in-list KEYED-DATUM-POSITIONS)])
         (update-positions
          r (list pos)
          (lambda (keyed)
            (for/list ([e (in-list keyed)])
              (define key (cons pos (car e)))
              (define only (current-keyed-for))
              (cond
                [(or (hash-ref seen key #f) (and only (not (eq? (car e) only)))) (cons (car e) unresolved-keys)]
                [else (hash-set! seen key #t)
                      (cons (car e) (or (resolve-keyed state-dir (cdr e)) unresolved-keys))]))))))
     (define n (length entries))
     (reverse
      (for*/list ([(e i) (in-indexed (in-list (reverse entries)))]
                  [br (in-value
                       (entry->build-record
                        e
                        (if (>= (- n 1 i) cutoff)
                            (lambda (r) (internalize-keyed state-dir r))
                            internalize-older)
                        (+ pruned (- n i))))]
                  #:when br)
        br))]))

;; history-last : path-string -> (or/c build-record #f)
;; The most recent readable build — "what did the last build do?". #f when the
;; history is empty or wholly unreadable.
(define (history-last state-dir)
  (define builds (history-load state-dir))
  (and (pair? builds) (last builds)))

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
;; current source state.
(define (history-last-source-report state-dir task)
  (let loop ([brs (reverse (history-load state-dir))])
    (cond
      [(null? brs) #f]
      [(findf (lambda (rec) (and (eq? (trace-record-task rec) task)
                                 (eq? (trace-record-outcome rec) 'ok)))
              (build-record-records (car brs)))
       => trace-record-source-report]
      [else (loop (cdr brs))])))

;; observe-timeline : path-string symbol (trace-record -> alist) (nat any trace-record -> X)
;;                    -> (listof X)
;; The shared walk behind both timelines: over the loaded history (by build
;; number), pull `artifact's entry from each record via `field', and build a point
;; with `make' from (build-index, that entry's value, the producing record). A
;; build whose producer cache-skipped carries no entry, so it contributes no
;; point — which is what makes consecutive points genuine re-productions.
(define (observe-timeline state-dir artifact field make)
  (for*/list ([br (in-list (history-load state-dir #:keyed-for artifact))]
              [rec (in-list (build-record-records br))]
              [pair (in-value (assq artifact (field rec)))]
              #:when pair)
    (make (build-record-number br) (cdr pair) rec)))

;; history-observations : path-string symbol -> (listof observation)
;; Every point at which `artifact' was (re)produced, in build order — its
;; content-hash timeline. Consecutive points with the same hash mark genuine
;; re-productions to identical content; a differing hash marks a change.
(define (history-observations state-dir artifact)
  (observe-timeline state-dir artifact trace-record-output-hashes observation))

;; history-key-observations : path-string symbol -> (listof key-observation)
;; The per-KEY timeline for a keyed artifact — per-path for a 'dir output, per-
;; column for a db-relation output, or per-key for a keyed STORE input (the notes
;; store, st-2k9): its full (part -> hash) map at each build that observed it, in
;; build order. Diffing consecutive maps yields exactly the parts that changed. '()
;; for an artifact that never recorded a per-part layer.
;;
;; ONE LOST OBSERVATION POISONS THE WHOLE TIMELINE, deliberately. If any recorded
;; point cannot be read back (its block is missing, damaged, or mis-addressed), this
;; returns '() rather than the surviving subset. A thinned timeline is worse than no
;; timeline: build-key-delta reads a gap at the build in question as 'not-produced —
;; "nothing moved" — and a caller that rebuilds per key would then skip work it
;; needed to do. '() instead yields 'no-basis, which refuses and makes the caller
;; rebuild in full. Losing precision is recoverable; answering "nothing moved" when
;; something did is not, and the next build re-records the timeline anyway.
(define (history-key-observations state-dir artifact)
  (define points (observe-timeline state-dir artifact trace-record-keyed key-observation))
  (if (for/or ([p (in-list points)]) (not (list? (key-observation-keys p))))
      '()
      points))

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
  (if (file-exists? f) (lines-pruned-count (file->lines f)) 0))

;; history-prune! : path-string exact-nonnegative-integer [#:now exact-integer]
;;                  -> (values exact-nonnegative-integer exact-nonnegative-integer)
;; Drop every build recorded more than `keep-seconds' before `now' (and the undated
;; ones before them), then delete the blocks no remaining line names. Returns how
;; many builds and how many blocks went. The log is rewritten whole, beside itself,
;; and renamed over, so a reader sees the old history or the new one.
(define (history-prune! state-dir keep-seconds #:now [now (current-seconds)])
  (define f (history-file state-dir))
  (cond
    [(not (file-exists? f)) (values 0 0)]
    [else
     (define lines (file->lines f))
     (define pruned (lines-pruned-count lines))
     (define body
       (for/list ([line (in-list lines)]
                  #:unless (string=? "" (string-trim line))
                  #:unless (pruned-header? (with-handlers ([exn:fail? (lambda (_) #f)])
                                             (read (open-input-string line)))))
         line))
     (define (recorded-at line)
       (define e (with-handlers ([exn:fail? (lambda (_) #f)]) (read (open-input-string line))))
       (and (hash? e) (let ([t (hash-ref e 'recorded-at #f)]) (and (exact-integer? t) t))))
     (define horizon (- now keep-seconds))
     ;; the last line recorded before the horizon; everything up to it goes
     (define last-old
       (for/last ([line (in-list body)] [i (in-naturals)]
                  #:when (let ([t (recorded-at line)]) (and t (< t horizon))))
         i))
     (cond
       [(not last-old) (values 0 0)]
       [else
        (define-values (gone kept) (split-at body (add1 last-old)))
        ;; numbers count the builds history-load reads, so only those
        (define dropped (for/sum ([line (in-list gone)]) (if (line->entry line) 1 0)))
        (define tmp (path-add-extension f #".pruning"))
        (call-with-output-file tmp #:exists 'truncate
          (lambda (o)
            (write (hash 'version HISTORY-VERSION 'pruned (+ pruned dropped)) o)
            (newline o)
            (for ([line (in-list kept)]) (write-string line o) (newline o))))
        (rename-file-or-directory tmp f #t)
        (values dropped (collect-blocks! state-dir kept))])]))

;; collect-blocks! : path-string (listof string) -> exact-nonnegative-integer
;; Delete every block that none of `lines' reaches, as its topology snapshot or as a
;; keyed map (with the blocks below a chunked map's root); return how many. Only
;; history writes blocks (blockstore.rkt), so a block no build reaches is one nothing
;; can.
(define (collect-blocks! state-dir lines)
  (define roots
    (for*/fold ([named (set)]) ([line (in-list lines)]
                                [e (in-value (line->entry line))]
                                #:when e)
      (for*/fold ([named (let ([g (hash-ref e 'graph-hash #f)]) (if (string? g) (set-add named g) named))])
                 ([r (in-list (hash-ref e 'records))]
                  [pos (in-list KEYED-DATUM-POSITIONS)]
                  #:when (and (list? r) (< pos (length r)) (list? (list-ref r pos)))
                  [entry (in-list (list-ref r pos))]
                  #:when (and (pair? entry) (string? (cdr entry))))
        (set-add named (cdr entry)))))
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
