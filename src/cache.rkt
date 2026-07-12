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
         "model.rkt")

(provide (struct-out decision)
         (struct-out snapshot)
         (struct-out output-delta)
         (struct-out build-env)
         env-resolve
         env-output-paths
         input-snapshot
         output-snapshot
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

;; How artifacts resolve to paths and where build state lives — the trio every
;; cache-aware entry point needs, bundled so it travels as one value.
;;   resolve    : (symbol export-dir -> (or/c path-string #f))
;;   export-dir : path-string — the explicit output destination
;;   cache-dir  : path-string — the derived, disposable sidecar dir
(struct build-env (resolve export-dir cache-dir) #:transparent)

;; env-resolve : build-env? symbol -> (or/c path-string #f)
(define (env-resolve env a)
  ((build-env-resolve env) a (build-env-export-dir env)))

;; env-output-paths : build-env? task? -> (listof path-string)
;; The task's resolvable output paths (unresolvable outputs drop out).
(define (env-output-paths env t)
  (filter values (map (lambda (o) (env-resolve env o)) (task-outputs t))))

;; input-snapshot : graph symbol (symbol -> (or/c path-string #f))
;;                  -> (or/c snapshot? decision?)
;; Hash the task's recipe and each input file. Returns a 'run decision instead
;; of a snapshot when the task can never be content-skipped: 'boundary tasks
;; (ingestion must re-run, or later use a boundary stamp), and tasks with an
;; input that is not a resolvable, existing file ('inputs-unresolvable).
(define (input-snapshot g name resolve)
  (define t (hash-ref (graph-tasks g) name))
  (cond
    [(eq? (task-kind t) 'boundary) (decision 'run 'boundary '())]
    [else
     (define pairs
       (for/list ([in (in-list (task-inputs t))])
         (define p (resolve in))
         (cons in (and p (file-exists? p) (file-sha1 p)))))
     (define unresolvable
       (sort (for/list ([kv (in-list pairs)] #:unless (cdr kv)) (car kv)) symbol<?))
     (if (pair? unresolvable)
         (decision 'run 'inputs-unresolvable unresolvable)
         (snapshot (string-sha1 (~s (task-invoke t)))
                   (make-immutable-hash pairs)))]))

;; output-snapshot : graph symbol build-env? -> (listof (cons symbol string))
;; Content hashes of the task's cutoff-eligible outputs, taken after a run: the
;; DERIVED artifacts that resolve to an existing file, as a sorted alist.
;; Authoritative outputs are excluded — cutoff applies only to derived state
;; (forward-only writes are effects; "rebuilt to identical bytes" is not a
;; claim we make about them). Tokens/relations have no file to hash and drop
;; out, so a task like dbt-build is judged on the outputs we CAN verify.
(define (output-snapshot g name env)
  (define t (hash-ref (graph-tasks g) name))
  (sort
   (for*/list ([out (in-list (task-outputs t))]
               [a (in-value (hash-ref (graph-artifacts g) out #f))]
               #:when (and a (eq? 'derived (artifact-provenance a)))
               [p (in-value (env-resolve env out))]
               #:when (and p (file-exists? p)))
     (cons out (file-sha1 p)))
   symbol<? #:key car))

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
  (define snap (input-snapshot g name (lambda (a) (env-resolve env a))))
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

(define (missing output-paths)
  (for/list ([p (in-list output-paths)] #:unless (file-exists? p)) p))
