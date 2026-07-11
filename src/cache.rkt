#lang racket/base

;; Input-addressed task caching (st-d44.3): skip a task whose inputs are
;; unchanged since it last produced its outputs.
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
         racket/string
         racket/format
         "model.rkt")

(provide input-fingerprint
         cache-hit?
         cache-store!)

(define CACHE-VERSION 1)

(define (file-sha1 path) (call-with-input-file path sha1))
(define (string-sha1 s) (sha1 (open-input-bytes (string->bytes/utf-8 s))))

;; input-fingerprint : graph symbol (symbol -> (or/c path-string #f)) -> (or/c string #f)
;; A content hash of the task's recipe plus each input file's hash. Returns #f
;; (NOT cacheable) when:
;;   - the task is a 'boundary (ingestion) node — its real input is the external
;;     world, which isn't content-addressable; ingestion must re-run (or later use
;;     a boundary stamp), never be content-skipped; or
;;   - any input is not a resolvable, existing file (e.g. duckdb relations, tokens).
(define (input-fingerprint g name resolve)
  (define t (hash-ref (graph-tasks g) name))
  (cond
    [(eq? (task-kind t) 'boundary) #f]
    [else (input-fingerprint* g t resolve)]))

(define (input-fingerprint* g t resolve)
  (define pairs
    (for/list ([in (in-list (task-inputs t))])
      (define p (resolve in))
      (and p (file-exists? p) (cons in (file-sha1 p)))))
  (cond
    [(andmap values pairs)
     (string-sha1
      (string-join
       (cons (~s (task-invoke t))                        ; recipe: change it -> new fp
             (sort (map (lambda (kv) (format "~a=~a" (car kv) (cdr kv))) pairs)
                   string<?))
       "\n"))]
    [else #f]))

(define (cache-file cache-dir name)
  (build-path cache-dir (format "~a.rktd" name)))

;; cache-hit? : path-string symbol string (listof path-string) -> boolean
;; True iff a same-version entry records this exact input fingerprint AND every
;; recorded output still exists on disk.
(define (cache-hit? cache-dir name input-fp output-paths)
  (define f (cache-file cache-dir name))
  (and (file-exists? f)
       (let ([e (with-handlers ([exn:fail? (lambda (_) #f)])
                  (call-with-input-file f read))])
         (and (hash? e)
              (equal? (hash-ref e 'version #f) CACHE-VERSION)
              (equal? (hash-ref e 'input-fp #f) input-fp)
              (andmap file-exists? output-paths)))))

;; cache-store! : path-string symbol string (listof path-string) -> void
(define (cache-store! cache-dir name input-fp output-paths)
  (make-directory* cache-dir)
  (call-with-output-file (cache-file cache-dir name) #:exists 'replace
    (lambda (o)
      (write (hash 'version CACHE-VERSION
                   'input-fp input-fp
                   'outputs (map (lambda (p) (if (path? p) (path->string p) p)) output-paths))
             o))))
