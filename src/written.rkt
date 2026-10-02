#lang racket/base

;; Which artifacts a task has written in this process (st-ml9.6).
;;
;; An observation of an artifact's content — a relation's digest, its per-column
;; parts — can only go stale when something writes the artifact, and within a build
;; the only writers are tasks, each of which declares what it writes. So run-task
;; notes a task's declared outputs as written when it finishes, and anything that
;; caches an observation keys it by the artifact's write GENERATION: the cached
;; value stands until the artifact's generation moves.
;;
;; The trust this rests on is the engine's own: a skip decision already assumes a
;; task writes nothing it doesn't declare, and --verify-edges is what checks it. A
;; writer outside the build (a shell, another process) is invisible here, which is
;; why this lives in memory and dies with the process: a cached observation never
;; outlives the build that made it.

(provide note-written! write-generation)

(define generations (make-hasheq))

;; note-written! : (listof symbol) -> void
(define (note-written! artifacts)
  (for ([a (in-list artifacts)])
    (hash-update! generations a add1 0)))

;; write-generation : symbol -> exact-nonnegative-integer
;; How many times `a' has been written in this process; 0 if never.
(define (write-generation a)
  (hash-ref generations a 0))
