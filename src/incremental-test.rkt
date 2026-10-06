#lang racket/base

;; A task told which of its inputs changed (ADR 0015): run-plan sets
;; STELIS_CHANGED_INPUTS only for a task the project names, whose decision was
;; 'input-changed, and whose recorded outputs are as its last clean run left them.
;; Every other reason to run is a full recompute, and the variable stays unset.
;; A synthetic task records what it was told, so each case is read off its output.

(require rackunit
         racket/file
         racket/string
         racket/port
         "model.rkt"
         "cache.rkt"
         "exec.rkt")

(define tmp (make-temporary-file "stelis-incremental-~a" 'directory))
(define a (build-path tmp "a.txt"))
(define b (build-path tmp "b.txt"))
(define out (build-path tmp "out.txt"))
(define out2 (build-path tmp "out2.txt"))

;; writes what it was told into its output: the changed inputs, or FULL
(define script
  (format "if [ -n \"${STELIS_CHANGED_INPUTS+set}\" ]; then printf '%s' \"$STELIS_CHANGED_INPUTS\" | tr '\\n' ' ' > ~a; else printf FULL > ~a; fi; printf x > ~a"
          out out out2))
(define runtimes (hash 'sh (runtime 'sh '("/bin/sh" "-c") "sh")))
(define g
  (build-graph
   (list (make-task 'derive 'transform #:inputs '(a b) #:outputs '(out out2)
                    #:invoke (recipe 'sh (list script))))
   (list (make-artifact 'a 'file #:provenance 'upstream) (make-artifact 'b 'file #:provenance 'upstream)
         (make-artifact 'out 'file) (make-artifact 'out2 'file))))
(define benv
  (make-build-env (lambda (art _dir)
                    (case art [(a) a] [(b) b] [(out) out] [(out2) out2] [else #f]))
                  tmp (build-path tmp "cache")))
(define (build! #:incremental? [inc? (lambda (_) #t)])
  (parameterize ([current-output-port (open-output-nowhere)])
    (define-values (_status _records) (run-plan g '(derive) runtimes #:context benv #:incremental? inc?))
    (void)))
(define (told) (string-trim (file->string out)))

(display-to-file "a0" a #:exists 'replace)
(display-to-file "b0" b #:exists 'replace)

;; 1. no receipt yet: a full recompute, told nothing
(build!)
(check-equal? (told) "FULL" "the first run has no basis, so it is told nothing")

;; 2. one input changed, outputs intact: told exactly that input
(display-to-file "b1" b #:exists 'replace)
(build!)
(check-equal? (told) "b" "a run for one changed input is told which")

;; 3. both changed: told both, sorted
(display-to-file "a1" a #:exists 'replace)
(display-to-file "b2" b #:exists 'replace)
(build!)
(check-equal? (told) "a b" "every changed input is named")

;; 4. nothing changed: cached, no run, the output stands
(build!)
(check-equal? (told) "a b" "an unchanged task does not run at all")

;; 5. an input changed but an output is gone: a full recompute — a partition
;;    replaced beside a missing rest would leave it missing
(display-to-file "a2" a #:exists 'replace)
(delete-file out2)
(build!)
(check-equal? (told) "FULL" "a missing output means recompute whole, whatever changed")

;; 6. an input changed but an output was rewritten underneath: full likewise
(display-to-file "b3" b #:exists 'replace)
(display-to-file "tampered" out2 #:exists 'replace)
(build!)
(check-equal? (told) "FULL" "a stale output means recompute whole")

;; 7. a task the project does not name is never told
(display-to-file "a3" a #:exists 'replace)
(build! #:incremental? (lambda (_) #f))
(check-equal? (told) "FULL" "the hint is opt-in per task")

(delete-directory/files tmp)
