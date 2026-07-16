#lang racket/base

;; Input-addressed task caching (st-d44.3), with reasons (st-yg7.1): the cache
;; layer answers not just WHETHER a task must run but WHY, as a pure `decision'
;; record — the provenance seed that --explain (slice 2) prints and the Datalog
;; layer (slice 3) turns into facts.
;;
;; The cache is DERIVED, DISPOSABLE state — a content-addressed sidecar per task
;; in a dedicated state dir (.stelis/cache/, gitignored). It is format-VERSIONED:
;; an entry whose version doesn't match, or that fails to parse, is treated as a
;; cache MISS (rebuild + rewrite), never an error. So the format can churn freely
;; while we iterate — a change just invalidates the cache. Deleting the dir only
;; forces a full rebuild. (Uses sha1, built-in; proper content-addressing / sha256
;; can swap in later without changing the shape.)

(require file/sha1
         racket/file
         racket/set
         racket/format
         racket/string
         "model.rkt"
         "tree-digest.rkt")

(provide (struct-out decision)
         (struct-out snapshot)
         (struct-out output-delta)
         (struct-out build-env)
         make-build-env
         env-resolve
         env-output-paths
         check-output-paths-resolvable
         input-snapshot
         input-store-snapshot
         artifact-key-parts
         output-snapshot
         output-snapshot+keys
         compare-outputs
         read-versioned
         read-cache-entry
         decide
         decision+snapshot
         task-decision
         cache-hit?
         cache-store!)

;; v3: output hashes recorded per artifact (st-8ig, early cutoff), so a rerun
;; can say whether it rebuilt to identical content. v2 entries read as misses.
(define CACHE-VERSION 3)

(define (file-sha1 path) (call-with-input-file path sha1))
(define (string-sha1 s) (sha1 (open-input-bytes (string->bytes/utf-8 s))))

;; --- Decisions ----------------------------------------------------------------

;; Why a task will run or may be skipped. Pure data, so it can be printed or
;; emitted as Datalog facts without re-deriving anything.
;;   verdict : 'run | 'skip
;;   reason  : 'boundary             ingestion — its real input is the external
;;                                   world, never content-skipped
;;           | 'inputs-unresolvable  not content-addressable; details name the
;;                                   artifacts (e.g. duckdb relations, tokens)
;;           | 'no-cache-entry       never built here (or unreadable/old entry)
;;           | 'recipe-changed       the command itself changed
;;           | 'input-changed        details name the changed/added/removed inputs
;;           | 'output-missing       details name the missing output paths
;;           | 'cached               (verdict 'skip) inputs unchanged, outputs exist
;;   details : reason-specific list; '() when there is nothing to name
(struct decision (verdict reason details) #:transparent)

;; What the cache compares: the task's recipe plus each input's content hash.
;;   recipe-hash  : string
;;   input-hashes : immutable hash, artifact name -> content hash
(struct snapshot (recipe-hash input-hashes) #:transparent)

;; What early cutoff observed (st-8ig): after a task reran, how its rebuilt
;; outputs compare to the previous build's recorded hashes. 'identical is the
;; cutoff point — downstream tasks see unchanged inputs and cache-skip
;; naturally; nothing has to suppress them.
;;   status  : 'identical | 'changed
;;   details : artifact names — everything verified identical, or what changed
(struct output-delta (status details) #:transparent)

;; --- The build environment ------------------------------------------------------

;; How artifacts resolve to content and where build state lives — the trio every
;; cache-aware entry point needs, bundled so it travels as one value.
;;   resolve          : (symbol export-dir -> (or/c path-string #f))
;;                      where a FILE artifact lives (also used to place/verify
;;                      outputs). db-relations/tokens/externals have no path -> #f.
;;   export-dir       : path-string — the explicit output destination
;;   cache-dir        : path-string — the derived, disposable sidecar dir
;;   resolve-relation : (symbol -> (or/c string #f)) — a db-relation's content
;;                      hash, or #f when it can't be read (st-d5d). #f (the whole
;;                      slot) means "no relation resolver": relations then read as
;;                      inputs-unresolvable, exactly the pre-st-d5d behaviour.
;;   resolve-relation-columns : (symbol -> (or/c (listof (cons string string)) #f))
;;                      — a db-relation's PER-COLUMN observation (st-7vz): sorted
;;                      (part -> "digest:count") pairs, or #f. Output-side only
;;                      (the attribute-level refinement recorded on the trace); the
;;                      cache decision never consults it. #f slot = no per-column
;;                      layer (tests, callers that don't want it).
;;   resolve-store-keys : (symbol -> (or/c (listof (cons string string)) #f))
;;                      — a keyed 'file STORE's per-KEY observation (st-2k9): sorted
;;                      (key -> "digest:count") pairs, or #f. The ingestion-boundary
;;                      analog of resolve-relation-columns for an authoritative
;;                      SQLite store (the notes store, keyed by canonical_name); #f
;;                      for a plain file. Like the columns slot, the cache decision
;;                      never consults it — it feeds the per-key delta/observation.
(struct build-env
  (resolve export-dir cache-dir
   resolve-relation resolve-relation-columns resolve-store-keys)
  #:transparent)

;; make-build-env : (symbol export-dir -> path?) path-string path-string
;;                  [#:resolve-relation (or/c (symbol -> (or/c string #f)) #f)]
;;                  [#:resolve-relation-columns
;;                     (or/c (symbol -> (or/c (listof (cons string string)) #f)) #f)]
;;                  [#:resolve-store-keys
;;                     (or/c (symbol -> (or/c (listof (cons string string)) #f)) #f)]
;;                  -> build-env?
;; Keyword constructor so callers that don't content-address relations/stores
;; (tests, the file-only paths) needn't mention the slots.
(define (make-build-env resolve export-dir cache-dir
                        #:resolve-relation [resolve-relation #f]
                        #:resolve-relation-columns [resolve-relation-columns #f]
                        #:resolve-store-keys [resolve-store-keys #f])
  (build-env resolve export-dir cache-dir
             resolve-relation resolve-relation-columns resolve-store-keys))

;; env-resolve : build-env? symbol -> (or/c path-string #f)
(define (env-resolve env a)
  ((build-env-resolve env) a (build-env-export-dir env)))

;; env-output-paths : build-env? task? -> (listof path-string)
;; The task's resolvable output paths (unresolvable outputs drop out).
(define (env-output-paths env t)
  (filter values (map (lambda (o) (env-resolve env o)) (task-outputs t))))

;; check-output-paths-resolvable : graph (listof symbol) build-env? -> void
;; Guard (st-6qc): every 'file or 'dir output produced by a task in `tasks' must
;; resolve to a path under `env'. A #f path for such an output is a modeling gap —
;; it silently drops out of env-output-paths, so the artifact is never checked for
;; presence nor hashed for cutoff, and the task can "succeed"/cache without its
;; output verified. Tokens, db-relations, and externals have no single path and are
;; exempt. Raise (naming task → artifact) instead of letting the gap pass quietly.
(define (check-output-paths-resolvable g tasks env)
  (define offenders
    (for*/list ([name (in-list tasks)]
                [t (in-value (hash-ref (graph-tasks g) name))]
                [o (in-list (task-outputs t))]
                #:when (let ([a (hash-ref (graph-artifacts g) o #f)])
                         (and a (memq (artifact-kind a) '(file dir))
                              (not (env-resolve env o)))))
      (format "  ~a → ~a" name o)))
  (unless (null? offenders)
    (error 'stelis
           (string-append
            "unresolvable file/dir output(s) — the path resolver returns #f, so they "
            "would be built but never verified. Add them to the resolver:\n"
            (string-join offenders "\n")))))

;; input-snapshot : graph symbol (symbol -> (or/c path-string #f))
;;                  [(or/c (symbol -> (or/c string #f)) #f)]
;;                  -> (or/c snapshot? decision?)
;; Hash the task's recipe and each input's content. Each input is hashed by its
;; artifact KIND: a file by its bytes; a db-relation by `resolve-relation' (its
;; DuckDB digest, st-d5d); anything else (tokens, externals) has no content hash.
;; Returns a 'run decision instead of a snapshot when the task can never be
;; content-skipped: 'boundary tasks (ingestion must re-run), and tasks with an
;; input that isn't content-addressable here ('inputs-unresolvable). With
;; resolve-relation #f, db-relations fall through to unresolvable (pre-st-d5d).
(define (input-snapshot g name resolve [resolve-relation #f])
  (define t (hash-ref (graph-tasks g) name))
  (cond
    [(eq? (task-kind t) 'boundary) (decision 'run 'boundary '())]
    [else
     (define pairs
       (for/list ([in (in-list (task-inputs t))])
         (cons in (input-hash g in resolve resolve-relation))))
     (define unresolvable
       (sort (for/list ([kv (in-list pairs)] #:unless (cdr kv)) (car kv)) symbol<?))
     (if (pair? unresolvable)
         (decision 'run 'inputs-unresolvable unresolvable)
         (snapshot (string-sha1 (~s (task-invoke t)))
                   (make-immutable-hash pairs)))]))

;; input-hash : graph symbol (symbol -> path?) (or/c (symbol -> string?) #f)
;;              -> (or/c string #f)
;; One input's content hash, by artifact kind, or #f if not content-addressable:
;; a file by its bytes; a dir by its order-independent tree digest (st-cly); a
;; db-relation by `resolve-relation'. #f (absent/unresolvable) forces a rerun.
(define (input-hash g in resolve resolve-relation)
  (define a (hash-ref (graph-artifacts g) in #f))
  (cond
    [(and a (eq? (artifact-kind a) 'db-relation))
     (and resolve-relation (resolve-relation in))]
    [(and a (eq? (artifact-kind a) 'dir))
     (define p (resolve in))
     (and p (tree-digest p))]
    [else
     (define p (resolve in))
     (and p (file-exists? p) (file-sha1 p))]))

;; output-snapshot+keys : graph symbol build-env?
;;   -> (values (listof (cons symbol string))                        ; digests
;;              (listof (cons symbol (listof (cons string string))))) ; per-'dir keys
;; The task's cutoff-eligible outputs, hashed after a run, at two granularities in
;; ONE walk. First value: each DERIVED artifact that resolves to existing content,
;; as a sorted (artifact -> digest) alist — the cutoff/observation basis. Second
;; value: for each 'dir output, its sorted (relative-path -> hash) pairs — the
;; per-KEY observations (st-6dv). A 'dir's digest is the roll-up of exactly those
;; pairs (digest-of-pairs), so the two granularities can never disagree; a 'file
;; has a digest but no keys, and tokens/relations have no path and drop out.
;; Authoritative outputs are excluded — cutoff applies only to derived state
;; (forward-only writes are effects; "rebuilt to identical bytes" isn't a claim we
;; make about them).
(define (output-snapshot+keys g name env)
  (define t (hash-ref (graph-tasks g) name))
  (define observed
    (for*/list ([out (in-list (task-outputs t))]
                [a (in-value (hash-ref (graph-artifacts g) out #f))]
                #:when (and a (eq? 'derived (artifact-provenance a)))
                [obs (in-value (observe-output a out env))]
                #:when obs)
      (list out (car obs) (cdr obs))))
  (values
   (sort (for/list ([o (in-list observed)]) (cons (car o) (cadr o)))
         symbol<? #:key car)
   (sort (for/list ([o (in-list observed)] #:when (caddr o)) (cons (car o) (caddr o)))
         symbol<? #:key car)))

;; artifact-key-parts : symbol symbol build-env? -> (or/c (listof (cons string string)) #f)
;; The ONE kind -> per-key-layer dispatch (st-lg0): an artifact's live per-key
;; (part -> value) map, or #f when it has none / can't be read. Every reader — the
;; live delta side (delta-explain live-key-map), the recorded output observation
;; (observe-output), the boundary input snapshot (input-store-snapshot) — goes
;; through here, so a new keyed kind is added in exactly one place.
;;   'dir         (path -> content-hash)     via tree-hashes
;;   'db-relation (column -> "digest:count") via resolve-relation-columns
;;   'file        (key -> "digest:count")    via resolve-store-keys — a keyed store;
;;                #f for a plain file (no per-key layer)
;;   else (token/external) -> #f
(define (artifact-key-parts a kind env)
  (case kind
    [(dir) (let ([p (env-resolve env a)]) (and p (tree-hashes p)))]
    [(db-relation) (let ([rrc (build-env-resolve-relation-columns env)]) (and rrc (rrc a)))]
    [(file) (let ([rsk (build-env-resolve-store-keys env)]) (and rsk (rsk a)))]
    [else #f]))

;; observe-output : artifact symbol build-env?
;;   -> (or/c (cons string (or/c (listof (cons string string)) #f)) #f)
;; One derived output's observation: (digest . parts), or #f when there's nothing
;; to hash. The PARTS come from the shared artifact-key-parts; the DIGEST stays
;; kind-specific here because it is NOT always a roll-up of the parts:
;;   'dir         digest-of-pairs over its parts (they agree by construction)
;;   'db-relation the row-coherent resolve-relation digest — per-column parts alone
;;                CANNOT reconstruct it (a cross-row value swap, st-d5d); taken here
;;                AFTER the producer released the db lock
;;   'file        the bytes hash (a plain file has no parts)
;;   else (token/external) -> #f
(define (observe-output a out env)
  (define parts (artifact-key-parts out (artifact-kind a) env))
  (case (artifact-kind a)
    [(dir) (and parts (cons (digest-of-pairs parts) parts))]
    [(db-relation)
     (define rr (build-env-resolve-relation env))
     (define h (and rr (rr out)))
     (and h (cons h parts))]
    [else
     (define p (env-resolve env out))
     (and p (file-exists? p) (cons (file-sha1 p) parts))]))

;; input-store-snapshot : graph symbol build-env?
;;   -> (listof (cons symbol (listof (cons string string))))
;; The ingestion-boundary CRUD-snapshot (st-2k9): each PRODUCERLESS keyed leaf the
;; task consumes, as (artifact -> its per-key map), sorted. Such a leaf (the notes
;; store — an authoritative 'file keyed by canonical_name) is observed by nobody
;; else: a 'dir/db-relation input is recorded by its PRODUCER as an output, so we
;; skip anything with a producer to avoid double-observing. Parts come from the
;; shared artifact-key-parts (st-lg0), so this covers any future producerless keyed
;; kind, not just stores; '() when nothing qualifies.
(define (input-store-snapshot g name env)
  (define t (hash-ref (graph-tasks g) name))
  (sort (for*/list ([in (in-list (task-inputs t))]
                    #:unless (producer-of g in)
                    [a (in-value (hash-ref (graph-artifacts g) in #f))]
                    [parts (in-value (and a (artifact-key-parts in (artifact-kind a) env)))]
                    #:when parts)
          (cons in parts))
        symbol<? #:key car))

;; output-snapshot : graph symbol build-env? -> (listof (cons symbol string))
;; The artifact-level digests alone — the cutoff basis and cache entry (role
;; UNCHANGED by st-6dv). The per-key layer rides only on the trace/history.
(define (output-snapshot g name env)
  (define-values (digests _keys) (output-snapshot+keys g name env))
  digests)

;; compare-outputs : (or/c hash? #f) (listof (cons symbol string))
;;                   -> (or/c output-delta? #f)
;; The pure cutoff question: given the previous cache entry and a fresh
;; output-snapshot, did the rerun rebuild to identical content? #f when there
;; is no basis to compare — no prior entry, or nothing hashable this run.
(define (compare-outputs entry fresh)
  (and entry (pair? fresh)
       (let ([changed (changed-names
                       (make-immutable-hash (hash-ref entry 'output-hashes '()))
                       (make-immutable-hash fresh))])
         (if (null? changed)
             (output-delta 'identical (map car fresh))
             (output-delta 'changed changed)))))

;; --- The cache sidecar ----------------------------------------------------------

(define (cache-file cache-dir name)
  (build-path cache-dir (format "~a.rktd" name)))

;; read-versioned : path-string exact-integer -> (or/c hash? #f)
;; The shared shape for versioned state files (cache sidecars, the build
;; trace): #f for missing, unparseable, or other-version — never an error.
(define (read-versioned f version)
  (and (file-exists? f)
       (let ([e (with-handlers ([exn:fail? (lambda (_) #f)])
                  (call-with-input-file f read))])
         (and (hash? e) (equal? (hash-ref e 'version #f) version) e))))

;; read-cache-entry : path-string symbol -> (or/c hash? #f)
(define (read-cache-entry cache-dir name)
  (read-versioned (cache-file cache-dir name) CACHE-VERSION))

;; cache-store! : path-string symbol (or/c snapshot? #f) (listof path-string)
;;                (listof (cons symbol string)) -> void
;; With snap = #f (a boundary task, or inputs that aren't content-addressable,
;; e.g. dbt-build's relations) the entry still records the output hashes, so
;; the NEXT rerun has a cutoff basis; the absent recipe/input hashes can never
;; produce a skip — `decide' is only ever reached when a snapshot exists.
(define (cache-store! cache-dir name snap output-paths out-hashes)
  (make-directory* cache-dir)
  (call-with-output-file (cache-file cache-dir name) #:exists 'replace
    (lambda (o)
      (write (hash 'version CACHE-VERSION
                   'recipe-hash (and snap (snapshot-recipe-hash snap))
                   ;; sorted alist, not a hash: same state -> same file bytes
                   'input-hashes (if snap
                                     (sort (hash->list (snapshot-input-hashes snap))
                                           symbol<? #:key car)
                                     '())
                   'outputs (map (lambda (p) (if (path? p) (path->string p) p))
                                 output-paths)
                   'output-hashes out-hashes) ; output-snapshot: already sorted
             o))))

;; --- The decision core ----------------------------------------------------------

;; decide : snapshot? (or/c hash? #f) (listof path-string) -> decision?
;; The pure core: compare a fresh snapshot against the recorded entry (#f = no
;; usable entry), given which recorded outputs are missing on disk. The first
;; applicable reason wins; 'output-missing is checked after the content reasons
;; so a content change is always reported as the content change.
(define (decide snap entry missing-outputs)
  (cond
    [(not entry) (decision 'run 'no-cache-entry '())]
    [(not (equal? (hash-ref entry 'recipe-hash #f) (snapshot-recipe-hash snap)))
     (decision 'run 'recipe-changed '())]
    [else
     (define changed
       (changed-names (make-immutable-hash (hash-ref entry 'input-hashes '()))
                      (snapshot-input-hashes snap)))
     (cond
       [(pair? changed)          (decision 'run 'input-changed changed)]
       [(pair? missing-outputs)  (decision 'run 'output-missing missing-outputs)]
       [else                     (decision 'skip 'cached '())])]))

;; names whose hash differs between the two maps, or that exist in only one
(define (changed-names old new)
  (sort (for/list ([name (in-set (set-union (list->set (hash-keys old))
                                            (list->set (hash-keys new))))]
                   #:unless (equal? (hash-ref old name #f) (hash-ref new name #f)))
          name)
        symbol<?))

;; decision+snapshot : graph symbol build-env?
;;                     -> (values decision? (or/c snapshot? #f))
;; The full question, IO included: would `name' run right now, and why? Also
;; returns the snapshot (when one exists) so an executor that goes on to run
;; the task can store it without re-hashing.
(define (decision+snapshot g name env)
  (define t (hash-ref (graph-tasks g) name))
  (define snap (input-snapshot g name (lambda (a) (env-resolve env a))
                               (build-env-resolve-relation env)))
  (if (decision? snap)
      (values snap #f)
      (values (decide snap (read-cache-entry (build-env-cache-dir env) name)
                      (missing (env-output-paths env t)))
              snap)))

;; task-decision : graph symbol build-env? -> decision?
(define (task-decision g name env)
  (define-values (d _snap) (decision+snapshot g name env))
  d)

;; cache-hit? : path-string symbol snapshot? (listof path-string) -> boolean
;; Thin wrapper over `decide' for callers that only need the verdict.
(define (cache-hit? cache-dir name snap output-paths)
  (eq? 'skip (decision-verdict
              (decide snap (read-cache-entry cache-dir name) (missing output-paths)))))

;; a recorded output is present if it exists as a file OR a directory ('dir
;; outputs, st-cly, resolve to a directory that file-exists? would miss).
(define (missing output-paths)
  (for/list ([p (in-list output-paths)]
             #:unless (or (file-exists? p) (directory-exists? p)))
    p))
