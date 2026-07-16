#lang racket/base

;; In-process rule nodes (st-0vz): a build node whose invoke is a `rule-check'
;; evaluated in Racket, not a subprocess. Pins the three behaviours the data-
;; quality-Datalog line depends on: the rule runs in-process and sees its
;; context; a failing rule fails the node and BLOCKS its downstream via the
;; ordinary partial-success flow; and an unchanged input cache-skips the check.

(require rackunit
         racket/file
         racket/port
         "model.rkt"
         "cache.rkt"
         "exec.rkt"
         "trace.rkt")

(define tmp (make-temporary-file "stelis-rulecheck-~a" 'directory))
(define data-path (build-path tmp "data.txt"))
(define out-path (build-path tmp "out.txt"))

;; seed (boundary) -> data -> check (rule gate) -> verified (token) -> publish -> out
;; `check' passes or fails under the control of a box, and records the context it
;; was handed so we can assert the node actually reached the rule in-process.
(define pass? (box #t))
(define seen-ctx (box #f))
(define (check-run ctx)
  (set-box! seen-ctx ctx)
  (if (unbox pass?)
      (values #t "no anomaly")
      (values #f "ANOMALY: blocked")))

(define g
  (build-graph
   (list (make-task 'seed 'boundary #:outputs '(data) #:invoke (recipe 'sh '()))
         (make-task 'check 'gate #:inputs '(data) #:outputs '(verified)
                    #:invoke (rule-check "integrity" check-run))
         (make-task 'publish 'transform #:inputs '(verified) #:outputs '(out)
                    #:invoke (recipe 'sh '())))
   (list (make-artifact 'data 'file)
         (make-artifact 'verified 'token)
         (make-artifact 'out 'file))))
(define runtimes (hash 'sh (runtime 'sh '("true") "sh")))

(define benv
  (make-build-env (lambda (a _export)
                    (case a [(data) data-path] [(out) out-path] [else #f]))
                  tmp (build-path tmp "cache")))

(display-to-file "rows" data-path)
(display-to-file "built" out-path) ; pre-exist so publish can cache cleanly later

(define (build!)
  (parameterize ([current-output-port (open-output-nowhere)])
    (define-values (status records)
      (run-plan g '(seed check publish) runtimes #:context benv #:state-dir tmp))
    (cons status records)))
(define (status-of r name) (hash-ref (car r) name))

;; --- rule passes: the node runs in-process and publish proceeds --------------

(define b1 (build!))
(check-equal? (status-of b1 'check) 'ok "a passing rule node succeeds")
(check-equal? (status-of b1 'publish) 'ok "…and its downstream runs")
(check-pred check-context? (unbox seen-ctx) "the rule ran in-process with a context")
(check-eq? (check-context-task (unbox seen-ctx)) 'check "the context names the node")
(check-eq? (check-context-state-dir (unbox seen-ctx)) tmp
           "…and carries the state-dir where history lives")

;; --- unchanged input cache-skips the check (no re-evaluation) -----------------

(set-box! seen-ctx #f)
(define b2 (build!))
(check-equal? (status-of b2 'check) 'cached
              "an unchanged relation can't be anomalous vs its own last observation — skip")
(check-false (unbox seen-ctx) "the rule was NOT re-evaluated on a cache hit")

;; --- rule fails: the node fails and BLOCKS its downstream ---------------------

(set-box! pass? #f)
(display-to-file "rows-changed" data-path #:exists 'replace) ; force the check to re-run
(define b3 (build!))
(check-equal? (status-of b3 'check) 'failed "a failing rule fails the node")
(check-equal? (status-of b3 'publish) 'skipped
              "…and the downstream is blocked (partial success)")

;; the trace records the failure like any other, in build order
(define check-rec
  (findf (lambda (r) (eq? 'check (trace-record-task r))) (cdr b3)))
(check-equal? (trace-record-outcome check-rec) 'failed "the failed rule lands on the trace")

(delete-directory/files tmp)
