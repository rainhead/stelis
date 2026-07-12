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
         input-snapshot
         read-cache-entry
         decide
         task-decision
         cache-hit?
         cache-store!)

;; v2: recipe hash + per-input hashes stored separately (st-yg7.1), so a miss
;; can name its cause. v1 entries (combined fingerprint) read as misses.
(define CACHE-VERSION 2)

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

;; --- The cache sidecar ----------------------------------------------------------

(define (cache-file cache-dir name)
  (build-path cache-dir (format "~a.rktd" name)))

;; read-cache-entry : path-string symbol -> (or/c hash? #f)
;; #f for a missing, unparseable, or other-version entry — all just misses.
(define (read-cache-entry cache-dir name)
  (define f (cache-file cache-dir name))
  (and (file-exists? f)
       (let ([e (with-handlers ([exn:fail? (lambda (_) #f)])
                  (call-with-input-file f read))])
         (and (hash? e) (equal? (hash-ref e 'version #f) CACHE-VERSION) e))))

;; cache-store! : path-string symbol snapshot? (listof path-string) -> void
(define (cache-store! cache-dir name snap output-paths)
  (make-directory* cache-dir)
  (call-with-output-file (cache-file cache-dir name) #:exists 'replace
    (lambda (o)
      (write (hash 'version CACHE-VERSION
                   'recipe-hash (snapshot-recipe-hash snap)
                   ;; sorted alist, not a hash: same state -> same file bytes
                   'input-hashes (sort (hash->list (snapshot-input-hashes snap))
                                       symbol<? #:key car)
                   'outputs (map (lambda (p) (if (path? p) (path->string p) p))
                                 output-paths))
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
       (changed-inputs (make-immutable-hash (hash-ref entry 'input-hashes '()))
                       (snapshot-input-hashes snap)))
     (cond
       [(pair? changed)          (decision 'run 'input-changed changed)]
       [(pair? missing-outputs)  (decision 'run 'output-missing missing-outputs)]
       [else                     (decision 'skip 'cached '())])]))

;; names whose hash differs between the two maps, or that exist in only one
(define (changed-inputs old new)
  (sort (for/list ([name (in-set (set-union (list->set (hash-keys old))
                                            (list->set (hash-keys new))))]
                   #:unless (equal? (hash-ref old name #f) (hash-ref new name #f)))
          name)
        symbol<?))

;; task-decision : graph symbol (symbol -> (or/c path-string #f))
;;                 path-string (listof path-string) -> decision?
;; The full question, IO included: would `name' run right now, and why?
(define (task-decision g name resolve cache-dir output-paths)
  (define snap (input-snapshot g name resolve))
  (if (decision? snap)
      snap
      (decide snap (read-cache-entry cache-dir name) (missing output-paths))))

;; cache-hit? : path-string symbol snapshot? (listof path-string) -> boolean
;; Thin wrapper over `decide' for callers that only need the verdict.
(define (cache-hit? cache-dir name snap output-paths)
  (eq? 'skip (decision-verdict
              (decide snap (read-cache-entry cache-dir name) (missing output-paths)))))

(define (missing output-paths)
  (for/list ([p (in-list output-paths)] #:unless (file-exists? p)) p))
