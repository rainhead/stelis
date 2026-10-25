#lang racket/base

;; A 'dir artifact's per-file observation is held once a task in this build has
;; written it (st-mxr, cache.rkt's dir-tree-hashes): the producer's observation and
;; every consumer's decision ask for the same map, and each ask walked and hashed the
;; whole tree. The trust is written.rkt's, narrowed: only a dir a task in this build
;; wrote is held, until that artifact is written again or the next build starts; a
;; dir nobody in the build wrote is walked on every ask, so a hand edit or a stray
;; file is still seen by the stale-output check.

(require rackunit
         racket/file
         file/sha1
         "model.rkt"
         "cache.rkt"
         "keyed-block.rkt"
         "written.rkt")

(define tmp (make-temporary-file "stelis-dir-observation-~a" 'directory))
(define (dir name) (build-path tmp name))
(define (write-a! d content)
  (make-directory* d)
  (display-to-file content (build-path d "a.txt") #:exists 'replace))
(define (hash-of s) (sha1 (open-input-bytes (string->bytes/utf-8 s))))
(define (a-map s) (list (cons "a.txt" (hash-of s))))

(define g
  (build-graph
   (list (make-task 'make 'transform #:outputs '(out) #:invoke (recipe 'sh '("true")))
         (make-task 'use 'transform #:inputs '(out) #:outputs '(res) #:invoke (recipe 'sh '("true"))))
   (list (make-artifact 'out 'dir) (make-artifact 'res 'file))))

(define (env-for d)
  (make-build-env (lambda (a export-dir) (case a [(out) d] [(res) (build-path tmp "res")] [else #f]))
                  tmp (build-path tmp "cache")))
(define (consumer-address e)
  (hash-ref (snapshot-input-hashes (input-snapshot g 'use (lambda (a) (env-resolve e a)))) 'out))
(define (build-starts!)                      ; what run-plan does first
  (note-build-start!)
  (reset-dir-observations!))
(build-starts!)

;; --- nobody in the build wrote it: every ask walks -----------------------------

(write-a! (dir "one") "a")
(define e1 (env-for (dir "one")))
(check-equal? (artifact-key-parts 'out 'dir e1) (a-map "a"))
(write-a! (dir "one") "hand-edited")
(check-equal? (artifact-key-parts 'out 'dir e1) (a-map "hand-edited")
              "a dir no task has written is whoever's: the edit is seen")

;; --- a task wrote it: held until it is written again ----------------------------

(write-a! (dir "one") "b")
(note-written! '(out))                       ; what run-task does when the producer finishes
(define observed (artifact-key-parts 'out 'dir e1))
(check-equal? observed (a-map "b") "the observation after the write")
(write-a! (dir "one") "stray")
(check-equal? (artifact-key-parts 'out 'dir e1) observed
              "held: within a build only tasks write, and none did")
(check-equal? (consumer-address e1) (keyed-block-digest observed)
              "a consumer's decision answers from the same hold, rolled up")
(note-written! '(out))                       ; the producer ran again
(check-equal? (artifact-key-parts 'out 'dir e1) (a-map "stray")
              "a write moves the generation, and the tree is read again")

;; --- the hold is per path, not per name ---------------------------------------
;; --verify builds the same artifact names into two export dirs; the second dir is
;; walked, never answered from the first.
(write-a! (dir "two") "elsewhere")
(define e2 (env-for (dir "two")))
(check-equal? (artifact-key-parts 'out 'dir e2) (a-map "elsewhere")
              "another path for the same name is its own observation")

;; --- a new build starts with no holds -----------------------------------------
(write-a! (dir "one") "between builds")
(check-equal? (artifact-key-parts 'out 'dir e1) (a-map "stray") "still held within the build")
(build-starts!)
(check-equal? (artifact-key-parts 'out 'dir e1) (a-map "between builds")
              "the next build sees what was written between builds")
;; and, no task in THIS build having written it, it is not held either: the write
;; generation alone would say "written", but that was last build's trust
(write-a! (dir "one") "edited in the next build")
(check-equal? (artifact-key-parts 'out 'dir e1) (a-map "edited in the next build")
              "a dir written in an earlier build of this process is still walked")

;; --- a missing dir is never held ----------------------------------------------
(define e3 (env-for (dir "later")))
(check-false (artifact-key-parts 'out 'dir e3) "absent -> #f")

(delete-directory/files tmp)
