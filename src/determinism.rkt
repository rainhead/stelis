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
         "exec.rkt")

(provide verify-determinism)

(define (file-sha1 path) (call-with-input-file path sha1))

;; verify-determinism : graph symbol (hash symbol->runtime)
;;   #:from (or/c symbol #f) #:out-file string -> boolean
;; Returns #t iff both builds produce a byte-identical target file.
(define (verify-determinism g target runtimes
                            #:from [from #f]
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
    (run-plan g to-run runtimes #:env (list (cons "EXPORT_DIR" (path->string dir))))
    (build-path dir out-file))

  (define f1 (build! 1))
  (define f2 (build! 2))
  (define h1 (file-sha1 f1))
  (define h2 (file-sha1 f2))
  (printf "\nbuild #1  sha1 ~a  (~a bytes)\n" h1 (file-size f1))
  (printf "build #2  sha1 ~a  (~a bytes)\n" h2 (file-size f2))
  (cond
    [(string=? h1 h2)
     (printf "\n✓ DETERMINISTIC — ~a is byte-identical across builds\n" out-file)
     #t]
    [else
     (printf "\n✗ NONDETERMINISTIC — ~a differs between builds (sizes ~a vs ~a)\n"
             out-file (file-size f1) (file-size f2))
     #f]))
