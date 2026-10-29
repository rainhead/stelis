#lang racket/base

;; Tests for peak-memory.rkt (st-1hi.1): parsing /proc, the trace datum, the
;; rendering, and, where there is a /proc, real measurements of real processes.
;; The measured tests allocate in a child Racket (the one running this test), so
;; they need no tool beyond what the suite already has.

(require rackunit
         racket/os
         racket/port
         "peak-memory.rkt")

;; --- /proc status parsing -------------------------------------------------------

(define status-text
  "Name:\tracket\nVmPeak:\t  900000 kB\nVmHWM:\t  432712 kB\nVmRSS:\t  431000 kB\nThreads:\t4\n")
(check-equal? (status-field-kb status-text "VmHWM") 432712)
(check-equal? (status-field-kb status-text "VmRSS") 431000)
(check-false (status-field-kb status-text "VmSwap") "an absent field is #f")
(check-false (status-field-kb status-text "VmH") "a field name matches whole, not by prefix")

;; --- the trace datum and the rendering -----------------------------------------------

(for ([p (list (peak 421888 'process) (peak 1024 'sampled) (peak 180224 'engine))])
  (check-equal? (datum->peak (peak->datum p)) p "a peak survives its datum"))
(check-false (peak->datum #f))
(check-false (datum->peak #f))
(check-false (datum->peak '(12 bogus)) "an unknown basis is not read as a peak")
(check-false (datum->peak '(-1 process)))

(check-equal? (peak->string (peak 421888 'process)) "peak 412 MB")
(check-equal? (peak->string (peak 421888 'sampled)) "peak ≥ 412 MB (sampled)"
              "a sampled figure says it is a lower bound")
(check-equal? (peak->string (peak 180224 'engine)) "engine peak 176 MB")
(check-equal? (peak->string (peak 300 'sampled)) "peak < 1 MB (sampled)")

;; --- real processes ---------------------------------------------------------------------

(define racket (find-executable-path (find-system-path 'exec-file)))

;; a child Racket that holds MB megabytes for a while, under a shell by default,
;; as a real task runs under its runtime's launcher. (Sampling passes over a tree's
;; root while it is still running the engine's own program, which is how it tells
;; a child that has not exec'd yet from the task, so a bare Racket child would go
;; unsampled.)
(define (spawn mb #:via-shell? [via-shell? #t])
  (define expr (format "(define b (make-bytes ~a 1)) (sleep 0.6)" (* mb 1000000)))
  (define-values (sp out in err)
    (if via-shell?
        (subprocess #f #f #f "/bin/sh" "-c" (format "'~a' -e '~a'; true" racket expr))
        (subprocess #f #f #f racket "-e" expr)))
  (close-output-port in)
  (thread (lambda () (copy-port out (open-output-nowhere))))
  (thread (lambda () (copy-port err (open-output-nowhere))))
  sp)

(define (measure sp)
  (define-values (status pk)
    (measure-subprocess sp (lambda () (subprocess-wait sp) (subprocess-status sp))))
  (check-equal? status 0 "a measurement counts only if the run succeeded")
  pk)

(when (rusage-max-kb 'self)
  (check-true (> (rusage-max-kb 'self) 10000) "the engine's own peak is plausible"))

(when (directory-exists? "/proc/self")
  ;; the tree reaches a grandchild through a shell
  (let ([sp (spawn 20 #:via-shell? #t)])
    (sleep 0.3)
    (check-true (> (length (process-tree (subprocess-pid sp))) 1)
                "the shell's child is in the tree")
    (subprocess-wait sp))

  ;; a tiny task is not credited with the engine's size, which its fork copied
  (let-values ([(sp out in err) (subprocess #f #f #f "/bin/sh" "-c" "true")])
    (close-output-port in)
    (define-values (status pk)
      (measure-subprocess sp (lambda () (subprocess-wait sp) (subprocess-status sp))))
    (check-true (or (not pk) (< (peak-kb pk) 20000))
                (format "a no-op shell is not the engine's size: ~a" pk)))

  ;; a child larger than every earlier one (and than the engine) moves the
  ;; kernel's account: exact
  (let ([pk (measure (spawn 300))])
    (check-equal? (peak-basis pk) 'process "a new high-water mark is the kernel's exact figure")
    (check-true (>= (peak-kb pk) 300000) "…and holds what the child allocated"))

  ;; a smaller one afterwards leaves the kernel's mark where it was: sampled
  (let ([pk (measure (spawn 40))])
    (check-equal? (peak-basis pk) 'sampled)
    (check-true (>= (peak-kb pk) 40000))
    (check-true (< (peak-kb pk) 300000) "…and is the small child's, not the earlier one's"))

  ;; a grandchild under a shell is counted
  (let ([pk (measure (spawn 120 #:via-shell? #t))])
    (check-true (>= (peak-kb pk) 120000) "the grandchild's memory is the task's"))

  ;; in-process: the thunk's value comes back, measured as the engine's
  (let-values ([(v pk) (measure-in-process
                        (lambda () (bytes-length (make-bytes 50000000 1))))])
    (check-equal? v 50000000)
    (check-equal? (and pk (peak-basis pk)) 'engine)))
