#lang racket/base

;; The HTML build log (st-9rf): the observation history rendered as ONE
;; self-contained page — the first probe of visual output modes, and the first
;; exercise of DESIGN's "browser is reached by emission" stance on the engine's
;; own behalf.
;;
;; This is an OPERATOR surface, not site content: Model Y (ADR 0007) gives the
;; site build the render of the DATASET, and stays untouched — beeatlas's 11ty
;; never learns about this page. Stelis emits it itself, AFTER a build, from the
;; completed records — which is what dissolves the apparent recursion of "a page
;; about the build, produced by the build": it is not produced by the build. It
;; is not a graph node at all, has no cache entry, and appears in no plan; it is
;; a projection of `.stelis/` state, maintained the way the history log line is.
;; Build N's page therefore describes build N fully, no fixpoint, no lag.
;;
;; PURE: a function of the loaded build-records and publish receipts (st-8x1 —
;; the publish path's self-reported outcome, joined per build) and nothing
;; else. No wall clock —
;; the page's own stamp is the LAST build's source epoch (the same clock the
;; history records; two renders of the same history are byte-identical, so the
;; determinism guardrail holds trivially). No IO — main.rkt loads the history,
;; supplies the path rewrites, and writes the file (the delta/delta-explain
;; seam idiom).
;;
;; Path REWRITES: decision details name absolute local paths (code files, export
;; dirs). This page sits at a public URL, so the caller passes prefix→label
;; rewrites (beeatlas root, engine root, $HOME) and every rendered string goes
;; through them — relativized at render time, so the history itself keeps the
;; real paths. Longest prefix wins, so a repo under $HOME rewrites as the repo,
;; not as "~/dev/…".
;;
;; Caps are REPORTED, never silent (the show-keys rule): a wide fan-out's moved
;; keys render as the first few plus an explicit "+n more", and the page header
;; says how many builds it shows of how many recorded.

(require racket/list
         racket/string
         racket/format
         racket/date
         "cache.rkt"      ; decision / output-delta / source-report structs
         "trace.rkt"      ; trace-record accessors + outcome-glyph
         "explain.rkt"    ; decision->string, source-report->string (pure)
         "history.rkt"    ; build-record + key-observation structs
         "delta.rkt")     ; build-key-delta — the pure retrospective per-key fold

(provide build-log-html)

;; ---------------------------------------------------------------------------
;; small pure helpers

(define (html-escape v)
  (for/fold ([s (~a v)]) ([sub (in-list '(("&" . "&amp;") ("<" . "&lt;")
                                          (">" . "&gt;") ("\"" . "&quot;")))])
    (string-replace s (car sub) (cdr sub))))

;; apply-rewrites : string (listof (cons string string)) -> string
;; Longest prefix first: "/home/x/dev/beeatlas/…" must become "beeatlas/…",
;; never "~/dev/beeatlas/…".
(define (apply-rewrites s rewrites)
  (for/fold ([s s])
            ([rw (in-list (sort rewrites > #:key (lambda (p) (string-length (car p)))))])
    (string-replace s (car rw) (cdr rw))))

;; The source epoch as a readable UTC stamp. This is the history's own clock
;; (beeatlas's HEAD committer date) — the page never reads the wall clock.
(define (epoch->utc e)
  (define n (string->number (~a e)))
  (if (exact-integer? n)
      (parameterize ([date-display-format 'iso-8601])
        (string-append (date->string (seconds->date n #f) #t) "Z"))
      (~a e)))

;; capped : (listof string) -> string — first few names, surplus counted aloud.
(define KEY-CAP 8)
(define (capped names)
  (define shown (if (> (length names) KEY-CAP) (take names KEY-CAP) names))
  (define extra (- (length names) (length shown)))
  (string-append (string-join (map html-escape shown) ", ")
                 (if (> extra 0) (format ", …(+~a more)" extra) "")))

;; ---------------------------------------------------------------------------
;; per-record projections

;; The one-line "why" for a record: the recorded decision (READ, never
;; re-derived — the key-blame rule), or the blockers for a task that never got
;; to decide.
(define (why-string r rewrites)
  (define d (trace-record-decision r))
  (cond
    [(eq? (trace-record-outcome r) 'skipped)
     (format "blocked by: ~a" (string-join (map ~a (trace-record-blockers r)) ", "))]
    [d (apply-rewrites (decision->string d) rewrites)]
    [else ""]))

(define (delta-string r)
  (define d (trace-record-delta r))
  (cond
    [(not d) ""]
    [(eq? (output-delta-status d) 'identical)
     "outputs identical — early cutoff"]
    [else (format "changed: ~a"
                  (string-join (map ~a (output-delta-details d)) ", "))]))

;; ---------------------------------------------------------------------------
;; the per-key story, reusing delta.rkt's retrospective fold

;; kobs-for : (listof build-record) symbol -> (listof key-observation)
;; The artifact's per-key timeline reconstructed from the loaded builds — only
;; builds that genuinely re-produced it carry a map (a cached run records none),
;; which is exactly the timeline shape build-key-delta expects.
(define (kobs-for builds artifact)
  (for*/list ([(br i) (in-indexed (in-list builds))]
              [r (in-list (build-record-records br))]
              [keys (in-value (let ([p (assq artifact (trace-record-output-key-hashes r))])
                                (and p (cdr p))))]
              #:when keys)
    (key-observation (add1 i) keys r)))

;; keyed-lines : builds build-index rewrites -> (listof string)
;; One line per keyed artifact this build re-produced: which keys moved, named
;; (capped), via build-key-delta. Its three answers stay distinct on purpose:
;; a delta names the keys; 'no-basis is a first production (every key is new —
;; say the count, refuse to pretend a diff); 'not-produced cannot occur here
;; (we only ask about artifacts this build's records carry a map for).
(define (keyed-lines builds i rewrites)
  (define br (list-ref builds (sub1 i)))
  (for*/list ([r (in-list (build-record-records br))]
              [pair (in-list (trace-record-output-key-hashes r))])
    (define a (car pair))
    (define d (build-key-delta a (kobs-for builds a) i))
    (define story
      (cond
        [(eq? d 'no-basis)
         (format "first recorded production — ~a key(s), no basis to diff"
                 (length (cdr pair)))]
        [(key-delta? d)
         (if (zero? (key-delta-count d))
             (format "no keys moved (~a total)" (key-delta-total d))
             (string-join
              (filter values
                      (list (let ([ks (key-delta-added d)])
                              (and (pair? ks) (format "+~a added: ~a" (length ks) (capped ks))))
                            (let ([ks (key-delta-changed d)])
                              (and (pair? ks) (format "~~~a changed: ~a" (length ks) (capped ks))))
                            (let ([ks (key-delta-removed d)])
                              (and (pair? ks) (format "−~a removed: ~a" (length ks) (capped ks))))))
              " · "))]
        [else (~a d)]))
    (format "<div class=\"keys\"><span class=\"art\">~a</span> ~a</div>"
            (html-escape a) (apply-rewrites story rewrites))))

;; ---------------------------------------------------------------------------
;; publish receipts (st-8x1)

;; receipt-for : (listof hash) exact-positive-integer string -> (or/c hash #f)
;; The receipt naming build i — joined on BOTH the number and the build's own
;; epoch (see history.rkt: the number is a live index, not an identity; a
;; mismatched receipt drops to absence rather than mislabeling a renumbered
;; build). First match wins; --mark-publish's refusal makes seconds anomalous.
(define (receipt-for receipts i epoch)
  (for/first ([r (in-list receipts)]
              #:when (and (equal? i (hash-ref r 'build #f))
                          (equal? (~a epoch) (~a (hash-ref r 'build-epoch "")))))
    r))

;; The badge. Absence renders NOTHING, deliberately: a build with no receipt has
;; no publish story (pre-feature builds, dev builds on a laptop) — silence is
;; honest where "not published" would be an accusation.
(define (publish-badge r)
  (cond
    [(not r) ""]
    [(eq? 'published (hash-ref r 'outcome #f))
     (format " <span class=\"pub-ok\">published~a</span>"
             (if (eq? 'note (hash-ref r 'path #f)) " (note write)" ""))]
    [else
     (format " <span class=\"pub-no\">not published — ~a</span>"
             (html-escape (hash-ref r 'stage "unknown")))]))

;; ---------------------------------------------------------------------------
;; sections

(define (outcome-class o) (format "o-~a" o))

(define (record-row r rewrites)
  (define o (trace-record-outcome r))
  (define sr (trace-record-source-report r))
  (format "<tr class=\"~a\"><td class=\"g\">~a</td><td class=\"t\">~a</td><td>~a</td><td>~a~a</td></tr>"
          (outcome-class o)
          (html-escape (outcome-glyph o))
          (html-escape (trace-record-task r))
          (html-escape (why-string r rewrites))
          (html-escape (delta-string r))
          (if sr
              (format "<div class=\"src\">~a</div>"
                      (html-escape (source-report->string sr)))
              "")))

(define (build-section builds i rewrites receipts)
  (define br (list-ref builds (sub1 i)))
  (define records (build-record-records br))
  (define (tally o) (for/sum ([r (in-list records)]
                              #:when (eq? o (trace-record-outcome r))) 1))
  (define failed (for/list ([r (in-list records)]
                            #:when (eq? 'failed (trace-record-outcome r)))
                   (trace-record-task r)))
  (string-append
   (format "<section><h2>Build #~a~a <span class=\"meta\">source @ ~a · target: ~a · graph ~a</span></h2>\n"
           i
           (publish-badge (receipt-for receipts i (build-record-epoch br)))
           (html-escape (epoch->utc (build-record-epoch br)))
           (html-escape (build-record-target br))
           (html-escape (let ([h (~a (build-record-graph-hash br))])
                          (if (> (string-length h) 12) (substring h 0 12) h))))
   (format "<p class=\"sum\">✓ ~a ran · ≡ ~a cached · ✗ ~a failed · ⊘ ~a blocked~a</p>\n"
           (tally 'ok) (tally 'cached) (tally 'failed) (tally 'skipped)
           (if (null? failed)
               ""
               (format " — <span class=\"o-failed\">failed: ~a</span>"
                       (html-escape (string-join (map ~a failed) ", ")))))
   (string-join (keyed-lines builds i rewrites) "\n")
   "\n<table><tr><th></th><th>task</th><th>why</th><th>outputs</th></tr>\n"
   (string-join (for/list ([r (in-list records)]) (record-row r rewrites)) "\n")
   "\n</table></section>\n"))

(define CSS #<<END
:root{--bg:#fff;--fg:#1c1e21;--muted:#68708a;--line:#e4e6ee;--ok:#2e7d32;--failed:#c62828;--skipped:#a86500;--soft:#f6f7fa}
@media (prefers-color-scheme:dark){:root{--bg:#15171b;--fg:#e6e8ee;--muted:#9aa2b8;--line:#2b2f38;--ok:#7bc67e;--failed:#ef9a9a;--skipped:#e0b364;--soft:#1c1f26}}
body{background:var(--bg);color:var(--fg);font:14px/1.55 ui-sans-serif,system-ui,sans-serif;max-width:72rem;margin:2rem auto;padding:0 1.25rem}
h1{font-size:1.4rem;margin:0 0 .25rem}
h2{font-size:1.05rem;margin:2rem 0 .25rem;border-top:2px solid var(--line);padding-top:1rem}
.meta,.sum,.src{color:var(--muted)}
.sum{margin:.1rem 0 .5rem}
.meta{font-weight:normal;font-size:.85rem}
.keys{font-size:.9rem;margin:.15rem 0;padding:.3rem .6rem;background:var(--soft);border-radius:4px}
.keys .art{font-weight:600}
table{border-collapse:collapse;width:100%;font-size:.9rem}
td,th{padding:.25rem .6rem;border-top:1px solid var(--line);text-align:left;vertical-align:top}
th{color:var(--muted);font-weight:600;border-top:none}
td.g{width:1.2rem}
td.t{white-space:nowrap;font-weight:600}
.o-ok td.g{color:var(--ok)}
.o-cached{color:var(--muted)}
.o-failed td.g,span.o-failed{color:var(--failed);font-weight:600}
.o-skipped td.g{color:var(--skipped)}
.src{font-size:.85rem}
.pub-ok,.pub-no{font-size:.75rem;font-weight:600;padding:.1rem .45rem;border-radius:9px;vertical-align:middle}
.pub-ok{color:var(--ok);border:1px solid var(--ok)}
.pub-no{color:var(--failed);border:1px solid var(--failed)}
END
)

;; build-log-html : (listof build-record)
;;                  [#:rewrites (listof (cons string string))]
;;                  [#:limit exact-positive-integer]
;;                  -> string
;; The whole page. `builds` oldest-first, exactly as history-load returns them;
;; rendered newest-first, capped at `limit` builds with the cap reported in the
;; header. An empty history renders an honest empty page rather than erroring —
;; the nightly should never fail over its own reporting.
(define (build-log-html builds #:rewrites [rewrites '()] #:limit [limit 30]
                        #:receipts [receipts '()])
  (define n (length builds))
  (define shown-count (min n limit))
  ;; the highest-numbered build with a JOINED published receipt — the header
  ;; line that answers "is what I'm reading live?" at a glance. Omitted when no
  ;; receipt says so (pre-feature histories): absence over accusation.
  (define last-published
    (for/last ([(br i) (in-indexed (in-list builds))]
               #:when (let ([r (receipt-for receipts (add1 i) (build-record-epoch br))])
                        (and r (eq? 'published (hash-ref r 'outcome #f)))))
      (add1 i)))
  (define header
    (if (zero? n)
        "<p class=\"sum\">no builds recorded yet</p>"
        (format "<p class=\"sum\">~a build~a recorded · latest #~a, source @ ~a~a~a</p>"
                n (if (= n 1) "" "s") n
                (html-escape (epoch->utc (build-record-epoch (last builds))))
                (if last-published
                    (format " · site last published from build #~a, source @ ~a"
                            last-published
                            (html-escape
                             (epoch->utc (build-record-epoch
                                          (list-ref builds (sub1 last-published))))))
                    "")
                (if (> n limit) (format " · showing the last ~a" limit) ""))))
  (string-append
   "<!doctype html>\n<html lang=\"en\">\n<head>\n<meta charset=\"utf-8\">\n"
   "<meta name=\"viewport\" content=\"width=device-width, initial-scale=1\">\n"
   "<title>stelis build log</title>\n<style>\n" CSS "\n</style>\n</head>\n<body>\n"
   "<h1>stelis build log</h1>\n" header "\n"
   (string-join
    ;; newest first: build numbers n, n-1, … down to the first shown. Numbers,
    ;; not index-of — two builds can be equal? as values (a fully-cached rerun
    ;; of an unchanged snapshot), and only their position tells them apart.
    (for/list ([i (in-range n (- n shown-count) -1)])
      (build-section builds i rewrites receipts))
    "\n")
   "\n</body>\n</html>\n"))
