#lang racket/base

;; build-log.rkt (st-9rf): the operator page is a PURE function of the loaded
;; build-records, so these tests feed synthetic builds and read the HTML string —
;; no state dir, no IO. What is pinned: newest-first order; the reported caps
;; (builds shown, keys named); path relativization (nothing absolute survives);
;; HTML escaping of data-carried strings (species keys); the three per-key
;; answers (first production vs a named delta); failure/blocked visibility; and
;; the honest empty page.

(require rackunit
         racket/string
         "cache.rkt"
         "trace.rkt"
         "history.rkt"
         "build-log.rkt")

(define (rec task outcome #:decision [d #f] #:blockers [b '()] #:delta [delta #f]
             #:okh [okh '()])
  (trace-record task d #f outcome b delta '() okh '()))

(define b1
  (build-record 'all "graphhash111" "1754000000"
    (list (rec 'harvest 'ok
               #:decision (decision 'run 'no-cache-entry '())
               #:delta (output-delta 'changed '(notes))
               #:okh (list (cons 'notes '(("Agapostemon <texanus>.json" . "h1")
                                          ("Bombus mixtus.json" . "h2")))))
          (rec 'gate 'failed #:decision (decision 'run 'input-changed '(db)))
          (rec 'publish 'skipped #:blockers '(gate)))))

(define b2
  (build-record 'all "graphhash111" "1754100000"
    (list (rec 'harvest 'ok
               #:decision (decision 'run 'code-changed
                                    '("/Users/me/dev/beeatlas/data/harvest.py"))
               #:delta (output-delta 'changed '(notes))
               #:okh (list (cons 'notes '(("Bombus mixtus.json" . "h2x")
                                          ("Ceratina acantha.json" . "h3")))))
          (rec 'gate 'ok
               #:decision (decision 'run 'input-changed '(db))
               #:delta (output-delta 'identical '(gate-token))))))

(define builds (list b1 b2))
(define html
  (build-log-html builds
                  #:rewrites (list (cons "/Users/me/dev/beeatlas/" "beeatlas/")
                                   (cons "/Users/me/" "~/"))))

(define (pos rx) (caar (regexp-match-positions rx html)))

;; order + header
(check-true (< (pos #rx"Build #2") (pos #rx"Build #1")) "newest first")
(check-true (regexp-match? #rx"2 builds recorded · latest #2" html))
(check-true (regexp-match? #rx"source @ 20[0-9][0-9]-[0-9][0-9]-[0-9][0-9]T" html)
            "epoch rendered as a UTC stamp, from the history's own clock")

;; relativization: the longest prefix wins and nothing absolute survives
(check-true (regexp-match? #rx"beeatlas/data/harvest\\.py" html))
(check-false (regexp-match? #rx"/Users/me" html) "no absolute local path on the page")
(check-false (regexp-match? #rx"~/dev/beeatlas" html) "repo rewrite outranks $HOME")

;; escaping: a key carrying markup renders inert
(check-true (regexp-match? #rx"Agapostemon &lt;texanus&gt;\\.json" html))
(check-false (regexp-match? #rx"<texanus>" html))

;; the per-key story: first production refuses to fake a diff; the second names
;; each arm of the delta
(check-true (regexp-match? #rx"first recorded production — 2 key\\(s\\), no basis" html))
(check-true (regexp-match? #rx"\\+1 added: Ceratina acantha\\.json" html))
(check-true (regexp-match? #rx"~1 changed: Bombus mixtus\\.json" html))
(check-true (regexp-match? #rx"−1 removed: Agapostemon &lt;texanus&gt;\\.json" html))

;; health: the failure is loud, the blocked task names its blocker, cutoff reads
;; as the answer it is
(check-true (regexp-match? #rx"failed: gate" html))
(check-true (regexp-match? #rx"blocked by: gate" html))
(check-true (regexp-match? #rx"outputs identical — early cutoff" html))

;; caps are reported, never silent
(let ([short (build-log-html builds #:limit 1)])
  (check-true (regexp-match? #rx"showing the last 1" short))
  (check-true (regexp-match? #rx"Build #2" short))
  (check-false (regexp-match? #rx"Build #1 " short) "over-limit builds drop out"))
(define many (for/list ([i (in-range 12)]) (cons (format "sp~a.json" i) "h")))
(define many2 (for/list ([p (in-list many)]) (cons (car p) "h2")))
(define wide
  (build-log-html
   (list (build-record 'all "g" "1754000000"
                       (list (rec 'fan 'ok
                                  #:decision (decision 'run 'no-cache-entry '())
                                  #:okh (list (cons 'pages many)))))
         (build-record 'all "g" "1754000001"
                       (list (rec 'fan 'ok
                                  #:decision (decision 'run 'input-changed '(db))
                                  #:delta (output-delta 'changed '(pages))
                                  #:okh (list (cons 'pages many2))))))))
(check-true (regexp-match? #rx"…\\(\\+4 more\\)" wide)
            "12 moved keys: 8 named, the surplus counted aloud")

;; the honest empty page
(check-true (regexp-match? #rx"no builds recorded yet" (build-log-html '())))

;; publish receipts (st-8x1): joined on build number AND epoch; a mismatch drops
;; to absence (never a wrong badge); the header names the last published build;
;; a build with no receipt shows nothing.
(check-false (regexp-match? #rx"site last published" html)
             "no receipts -> no publish claim anywhere")
(define rhtml
  (build-log-html
   builds
   #:receipts (list (hash 'version 1 'build 1 'build-epoch "1754000000"
                          'outcome 'published 'stage "merge-swap" 'path 'nightly)
                    (hash 'version 1 'build 2 'build-epoch "WRONG-EPOCH"
                          'outcome 'published 'stage "merge-swap" 'path 'nightly))))
(check-true (regexp-match? #rx"Build #1 <span class=\"pub-ok\">published</span>" rhtml))
(check-false (regexp-match? #rx"Build #2 <span class=\"pub" rhtml)
             "epoch mismatch -> absence, not a badge")
(check-true (regexp-match? #rx"site last published from build #1, source @ 20" rhtml))
(define rhtml2
  (build-log-html
   builds
   #:receipts (list (hash 'version 1 'build 1 'build-epoch "1754000000"
                          'outcome 'published 'stage "merge-swap" 'path 'note)
                    (hash 'version 1 'build 2 'build-epoch "1754100000"
                          'outcome 'not-published 'stage "integration-gate"
                          'path 'nightly))))
(check-true (regexp-match? #rx"Build #1 <span class=\"pub-ok\">published \\(note write\\)</span>" rhtml2))
(check-true (regexp-match?
             #rx"Build #2 <span class=\"pub-no\">not published — integration-gate</span>" rhtml2))
(check-true (regexp-match? #rx"site last published from build #1" rhtml2)
            "the not-published #2 does not advance the last-published line")

;; determinism, trivially: same builds, same bytes
(check-equal? html
              (build-log-html builds
                              #:rewrites (list (cons "/Users/me/dev/beeatlas/" "beeatlas/")
                                               (cons "/Users/me/" "~/"))))
