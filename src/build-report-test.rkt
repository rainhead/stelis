#lang racket/base

;; Tests for the --build report (build-report.rkt, st-3un). Each file must say what
;; the launch it replaces would have said: `build` the line --last-build prints,
;; `moved-keys` the keys --moved-keys prints. And absence must keep meaning the
;; cautious thing: nothing to mark, no basis for a delta.

(require rackunit
         racket/file
         "model.rkt"
         "cache.rkt"
         "trace.rkt"
         "history.rkt"
         "build-report.rkt")

;; maps -> species-maps, a 'dir whose keys are files, as in history-test.rkt
(define g
  (build-graph
   (list (make-task 'maps 'transform #:inputs '(taxa) #:outputs '(species-maps)))
   (list (make-artifact 'taxa 'file #:provenance 'upstream) (make-artifact 'species-maps 'dir))))
(define (rec-maps keys)
  (trace-record 'maps (decision 'run 'input-changed '(taxa))
                (snapshot "r" (hash 'taxa "t")) 'ok '() #f
                (list (cons 'species-maps "dir-digest"))
                (list (cons 'species-maps keys))
                '()))
(define cache-skip
  (trace-record 'maps (decision 'skip 'inputs-unchanged '()) #f 'cached '() #f '() '() '()))

;; dir's report: (values build-line-or-#f moved-keys-lines-or-#f)
(define (read-report dir)
  (define (lines name)
    (define f (build-path dir name))
    (and (file-exists? f) (file->lines f)))
  (define b (lines "build"))
  (values (and b (car b)) (lines "moved-keys")))

(define state (make-temporary-directory "stelis-build-report-~a"))
(define report (build-path state "report"))

(test-case "before any build there is nothing to report"
  (clear-build-report! report)
  (write-build-report! report state 'species-maps)
  (define-values (b m) (read-report report))
  (check-false b "no build line: nothing was appended")
  (check-false m "no moved keys: no basis"))

(void (history-append! state 'species-maps g "100"
                       (list (rec-maps '(("genus/Apis.svg" . "a0") ("genus/Bombus.svg" . "b0"))))))

(test-case "a first production has no basis: the build line, but no moved-keys file"
  (clear-build-report! report)
  (write-build-report! report state 'species-maps)
  (define-values (b m) (read-report report))
  (check-equal? b "1 100" "the number and the epoch, as --last-build prints them")
  (check-false m "every key is new, which is not a delta — the caller renders in full"))

(void (history-append! state 'species-maps g "200"
                       (list (rec-maps '(("genus/Bombus.svg" . "b1") ("genus/Osmia.svg" . "o0"))))))

(test-case "a real delta: its moved keys, sorted, one per line"
  (clear-build-report! report)
  (write-build-report! report state 'species-maps)
  (define-values (b m) (read-report report))
  (check-equal? b "2 200")
  (check-equal? m '("genus/Apis.svg" "genus/Bombus.svg" "genus/Osmia.svg")
                "removed + changed + added, as --moved-keys prints them"))

(test-case "a build of the whole graph reports its number and no moved keys"
  (clear-build-report! report)
  (write-build-report! report state #f)
  (define-values (b m) (read-report report))
  (check-equal? b "2 200")
  (check-false m))

(void (history-append! state 'species-maps g "300" (list cache-skip)))

(test-case "a build that did not re-produce the target reports nothing moved: an empty file"
  (clear-build-report! report)
  (write-build-report! report state 'species-maps)
  (define-values (b m) (read-report report))
  (check-equal? b "3 300")
  (check-equal? m '() "present and empty is the answer; absent would force a full render"))

(test-case "clearing removes a previous build's answers"
  (clear-build-report! report)
  (define-values (b m) (read-report report))
  (check-false b "a build that stops before its history line must not leave the last one's number")
  (check-false m))

(delete-directory/files state)
