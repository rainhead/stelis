#lang racket/base

;; Determinism harness (st-d44.6). DESIGN calls this a day-one property: build the
;; same snapshot twice and compare hashes. Watch DuckDB parallelism, floating
;; point, and spatial joins — any of which can make an "identical" rebuild differ.
;;
;; We build the plan (or a runnable suffix) twice into SEPARATE output dirs, hash
;; the target file each time, and compare. Because ingestion is held fixed (we run
;; from the derived tail), this tests determinism of the DERIVED core given fixed
;; inputs — exactly what "ingestion outside the hermetic boundary" means.
;;
;; Uses sha1 (built-in, zero-dep) purely to compare two files we control; proper
;; content-addressing (sha256) arrives with the caching slice (st-d44.3).

(require file/sha1
         racket/file
         "model.rkt"
         "exec.rkt"
         "tree-digest.rkt")

(provide verify-determinism)

(define (file-sha1 path) (call-with-input-file path sha1))

;; digest the built target whether it is a single file or a directory TREE ('dir
;; artifacts, st-cly): a dir compares by its order-independent tree digest.
(define (target-digest p)
  (cond
    [(directory-exists? p) (tree-digest p)]
    [(file-exists? p) (file-sha1 p)]
    [else (error 'verify-determinism "target was not produced: ~a" p)]))

;; total bytes under a path — the file's own size, or the sum for a directory.
(define (path-bytes p)
  (if (directory-exists? p)
      (for/sum ([f (in-directory p)] #:when (file-exists? f)) (file-size f))
      (file-size p)))

;; verify-determinism : graph symbol (hash symbol->runtime)
;;   #:from (or/c symbol #f) #:extra-env (listof (cons string string))
;;   #:seed (listof (cons path-string string)) #:out-file string -> boolean
;; Returns #t iff both builds produce a byte-identical target file. `extra-env'
;; is injected into BOTH builds' task env (e.g. the ADR-0004 SOURCE_DATE_EPOCH
;; clock) — it must be constant across the two builds or the harness is moot.
;; `seed' is (src . basename) pairs copied into each fresh build dir BEFORE the
;; build: for a --from suffix (st-dtq), these are the suffix's external @export
;; inputs its scripts read from EXPORT_DIR, held fixed so the harness measures the
;; suffix's own determinism given identical upstream bytes.
(define (verify-determinism g target runtimes
                            #:from [from #f]
                            #:extra-env [extra-env '()]
                            #:seed [seed '()]
                            #:out-file [out-file "occurrences.db"])
  (define-values (ordered _pruned) (plan g target))
  (define to-run
    (cond
      [from (or (member from ordered)
                (error 'verify-determinism "--from ~a not in plan for ~a" from target))]
      [else ordered]))

  (define (build! label)
    (define dir (make-temporary-directory))
    (printf "\n═══ build ~a → ~a ═══\n" label dir)
    (for ([s (in-list seed)])
      (copy-file (car s) (build-path dir (cdr s)) #t))
    (run-plan g to-run runtimes
              #:env (cons (cons "EXPORT_DIR" (path->string dir)) extra-env))
    (build-path dir out-file))

  (define f1 (build! 1))
  (define f2 (build! 2))
  (define h1 (target-digest f1))
  (define h2 (target-digest f2))
  (printf "\nbuild #1  digest ~a  (~a bytes)\n" h1 (path-bytes f1))
  (printf "build #2  digest ~a  (~a bytes)\n" h2 (path-bytes f2))
  (cond
    [(string=? h1 h2)
     (printf "\n✓ DETERMINISTIC — ~a is byte-identical across builds\n" out-file)
     #t]
    [else
     (printf "\n✗ NONDETERMINISTIC — ~a differs between builds (sizes ~a vs ~a)\n"
             out-file (path-bytes f1) (path-bytes f2))
     #f]))
