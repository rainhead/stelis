#lang racket/base

;; Unit tests for keyed-block (st-1e5): a keyed artifact's per-key map as a DRISL
;; block, and its CID as the artifact's address. The properties that matter are the
;; ones digest-of-pairs did NOT have — an unambiguous encoding, order-independence
;; that belongs to the encoding rather than to the caller, and a duplicate key that
;; is an error rather than a silent collapse — plus the one that makes the whole
;; slice worth doing: the digest is the block's address, so the roll-up and the
;; parts are one object and cannot drift.

(require rackunit
         "dasl.rkt"
         "drisl.rkt"
         "keyed-block.rkt")

(define pairs '(("genus/two.txt" . "beta-hash") ("one.txt" . "alpha-hash")))

;; --- The block is the parts, and the digest is its address --------------------

(check-equal? (keyed-block pairs)
              (hash "genus/two.txt" "beta-hash" "one.txt" "alpha-hash")
              "the pairs become a DRISL map, unchanged")
(check-equal? (keyed-block-digest pairs)
              (cid->string (drisl-cid (keyed-block pairs)))
              "the digest IS the block's CID — no second computation to drift")
(check-eq? (cid-codec (string->cid (keyed-block-digest pairs))) 'drisl
           "and it is addressed as a structured block, not as a raw blob")

;; --- Order-independence, now the encoding's property --------------------------

(check-equal? (keyed-block-digest (reverse pairs)) (keyed-block-digest pairs)
              "a shuffled pair list is the same map, hence the same address")

;; --- The ambiguity digest-of-pairs had ----------------------------------------
;; It joined "<key>=<value>" with newlines, so these two DIFFERENT maps both
;; rendered "a=b=c" and collided. Paths containing "=" are legal everywhere we run.

(check-not-equal? (keyed-block-digest '(("a=b" . "c")))
                  (keyed-block-digest '(("a" . "b=c")))
                  "a separator in a key can no longer spell another map")
(check-not-equal? (keyed-block-digest '(("a" . "b\nc" )))
                  (keyed-block-digest '(("a" . "b") ("c" . "")))
                  "...nor can a newline in a value forge an extra entry")

;; --- Duplicates are a bug in the reader, not data ------------------------------

(check-exn #rx"duplicate key"
           (lambda () (keyed-block '(("one.txt" . "h1") ("one.txt" . "h2"))))
           "a duplicate key raises rather than collapsing to the last one")

;; --- Distinctness ---------------------------------------------------------------

(check-not-equal? (keyed-block-digest pairs)
                  (keyed-block-digest '(("genus/two.txt" . "beta-hash")))
                  "dropping a key changes the address")
(check-not-equal? (keyed-block-digest pairs)
                  (keyed-block-digest '(("genus/two.txt" . "beta-hash")
                                        ("one.txt" . "OTHER")))
                  "changing a value changes the address")
(check-not-equal? (keyed-block-digest pairs)
                  (keyed-block-digest '(("genus/two.txt" . "beta-hash")
                                        ("moved.txt" . "alpha-hash")))
                  "moving a file changes the address — location is part of identity")

;; The empty map has a real address: "a directory with nothing in it" is a fact,
;; distinct from tree-digest's #f for "there is no directory".
(check-pred string? (keyed-block-digest '()) "the empty block still has an address")
(check-not-equal? (keyed-block-digest '()) (keyed-block-digest pairs)
                  "and it is not any non-empty one")
