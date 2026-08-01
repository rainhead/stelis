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
         racket/string
         "model.rkt"
         "cache.rkt"    ; read-versioned — the shared versioned-file reader
         "blockstore.rkt"
         (only-in "keyed-block.rkt" keyed-block)
         "trace.rkt")

(provide (struct-out build-record)
         (struct-out observation)
         (struct-out key-observation)
         history-append!
         history-load
         history-last
         history-last-source-report
         history-observations
         history-key-observations
         history-graph)

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
(struct build-record (target graph-hash epoch records) #:transparent)

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

;; history-append! : path-string symbol graph string (listof trace-record) -> string
;; Append one build to the log (creating .stelis/ as needed), storing the topology
;; snapshot and each record's keyed maps as blocks. Returns the graph-hash it
;; recorded. Append-only: existing lines are never rewritten.
;;
;; The snapshot needs no envelope of its own — no 'version or 'graph-hash beside
;; the payload — because the version is a field INSIDE the snapshot value
;; (model.rkt's GRAPH-SNAPSHOT-VERSION) and the hash is the filename, verifiable by
;; re-hashing the bytes rather than by trusting a field that sits next to them.
(define (history-append! state-dir target g epoch records)
  (define h (block-put! state-dir (graph->drisl g)))
  (make-directory* state-dir)
  (call-with-output-file (history-file state-dir) #:exists 'append
    (lambda (o)
      ;; one build per line: `write' emits no interior newlines for these
      ;; symbol/string/list values, so line-oriented reading can skip a single
      ;; corrupt build without losing the rest.
      (write (hash 'version HISTORY-VERSION
                   'target target
                   'graph-hash h
                   'epoch epoch
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
                                (block-put! state-dir (keyed-block (cdr e)))))))))

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
  (update-positions datum KEYED-DATUM-POSITIONS
                    (lambda (entries)
                      (for/list ([e (in-list entries)])
                        (cons (car e)
                              (or (resolve-keyed state-dir (cdr e)) unresolved-keys))))))

;; resolve-keyed : path-string any -> (or/c (listof (cons string string)) #f)
(define (resolve-keyed state-dir v)
  (cond
    [(list? v) v]                                   ; pre-st-1e5: inline pairs
    [(string? v) (block->pairs (block-ref state-dir v))]
    [else #f]))

;; A keyed block is a DRISL map; the timeline wants sorted pairs, and sorting here
;; (rather than trusting the decoder) keeps the shape identical to what the inline
;; form produced, so delta.rkt cannot tell the two apart.
(define (block->pairs v)
  (and (hash? v)
       (sort (hash->list v) string<? #:key car)))

;; history-load : path-string -> (listof build-record)
;; Every readable build, in append (build) order. Missing history ⇒ '(). A line
;; that fails to parse or carries a wrong version is dropped; the surrounding
;; builds still load.
(define (history-load state-dir)
  (define f (history-file state-dir))
  (cond
    [(not (file-exists? f)) '()]
    [else
     (for*/list ([line (in-list (file->lines f))]
                 #:unless (string=? "" (string-trim line))
                 [br (in-value (line->build-record state-dir line))]
                 #:when br)
       br)]))

;; history-last : path-string -> (or/c build-record #f)
;; The most recent readable build — "what did the last build do?". #f when the
;; history is empty or wholly unreadable.
(define (history-last state-dir)
  (define builds (history-load state-dir))
  (and (pair? builds) (last builds)))

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
;; The shared walk behind both timelines: over the loaded history (1-based build
;; index), pull `artifact's entry from each record via `field', and build a point
;; with `make' from (build-index, that entry's value, the producing record). A
;; build whose producer cache-skipped carries no entry, so it contributes no
;; point — which is what makes consecutive points genuine re-productions.
(define (observe-timeline state-dir artifact field make)
  (for*/list ([(br i) (in-indexed (history-load state-dir))]
              [rec (in-list (build-record-records br))]
              [pair (in-value (assq artifact (field rec)))]
              #:when pair)
    (make (add1 i) (cdr pair) rec)))

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

(define (line->build-record state-dir line)
  (define e (with-handlers ([exn:fail? (lambda (_) #f)])
              (read (open-input-string line))))
  (and (hash? e)
       (equal? (hash-ref e 'version #f) HISTORY-VERSION)
       (list? (hash-ref e 'records #f))
       (with-handlers ([exn:fail? (lambda (_) #f)])
         (build-record (hash-ref e 'target)
                       (hash-ref e 'graph-hash #f)
                       (hash-ref e 'epoch #f)
                       (for/list ([r (in-list (hash-ref e 'records))])
                         (datum->trace-record (internalize-keyed state-dir r)))))))
