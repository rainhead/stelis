#lang racket/base

;; The DELTA substrate (st-066, Horizon 2) — entry point. Folds the H1
;; observation history's PER-KEY layer into a NAMED change: which fan-out members
;; of a keyed artifact ('dir tree paths, or db-relation columns) moved between two
;; (re)productions.
;;
;; DELTA REASONING BEFORE DELTA MECHANISM (st-2hh). This mirrors how H1 sequenced
;; itself — make the build EXPLAIN staleness (provenance-as-value) before making
;; anything physically faster. So this module REPORTS the minimal changed key-set
;; as a staleness reason; it does NOT yet make any rebuild physically targeted.
;; The exporter still reruns whole; the engine now merely SEES, and can name, the
;; delta. Targeted execution is a later slice.
;;
;; PER-KEY STALENESS FIRST (user, 2026-07-16; DESIGN "Fine-grained
;; incrementality ... buy back finer granularity only when coarse over-rebuilding
;; actually hurts", lines 130-132). No Z-set / DBSP retraction algebra here: a
;; delta is a plain three-way partition of key names, not a value that flows. That
;; heavier model waits for a case where coarse rebuilding demonstrably hurts.
;;
;; THE SEAM. history-key-observations (history.rkt) already hands back a keyed
;; artifact's full (part -> hash) map at each build that (re)produced it; the
;; Datalog projection names datalog-key-observations "the seam H2 propagation
;; reads". This module reads that seam: diff two such maps -> the members that
;; changed, WITHOUT re-reading any input relation.
;;
;; `diff-key-maps` is the shared core; two callers feed it different `to` sides:
;;   RETROSPECTIVE — both maps from history's timeline, one adjacent PAIR at a time
;;                   ("at that build, these keys of A moved"). --history is that
;;                   caller — it walks every adjacent pair, so it uses diff-key-maps
;;                   directly rather than a whole-timeline fold.
;;   PROSPECTIVE — `prospective-delta`: the `to` map read LIVE off disk vs history's
;;                   tail ("these keys of A are about to move"). This is the seam
;;                   --explain / --why decorate, via delta-explain.rkt.

(require racket/list
         racket/string
         "history.rkt")   ; key-observation accessors

(provide (struct-out key-delta)
         key-delta-count
         diff-key-maps
         prospective-delta
         key-delta->string)

;; A per-key delta: which members of one keyed artifact moved from one
;; (re)production to the next. The delta names only what MOVED — `unchanged` keys
;; are deliberately absent (the whole point is to be minimal); `total` is the
;; denominator the prose reads for "2 of 214".
;;   artifact   : symbol
;;   from-build : (or/c exact-positive-integer #f) — the `from` side's build; #f
;;                when it is a live/on-disk map rather than a recorded build
;;   to-build   : (or/c exact-positive-integer 'pending) — the `to` side's build.
;;                prospective-delta (the only producer today) sets 'pending: the
;;                live map is a build about to happen. Kept general so a future
;;                history-to-history producer can record the actual to-build.
;;   total      : exact-nonnegative-integer — the distinct keys INVOLVED: the union
;;                of the from- and to-side keys (= |to| + |removed|). The `of N`
;;                denominator, chosen so `count` can never exceed it (a removed key
;;                is absent from the to-side but still moved, so it must be counted
;;                in the total too)
;;   added      : (listof string) — keys in `to`, absent from `from`
;;   removed    : (listof string) — keys in `from`, absent from `to`
;;   changed    : (listof string) — in both, but the value (content hash /
;;                "digest:count") differs
;; Each list is sorted.
(struct key-delta (artifact from-build to-build total added removed changed)
  #:transparent)

;; key-delta-count : key-delta -> exact-nonnegative-integer — how many moved. Zero
;; is meaningful: a re-production to identical content, seen per-key (the early
;; cutoff case). It is NOT the same as "no delta" (#f) — the producer did re-run.
(define (key-delta-count d)
  (+ (length (key-delta-added d))
     (length (key-delta-removed d))
     (length (key-delta-changed d))))

;; diff-key-maps : (listof (cons string string)) (listof (cons string string))
;;                 -> (values (listof string) (listof string) (listof string))
;; The pure three-way partition of two (key -> value) alists (the
;; key-observation-keys shape): keys only in `new` (added), only in `old`
;; (removed), in both but with a differing value (changed), each sorted. Values
;; are opaque strings — a 'dir member's content hash, or a db-relation column's
;; "digest:count" — compared by equality only. Kin to cache.rkt's `changed-names`,
;; but three-way where that one is a flat "differs or one-sided" list; the extra
;; structure is exactly what lets the prose distinguish +added / ~changed /
;; -removed.
(define (diff-key-maps old new)
  (define oh (make-immutable-hash old))
  (define nh (make-immutable-hash new))
  (define added
    (sort (for/list ([k (in-hash-keys nh)] #:unless (hash-has-key? oh k)) k) string<?))
  (define removed
    (sort (for/list ([k (in-hash-keys oh)] #:unless (hash-has-key? nh k)) k) string<?))
  (define changed
    (sort (for/list ([(k v) (in-hash oh)]
                     #:when (and (hash-has-key? nh k)
                                 (not (equal? v (hash-ref nh k)))))
            k)
          string<?))
  (values added removed changed))

;; prospective-delta : symbol (listof key-observation)
;;                     (listof (cons string string)) -> (or/c key-delta #f)
;; The PROSPECTIVE fold: diff a keyed artifact's most recent RECORDED
;; key-observation (its `from`) against a LIVE on-disk key map (`to` — read off
;; disk now, not yet in history). Same diff core as observations->delta; the only
;; difference is where the `to` side comes from. #f when the artifact has no prior
;; observation to diff against (nothing recorded to compare the pending state to).
;; to-build is 'pending — this map is a build about to happen, not a recorded one.
(define (prospective-delta artifact obs live-keys)
  (and (pair? obs)
       (let ([prev (last obs)])
         (define-values (added removed changed)
           (diff-key-maps (key-observation-keys prev) live-keys))
         (key-delta artifact
                    (key-observation-build prev)
                    'pending
                    (+ (length live-keys) (length removed))
                    added removed changed))))

;; key-delta->string : key-delta -> string
;; The moved keys as compact prose, refining a bare "inputs changed: A" into a
;; named subset: `+k` added, `~k` changed, `-k` removed, e.g.
;; "2 of 214 keys: +olympia ~seattle". An empty delta reads "no keys moved".
(define (key-delta->string d)
  (define n (key-delta-count d))
  (define total (key-delta-total d))
  (if (zero? n)
      (format "no keys moved (~a total)" total)
      (format "~a of ~a key~a: ~a"
              n total (if (= 1 total) "" "s")
              (string-join (moved-markers d) " "))))

;; the sorted markers, added then changed then removed
(define (moved-markers d)
  (append (map (lambda (k) (string-append "+" k)) (key-delta-added d))
          (map (lambda (k) (string-append "~" k)) (key-delta-changed d))
          (map (lambda (k) (string-append "-" k)) (key-delta-removed d))))
