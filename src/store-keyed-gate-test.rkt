#lang racket/base

;; A store-keyed 'dir is held to its keyset after every run (st-243's gate, run in
;; the build since st-6d2.2): after a PARTIAL run a mismatch fails the task — the
;; engine pruned and named keys by a rule the task does not group by — and after a
;; full run it is reported and the run stands. A synthetic task writes files by a
;; grouping of its own; a fake store resolver says what the keys should be.

(require rackunit
         racket/file
         racket/port
         racket/string
         "model.rkt"
         "cache.rkt"
         "exec.rkt"
         "fan-out-key.rkt")

(define tmp (make-temporary-file "stelis-gate-~a" 'directory))
(define out (build-path tmp "days"))
;; FILES says which files the task writes; a partial run writes only the named keys
(define script
  (format "mkdir -p ~a; if [ -n \"${STELIS_REBUILD_KEYS+set}\" ]; then keys=\"$STELIS_REBUILD_KEYS\"; else rm -f ~a/*; keys=\"$FILES\"; fi; printf '%s\\n' \"$keys\" | while IFS= read -r k; do [ -n \"$k\" ] && printf x > ~a/$k.json; done; true" out out out))
(define runtimes (hash 'sh (runtime 'sh '("/bin/sh" "-c") "sh")))
(define g
  (build-graph
   (list (make-task 'write 'transform #:inputs '(rel) #:outputs '(days)
                    #:invoke (recipe 'sh (list script))))
   (list (make-artifact 'rel 'db-relation #:provenance 'upstream)
         (make-artifact 'days 'dir #:keyed-by (store-keyed 'rel "{}.json")))))
;; the store's keyset, and the relation's digest, as the project's resolvers answer;
;; the digest moves before every build, so the task runs every time
(define keys (box '(("a" . "h1:1") ("b" . "h2:1"))))
(define digest (box 0))
(define benv
  (make-build-env (lambda (a _d) (case a [(days) out] [else #f])) tmp (build-path tmp "cache")
                  #:resolve-relation (lambda (a) (format "rel-digest-~a" (unbox digest)))
                  #:resolve-store-keys (lambda (a) (and (eq? a 'rel) (unbox keys)))))
(define (build! files #:rebuild [rk #f])
  (set-box! digest (add1 (unbox digest)))
  (define log (open-output-string))
  (define-values (status _records)
    (parameterize ([current-output-port log])
      (run-plan g '(write) runtimes #:context benv
                #:env (list (cons "FILES" (string-join files "\n")))
                #:rebuild-keys-of (lambda (_) rk))))
  (values (hash-ref status 'write) (get-output-string log)))
(define (reset! files) (let-values ([(_o _l) (build! files)]) (void)))

;; 1. a full run whose files ARE the keyset: sound, nothing said
(let-values ([(outcome log) (build! '("a" "b"))])
  (check-eq? outcome 'ok)
  (check-false (regexp-match? #rx"keyset" log) "a sound dir draws no remark"))

;; 2. a full run that writes a file the keyset does not have: reported, run stands
(let-values ([(outcome log) (build! '("a" "b" "stray"))])
  (check-eq? outcome 'ok "a full run's set is the task's own; the mismatch is a warning")
  (check-true (regexp-match? #rx"⚠ days is not the keyset of its store: stray.json" log) log))

;; 3. restore identity, then a PARTIAL run told key "b" that writes a stray instead:
;;    the engine named keys by one rule, the task wrote by another — failed
(reset! '("a" "b"))
(let-values ([(outcome log) (build! '() #:rebuild (cons '("zz") '()))])
  (check-eq? outcome 'failed "a partial run whose files are not the keyset fails")
  (check-true (regexp-match? #rx"✗ days is not the keyset of its store: zz.json" log) log))

;; 4. a partial run whose named key the store also has: sound again
(reset! '("a" "b"))
(let-values ([(outcome log) (build! '() #:rebuild (cons '("b") '()))])
  (check-eq? outcome 'ok)
  (check-false (regexp-match? #rx"keyset" log)))

(delete-directory/files tmp)
