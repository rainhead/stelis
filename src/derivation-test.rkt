#lang racket/base

;; In-process DERIVATION nodes (st-ozp): a transform that runs inside the engine
;; and WRITES an artifact — the third invoke variant, beside `recipe' (shell out)
;; and `rule-check' (in-process, verdict only).
;;
;; What this pins is that being in-process buys no exemptions. A derivation is a
;; producing node like any other: its output is observed and receipted, an
;; unchanged input skips it, rebuilding to identical bytes trips early cutoff, and
;; a failure blocks its downstream. Plus the one thing only an in-engine transform
;; has: its own SOURCE is task code, so editing the rule invalidates the cache the
;; way editing a Python exporter does (st-top, turned inward).

(require rackunit
         racket/file
         racket/port
         racket/string
         "model.rkt"
         "cache.rkt"
         "exec.rkt"
         "trace.rkt")

(define tmp (make-temporary-file "stelis-derivation-~a" 'directory))
(define data-path (build-path tmp "data.txt"))     ; an upstream input
(define facts-path (build-path tmp "facts.rktd"))  ; the AUTHORED facts, an artifact
(define rule-path (build-path tmp "rule.rkt"))     ; the ENGINE SOURCE, task code
(define report-path (build-path tmp "report.txt")) ; what the derivation writes
(define out-path (build-path tmp "out.txt"))

;; seed (boundary) -> data ─┐
;;                          ├─> derive (derivation) -> report -> publish -> out
;;              facts ──────┘
;; `derive' writes report from data alone; `facts' is an input it is free to
;; ignore, which is what lets us watch an input change rebuild to IDENTICAL bytes.
(define pass? (box #t))
(define seen-ctx (box #f))
(define (derive-run ctx)
  (set-box! seen-ctx ctx)
  (cond
    [(unbox pass?)
     (display-to-file (string-upcase (file->string data-path))
                      report-path #:exists 'replace)
     (values #t "derived 1 report")]
    [else (values #f "RULE CONFLICT: refusing to publish")]))

(define g
  (build-graph
   (list (make-task 'seed 'boundary #:outputs '(data) #:invoke (recipe 'sh '()))
         (make-task 'derive 'transform #:inputs '(data facts) #:outputs '(report)
                    #:invoke (derivation "taxon-traits" derive-run (list rule-path)))
         (make-task 'publish 'transform #:inputs '(report) #:outputs '(out)
                    #:invoke (recipe 'sh '())))
   (list (make-artifact 'data 'file)
         (make-artifact 'facts 'file)
         (make-artifact 'report 'file)
         (make-artifact 'out 'file))))
(define runtimes (hash 'sh (runtime 'sh '("true") "sh")))

(define benv
  (make-build-env (lambda (a _export)
                    (case a
                      [(data) data-path] [(facts) facts-path]
                      [(report) report-path] [(out) out-path] [else #f]))
                  tmp (build-path tmp "cache")
                  #:runtimes runtimes))

(display-to-file "rows" data-path)
(display-to-file "(traits)" facts-path)
(display-to-file ";; the rule module\n" rule-path)
(display-to-file "built" out-path) ; pre-exist so publish can cache cleanly

(define (build!)
  (parameterize ([current-output-port (open-output-nowhere)])
    (define-values (status records)
      (run-plan g '(seed derive publish) runtimes #:context benv #:state-dir tmp))
    (cons status records)))
(define (status-of r name) (hash-ref (car r) name))
(define (record-of r name)
  (findf (lambda (x) (eq? name (trace-record-task x))) (cdr r)))

;; --- it runs in-process AND produces an artifact --------------------------------

(define b1 (build!))
(check-equal? (status-of b1 'derive) 'ok "the derivation node runs")
(check-pred check-context? (unbox seen-ctx) "…in-process, with a context")
(check-eq? (check-context-task (unbox seen-ctx)) 'derive "…that names the node")
(check-equal? (file->string report-path) "ROWS" "…and it WROTE its output artifact")
(check-equal? (status-of b1 'publish) 'ok "…so its downstream consumer runs")

;; the distinguishing property vs. a rule-check: the artifact is OBSERVED, so it
;; lands in the history and gets a hash timeline like any other derived output.
(check-equal? (map car (trace-record-output-hashes (record-of b1 'derive)))
              '(report)
              "an in-process transform's output is observed like a subprocess's")

;; --- unchanged inputs skip it ----------------------------------------------------

(set-box! seen-ctx #f)
(define b2 (build!))
(check-equal? (status-of b2 'derive) 'cached "unchanged inputs + present output ⇒ skip")
(check-false (unbox seen-ctx) "the rule was NOT re-evaluated on a cache hit")

;; --- editing the ENGINE SOURCE invalidates it (st-top, turned inward) ------------

(display-to-file ";; the rule module, revised\n" rule-path #:exists 'replace)
(define b3 (build!))
(check-equal? (status-of b3 'derive) 'ok "editing the rule's own source reruns the node")
(check-equal? (decision-reason (trace-record-decision (record-of b3 'derive)))
              'code-changed
              "…and it is reported as CODE changing, naming the rule file — not as data")
(check-equal? (decision-details (trace-record-decision (record-of b3 'derive)))
              (list (path->string rule-path)))

;; --- an input change that rebuilds to identical bytes trips early cutoff ---------

(display-to-file "(traits (subfamily \"Nomadinae\"))" facts-path #:exists 'replace)
(define b4 (build!))
(check-equal? (decision-reason (trace-record-decision (record-of b4 'derive)))
              'input-changed
              "the authored facts are an input ARTIFACT, so editing them is a data change")
(check-equal? (output-delta-status (trace-record-delta (record-of b4 'derive)))
              'identical
              "…and rebuilding to identical bytes cuts off, exactly as for a subprocess")
(check-equal? (status-of b4 'publish) 'cached
              "…so the downstream consumer sees unchanged inputs and skips")

;; --- a failing derivation fails, and blocks its downstream ----------------------

(set-box! pass? #f)
(display-to-file "rows-changed" data-path #:exists 'replace) ; force a rerun
(define b5 (build!))
(check-equal? (status-of b5 'derive) 'failed "a #f verdict fails the node")
(check-equal? (status-of b5 'publish) 'skipped
              "…and blocks its downstream (partial success), like a non-zero exit")
(check-equal? (file->string report-path) "ROWS"
              "a failed derivation leaves the last good artifact in place")

;; --- the dry run says there is no command to print ------------------------------

(define shown
  (parameterize ([current-output-port (open-output-string)])
    (print-plan-commands g '(derive) runtimes)
    (get-output-string (current-output-port))))
(check-true (string-contains? shown "derivation: taxon-traits")
            "--commands names the derivation…")
(check-true (string-contains? shown "no command")
            "…and is honest that there is no command to run")

(delete-directory/files tmp)
