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
         "trace.rkt")

(provide (struct-out build-record)
         (struct-out observation)
         (struct-out key-observation)
         history-append!
         history-load
         history-last
         history-observations
         history-key-observations
         history-graph)

;; Bump when the envelope or record shape changes; older lines then read as
;; (skipped) misses, exactly like a stale cache sidecar. v2: records carry
;; per-key observations (st-6dv).
(define HISTORY-VERSION 2)

;; One build's persisted result.
;;   target     : symbol — the artifact this build was asked to produce
;;   graph-hash : string — the topology it ran against (graph-digest); the full
;;                snapshot lives once under graphs/<graph-hash>.rktd
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
(define (graphs-dir state-dir)   (build-path state-dir "graphs"))
(define (graph-file state-dir h) (build-path (graphs-dir state-dir) (format "~a.rktd" h)))

;; history-append! : path-string symbol graph string (listof trace-record) -> string
;; Append one build to the log (creating .stelis/ as needed) and, once per
;; distinct topology, write its graph snapshot under graphs/<hash>.rktd. Returns
;; the graph-hash it recorded. Append-only: existing lines are never rewritten.
(define (history-append! state-dir target g epoch records)
  (define h (graph-digest g))
  (write-graph-snapshot! state-dir g h)
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
                   'records (map trace-record->datum records))
             o)
      (newline o)))
  h)

;; write-graph-snapshot! : path-string graph string -> void
;; Persist the topology snapshot once per graph-hash (content-addressed, so a
;; repeat is a no-op). Never overwrites an existing snapshot.
(define (write-graph-snapshot! state-dir g h)
  (define f (graph-file state-dir h))
  (unless (file-exists? f)
    (make-directory* (graphs-dir state-dir))
    (call-with-output-file f #:exists 'error
      (lambda (o) (write (hash 'version GRAPH-SNAPSHOT-VERSION
                               'graph-hash h
                               'snapshot (graph->datum g))
                         o)))))

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
                 [br (in-value (line->build-record line))]
                 #:when br)
       br)]))

;; history-last : path-string -> (or/c build-record #f)
;; The most recent readable build — "what did the last build do?". #f when the
;; history is empty or wholly unreadable.
(define (history-last state-dir)
  (define builds (history-load state-dir))
  (and (pair? builds) (last builds)))

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
;; The per-KEY timeline for a 'dir artifact (or per-COLUMN for a db-relation):
;; its full (part -> hash) map at each build that (re)produced it, in build order.
;; Diffing consecutive maps yields exactly the parts that changed. '() for an
;; artifact that never recorded a per-part layer.
(define (history-key-observations state-dir artifact)
  (observe-timeline state-dir artifact trace-record-output-key-hashes key-observation))

;; history-graph : path-string string -> (or/c list #f)
;; The persisted topology snapshot (graph->datum shape) for a graph-hash, or #f
;; when absent/unreadable — reconstruct a past build's graph without Racket.
(define (history-graph state-dir h)
  (define e (read-versioned (graph-file state-dir h) GRAPH-SNAPSHOT-VERSION))
  (and e (hash-ref e 'snapshot #f)))

;; --- Parsing (a bad line is a miss, never an error) ---------------------------

(define (line->build-record line)
  (define e (with-handlers ([exn:fail? (lambda (_) #f)])
              (read (open-input-string line))))
  (and (hash? e)
       (equal? (hash-ref e 'version #f) HISTORY-VERSION)
       (list? (hash-ref e 'records #f))
       (with-handlers ([exn:fail? (lambda (_) #f)])
         (build-record (hash-ref e 'target)
                       (hash-ref e 'graph-hash #f)
                       (hash-ref e 'epoch #f)
                       (map datum->trace-record (hash-ref e 'records))))))
