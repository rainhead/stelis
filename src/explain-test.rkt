#lang racket/base

;; Unit tests for the explanation walk (explain.rkt, st-yg7.2): the pure
;; frontier logic over a synthetic diamond with stubbed decisions, and the
;; one-hop "conditional because upstream X runs" attribution.

(require rackunit
         racket/string
         "model.rkt"
         "cache.rkt"
         "explain.rkt")

;; The model-test diamond: ingest -> raw; left(raw)->l; right(raw)->r;
;; join(l,r)->out. Boundary ingest always runs, so everything below it is at
;; best conditional — exactly the beeatlas shape.
(define g
  (build-graph
   (list (make-task 'ingest 'boundary  #:outputs '(raw))
         (make-task 'left   'transform #:inputs '(raw) #:outputs '(l))
         (make-task 'right  'transform #:inputs '(raw) #:outputs '(r))
         (make-task 'join   'transform #:inputs '(l r) #:outputs '(out)))
   (list (make-artifact 'raw 'file) (make-artifact 'l 'file)
         (make-artifact 'r 'file)   (make-artifact 'out 'file))))
(define ordered '(ingest left right join))

(define (stub decisions) (lambda (name) (hash-ref decisions name)))

;; Everything cached below a boundary: the boundary runs, all else conditional.
(let* ([exps (walk-explanations
              g ordered
              (stub (hash 'ingest (decision 'run 'boundary '())
                          'left   (decision 'skip 'cached '())
                          'right  (decision 'skip 'cached '())
                          'join   (decision 'skip 'cached '()))))]
       [by-task (for/hash ([e (in-list exps)]) (values (explanation-task e) e))])
  (check-equal? (explanation-upstreams (hash-ref by-task 'ingest)) '()
                "the boundary has no in-plan upstream")
  (check-equal? (explanation-upstreams (hash-ref by-task 'left)) '(ingest)
                "left is conditional because ingest runs")
  (check-equal? (explanation-upstreams (hash-ref by-task 'join)) '(left right)
                "conditional tasks extend the frontier: join blames both")
  (check-equal? (map explanation-glyph exps) '("▶" "≈" "≈" "≈")
                "glyphs match the dry-run legend"))

;; A genuinely materialised frontier: nothing upstream runs, so a cache hit is
;; a real skip, and a miss below it starts a new frontier.
(let* ([exps (walk-explanations
              g '(left right join)   ; --from style suffix: ingest not in plan
              (stub (hash 'left  (decision 'skip 'cached '())
                          'right (decision 'run 'input-changed '(raw))
                          'join  (decision 'skip 'cached '()))))]
       [by-task (for/hash ([e (in-list exps)]) (values (explanation-task e) e))])
  (check-equal? (explanation-glyph (hash-ref by-task 'left)) "≡"
                "no running upstream: a cache hit really skips")
  (check-equal? (explanation-upstreams (hash-ref by-task 'join)) '(right)
                "join blames only the branch that runs")
  (check-equal? (explanation-glyph (hash-ref by-task 'join)) "≈"
                "cached but downstream of a runner: conditional"))

;; Rendering: reasons name their details; conditionals name their upstream.
(check-true (regexp-match?
             #rx"inputs changed: raw"
             (explanation->string
              (explanation 'right (decision 'run 'input-changed '(raw)) '())))
            "a changed input is named in the rendering")
(check-true (regexp-match?
             #rx"conditional: upstream right runs first"
             (explanation->string
              (explanation 'join (decision 'skip 'cached '()) '(right))))
            "a conditional skip names the upstream that causes it")
(check-false (regexp-match?
              #rx"conditional"
              (explanation->string
               (explanation 'left (decision 'skip 'cached '()) '())))
             "a real skip is not marked conditional")
