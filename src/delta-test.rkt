#lang racket/base

;; Unit tests for the delta core (st-2hh, st-066 H2): the pure diff of two keyed
;; (part -> value) maps into a NAMED three-way key-delta, and the prospective fold
;; that diffs a keyed artifact's history tail against a live on-disk map. The
;; properties that matter — the three-way partition (added/removed/changed) is
;; exact and sorted; value-difference (not just key presence) drives `changed`;
;; the fold reads the MOST RECENT recorded point; too-short history yields #f; an
;; all-same re-production is an EMPTY delta (not #f); the "N of M" denominator
;; counts removed keys too (so N never exceeds M); the prose names the subset.

(require rackunit
         "delta.rkt"
         "history.rkt")   ; key-observation constructor + accessors

;; a key-observation with a throwaway record — the fold only reads build + keys.
(define (obs build keys) (key-observation build keys #f))

;; diff-key-maps: the three-way partition ---------------------------------------
(let-values ([(added removed changed)
              (diff-key-maps
               '(("seattle" . "h1") ("tacoma" . "h2") ("olympia" . "h3"))
               '(("seattle" . "h1") ("tacoma" . "hX") ("chelan"  . "h4")))])
  (check-equal? added   '("chelan")  "key only in `new` is added")
  (check-equal? removed '("olympia") "key only in `old` is removed")
  (check-equal? changed '("tacoma")  "key in both with a differing value is changed")
  ;; seattle: present in both, same value -> named in NONE of the three lists
  (check-false (member "seattle" (append added removed changed))
               "an unchanged key appears in no partition"))

;; identical maps -> all empty
(let-values ([(a r c) (diff-key-maps '(("k" . "v")) '(("k" . "v")))])
  (check-equal? (list a r c) '(() () ()) "identical maps: nothing moved"))

;; sorting: added/removed/changed each come out sorted regardless of input order
(let-values ([(added removed changed)
              (diff-key-maps
               '(("b" . "1") ("a" . "1"))
               '(("d" . "1") ("c" . "1") ("a" . "9")))])
  (check-equal? added   '("c" "d") "added sorted")
  (check-equal? removed '("b")     "removed sorted")
  (check-equal? changed '("a")     "changed sorted"))

;; prospective-delta: history tail vs a LIVE on-disk map ------------------------
(check-false (prospective-delta 'place-maps '() '(("seattle" . "h")))
             "no prior observation -> nothing to diff against -> #f")

;; the full three-way move, and tail-selection: `from` is history's TAIL (build 4,
;; NOT the older build 2); `to` is the live map, whose build is 'pending.
(define d
  (prospective-delta
   'place-maps
   (list (obs 2 '(("seattle" . "old")))                   ; older, ignored
         (obs 4 '(("seattle" . "h1") ("tacoma" . "h2")))) ; tail = `from`
   '(("seattle" . "hX") ("olympia" . "h3"))))             ; live = `to`
(check-equal? (key-delta-artifact d) 'place-maps)
(check-equal? (key-delta-from-build d) 4 "from = history tail's build (older points ignored)")
(check-equal? (key-delta-to-build d) 'pending "to = the pending live map")
(check-equal? (key-delta-added d)   '("olympia"))
(check-equal? (key-delta-removed d) '("tacoma"))
(check-equal? (key-delta-changed d) '("seattle"))
(check-equal? (key-delta-count d) 3 "added + removed + changed")
(check-equal? (key-delta-total d) 3 "total = union of from/to keys (|to|=2 + removed=1)")

;; an all-same re-production is an EMPTY delta, not #f (early cutoff, per-key)
(define same
  (prospective-delta 'feeds
                     (list (obs 5 '(("x" . "h") ("y" . "h"))))
                     '(("x" . "h") ("y" . "h"))))
(check-not-false same "a re-production to identical content still yields a delta")
(check-equal? (key-delta-count same) 0 "...an empty one — nothing moved")

;; key-delta->string: names the subset, +added ~changed -removed
(check-equal? (key-delta->string d)
              "3 of 3 keys: +olympia ~seattle -tacoma"
              "prose names the moved subset; denominator counts removed too (N never > M)")
(check-equal? (key-delta->string same)
              "no keys moved (2 total)"
              "an empty delta reads plainly")

;; regression: a removal-heavy delta must keep N ≤ M. from {a,b} -> to {a} leaves
;; the to-side at 1, but 1 key moved out of the 2 involved — "1 of 2", never "1 of 1".
(define rm (prospective-delta 'feeds
                              (list (obs 1 '(("a" . "h") ("b" . "h"))))
                              '(("a" . "h"))))
(check-equal? (key-delta-total rm) 2 "removed key still counts toward the total")
(check-equal? (key-delta->string rm) "1 of 2 keys: -b")

;; build-key-delta: the RETROSPECTIVE fold at one build ---------------------------
;; The properties that matter: the `from` side is the previous OBSERVATION (the
;; previous genuine re-production), not the previous build; the two non-delta
;; answers stay distinguishable; and 'not-produced is an ANSWER (nothing moved),
;; while 'no-basis is a refusal to answer.

;; produced at the build we ask about -> diff against the observation before it
(define bd (build-key-delta
            'notes
            (list (obs 2 '(("apis mellifera.json" . "h1") ("bombus mixtus.json" . "h2")))
                  (obs 7 '(("apis mellifera.json" . "hX") ("osmia lignaria.json" . "h3"))))
            7))
(check-equal? (key-delta-from-build bd) 2 "from = the previous OBSERVATION, not build 6")
(check-equal? (key-delta-to-build bd) 7 "to = the build asked about (recorded, not 'pending)")
(check-equal? (key-delta-changed bd) '("apis mellifera.json"))
(check-equal? (key-delta-added bd)   '("osmia lignaria.json"))
(check-equal? (key-delta-removed bd) '("bombus mixtus.json"))
(check-equal? (key-delta-total bd) 3 "|to| = 2 plus the 1 removed")

;; key-delta-moved: one flat sorted list, unmarked — a removed key moved too
(check-equal? (key-delta-moved bd)
              '("apis mellifera.json" "bombus mixtus.json" "osmia lignaria.json")
              "every moved key, sorted, no +~- markers")

;; the producer cache-skipped the build asked about: nothing moved THEN. An answer
;; (the empty key set), never a refusal — this is exactly the early-cutoff case.
(check-equal? (build-key-delta 'notes (list (obs 2 '(("a.json" . "h")))) 7)
              'not-produced
              "no observation at the build asked about -> nothing moved then")

;; a first-ever production has no basis to diff against. Every key is new, which
;; must NOT be reported as "these keys moved" — a caller would read a first build
;; as an incremental one and skip rebuilding everything else.
(check-equal? (build-key-delta 'notes (list (obs 7 '(("a.json" . "h")))) 7)
              'no-basis
              "produced, but nothing earlier to diff -> refuse rather than claim a delta")

;; NO per-key timeline at all — a never-built artifact, or a typo'd name. This must
;; refuse, not answer "nothing moved": an empty key set would tell a targeted caller
;; to rebuild nothing, which is precisely the wrong instruction when the truth is
;; "I have never seen this artifact".
(check-equal? (build-key-delta 'notes '() 7) 'no-basis "empty timeline refuses to answer")

;; a re-production to identical content is an EMPTY delta, not 'not-produced:
;; the producer DID run, and the truthful answer is "zero keys moved".
(define bsame (build-key-delta 'notes
                               (list (obs 3 '(("a.json" . "h")))
                                     (obs 4 '(("a.json" . "h"))))
                               4))
(check-not-false (key-delta? bsame) "ran and produced identical content -> still a delta")
(check-equal? (key-delta-count bsame) 0 "...an empty one")
(check-equal? (key-delta-moved bsame) '() "no keys to hand a targeted rebuild")
