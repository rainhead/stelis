#lang racket/base

;; --explain (st-yg7.2): why would each task in the plan run or be skipped?
;;
;; Slice 1's decision records, walked over the ordered plan with the same
;; frontier logic as the dry run (exec.rkt): a task's decision is provisional
;; when an upstream producer would run before it — that upstream may change its
;; inputs, so a cache hit below the frontier is only *conditionally* a skip.
;; The upstream names are kept, giving the one-hop provenance chain ("stale
;; because dbt-build reruns"); the transitive chain is slice 3's Datalog query.

(require racket/list
         racket/string
         "model.rkt"
         "cache.rkt")

(provide (struct-out explanation)
         walk-explanations
         plan-explanations
         explanation-glyph
         explanation->string
         print-explanations)

;; One task's fate in a hypothetical build right now.
;;   task      : symbol
;;   decision  : decision? — the cache layer's verdict, ignoring upstreams
;;   upstreams : (listof symbol) in-plan producers of its inputs that would run
;;               before it; non-empty makes a 'skip verdict conditional
(struct explanation (task decision upstreams) #:transparent)

;; walk-explanations : graph (listof symbol) (symbol -> decision?)
;;                     -> (listof explanation?)
;; The pure core. Walk the plan in order, asking `decision-of' for each task's
;; own verdict and tracking the would-run frontier: a task runs — and extends
;; the frontier — unless its verdict is 'skip AND no upstream producer runs.
;; (A conditional task extends the frontier too: it MAY run, so everything
;; below it is provisional as well. Same rule as the dry-run tags.)
(define (walk-explanations g ordered decision-of)
  (define will-run (make-hash))
  (for/list ([name (in-list ordered)])
    (define t (hash-ref (graph-tasks g) name))
    (define d (decision-of name))
    (define ups
      (remove-duplicates
       (for*/list ([in (in-list (task-inputs t))]
                   [p (in-value (producer-of g in))]
                   #:when (and p (hash-ref will-run p #f)))
         p)))
    (unless (and (eq? 'skip (decision-verdict d)) (null? ups))
      (hash-set! will-run name #t))
    (explanation name d ups)))

;; plan-explanations : graph (listof symbol)
;;   #:resolve (symbol export-dir -> path/#f) #:export-dir path #:cache-dir path
;;   -> (listof explanation?)
;; The IO wrapper: decisions come from the cache layer against the real
;; filesystem. Same keyword shape as print-plan-commands.
(define (plan-explanations g ordered
                           #:resolve resolve
                           #:export-dir export-dir
                           #:cache-dir cache-dir)
  (define (rsv a) (resolve a export-dir))
  (walk-explanations
   g ordered
   (lambda (name)
     (define t (hash-ref (graph-tasks g) name))
     (task-decision g name rsv cache-dir
                    (filter values (map rsv (task-outputs t)))))))

;; --- Rendering ----------------------------------------------------------------

;; The same legend as the dry run: ≡ skipped · ≈ conditional · ▶ runs.
(define (explanation-glyph e)
  (cond [(eq? 'run (decision-verdict (explanation-decision e))) "▶"]
        [(pair? (explanation-upstreams e))                      "≈"]
        [else                                                   "≡"]))

(define (explanation->string e)
  (define d (explanation-decision e))
  (define details (decision-details d))
  (define (names) (string-join (map ~display details) ", "))
  (define base
    (case (decision-reason d)
      [(boundary)            "boundary — ingestion; never content-skipped"]
      [(inputs-unresolvable) (format "inputs not content-addressable: ~a" (names))]
      [(no-cache-entry)      "no cache entry — never built here"]
      [(recipe-changed)      "recipe changed"]
      [(input-changed)       (format "inputs changed: ~a" (names))]
      [(output-missing)      (format "outputs missing: ~a" (names))]
      [(cached)              "cached — inputs unchanged, outputs present"]
      [else                  (format "~a" (decision-reason d))]))
  (if (and (eq? 'skip (decision-verdict d)) (pair? (explanation-upstreams e)))
      (format "~a, BUT conditional: upstream ~a runs first and may change its inputs"
              base
              (string-join (map symbol->string (explanation-upstreams e)) ", "))
      base))

(define (~display v) (format "~a" v))

;; print-explanations : (listof explanation?) -> void
(define (print-explanations exps)
  (for ([e (in-list exps)] [i (in-naturals 1)])
    (printf "~a~a. ~a ~a\n     ~a\n"
            (if (< i 10) " " "") i
            (explanation-glyph e) (explanation-task e)
            (explanation->string e))))
