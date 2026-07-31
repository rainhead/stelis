#lang racket/base

;; The `--moved-keys` CLI CONTRACT (beeatlas-4oa). delta-test.rkt covers the fold;
;; this covers the part a caller outside Racket actually binds to, and which no
;; pure test can catch breaking:
;;
;;   stdout carries the moved keys and NOTHING else, one per line
;;   exit 0 + keys     — these moved
;;   exit 0 + silence  — nothing moved (producer cache-skipped / identical content)
;;   exit 1            — no basis; the caller must rebuild in FULL, never nothing
;;
;; The last two lines are the load-bearing ones. beeatlas's note publish renders only
;; the species named on stdout, so a diagnostic printf landing on stdout would try to
;; render a page called "notes — 2 of 3 keys…", and an exit-0-on-no-basis would render
;; nothing at all and publish a note that never appears. Both are silent failures in
;; production and cheap to catch here.
;;
;; GATED like the other environment-coupled tests: main.rkt requires beeatlas.rkt,
;; whose graph is authored by scanning the beeatlas checkout (py-imports at
;; graph-authoring time), so a bare checkout / CI skips.

(require rackunit
         racket/system
         racket/file
         racket/runtime-path
         "beeatlas.rkt"
         "history.rkt"
         "trace.rkt")

(define-runtime-path main-rkt "main.rkt")

;; stdout as its list of non-empty lines
(define (lines s)
  (for/list ([l (in-list (regexp-split #rx"\n" s))] #:unless (equal? "" l)) l))

;; A record that observed `artifact` with this (key -> hash) map, and nothing else.
(define (keyed-record task artifact keys)
  (trace-record task #f #f 'ok '() #f
                (list (cons artifact "whole-dir-hash"))
                (list (cons artifact keys))
                '()))

;; Run the CLI against a throwaway state dir; -> (values stdout stderr exit-code).
(define (cli state-dir . args)
  (define out (open-output-string))
  (define err (open-output-string))
  (define code
    (parameterize ([current-output-port out]
                   [current-error-port err]
                   [current-environment-variables
                    (environment-variables-copy (current-environment-variables))])
      (putenv "STELIS_STATE_DIR" (path->string state-dir))
      (apply system*/exit-code (find-executable-path "racket")
             (path->string main-rkt) args)))
  (values (get-output-string out) (get-output-string err) code))

(cond
  [(not (file-exists? beeatlas-db))
   (printf "--moved-keys CLI contract: SKIPPED — no beeatlas checkout\n")]
  [else
   ;; Two recorded builds: build 1 harvests two species; build 2 changes one, adds
   ;; one and drops one.
   (define state (make-temporary-directory))
   (history-append! state 'notes beeatlas-graph "1000000000"
                    (list (keyed-record 'notes-harvest 'notes
                                        '(("apis mellifera.json" . "h1")
                                          ("bombus mixtus.json" . "h2")))))
   (history-append! state 'notes beeatlas-graph "1000000001"
                    (list (keyed-record 'notes-harvest 'notes
                                        '(("apis mellifera.json" . "hX")
                                          ("osmia lignaria.json" . "h3")))))

   (test-case "moved keys go to stdout, one per line, and nothing else does"
     (define-values (out err code) (cli state "--moved-keys" "notes"))
     (check-equal? code 0 "a real delta exits 0")
     (check-equal? (lines out)
                   '("apis mellifera.json" "bombus mixtus.json" "osmia lignaria.json")
                   "changed + removed + added, sorted, bare — stdout is machine input")
     (check-true (regexp-match? #rx"3 of 3 keys" err)
                 "the human summary goes to stderr, where it cannot corrupt the key list"))

   ;; A build that did NOT re-produce the artifact: the empty key set is the ANSWER.
   (history-append! state 'species_reasoning.json beeatlas-graph "1000000002"
                    (list (trace-record 'taxon-derive #f #f 'ok '() #f '() '() '())))

   (test-case "a build that didn't re-produce the artifact reports nothing moved"
     (define-values (out err code) (cli state "--moved-keys" "notes"))
     (check-equal? code 0 "nothing moved is a successful answer, not a failure")
     (check-equal? (lines out) '() "no keys on stdout")
     (check-true (regexp-match? #rx"not re-produced" err) "and says so on stderr"))

   ;; No basis at all — the caller must fall back to a full rebuild.
   (test-case "an artifact with no per-key timeline refuses, rather than saying nothing moved"
     (define fresh (make-temporary-directory))
     (history-append! fresh 'notes beeatlas-graph "1000000000"
                      (list (trace-record 'notes-harvest #f #f 'ok '() #f '() '() '())))
     (define-values (out err code) (cli fresh "--moved-keys" "notes"))
     (check-equal? code 1 "no basis exits non-zero so the caller rebuilds in FULL")
     (check-equal? (lines out) '() "and offers no keys to act on")
     (delete-directory/files fresh))

   (test-case "a name that isn't an artifact is named as such, not treated as unmoved"
     (define-values (out err code) (cli state "--moved-keys" "notez"))
     (check-equal? code 1 "a typo exits non-zero")
     (check-equal? (lines out) '())
     (check-true (regexp-match? #rx"no artifact by that name" err)))

   (delete-directory/files state)])
