#lang racket/base

;; Unit tests for keyed-block (st-1e5): a keyed artifact's per-key map as a DRISL
;; block, and its CID as the artifact's address. The properties that matter are the
;; ones digest-of-pairs did NOT have — an unambiguous encoding, order-independence
;; that belongs to the encoding rather than to the caller, and a duplicate key that
;; is an error rather than a silent collapse — plus the one that makes the whole
;; slice worth doing: the digest is the block's address, so the roll-up and the
;; parts are one object and cannot drift.

(require rackunit
         racket/list
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

;; --- Chunked (st-ml9.7) -------------------------------------------------------
;; A small map is the flat block it always was, CID and all; a large one is a tree
;; whose root is the address, and changing one key rewrites the root and one bucket.
(define (many n [suffix ""])
  (for/list ([i (in-range n)]) (cons (format "days/2026/~a.json" i) (format "h~a~a" i suffix))))

(check-equal? (keyed-tree-blocks (many LEAF-MAX)) (list (keyed-block (many LEAF-MAX)))
              "up to LEAF-MAX entries: one flat block, so a small map's digest never moved")
(check-equal? (keyed-block-digest (many LEAF-MAX))
              (cid->string (drisl-cid (keyed-block (many LEAF-MAX)))))

(define big (many 4400))
(define big-blocks (keyed-tree-blocks big))
(check-true (keyed-node? (car big-blocks)) "a large map's root is a node")
(check-true (for/and ([b (in-list (cdr big-blocks))])
              (or (keyed-node? b) (<= (hash-count b) LEAF-MAX)))
            "and every leaf holds at most LEAF-MAX entries")
(check-equal? (sort (append* (for/list ([b (in-list big-blocks)] #:unless (keyed-node? b)) (hash->list b)))
                    string<? #:key car)
              (sort big string<? #:key car)
              "the leaves together are the map")
(check-equal? (keyed-block-digest big) (cid->string (drisl-cid (car big-blocks))) "the address is the root's")
(check-equal? (keyed-block-digest (reverse big)) (keyed-block-digest big) "order still doesn't matter")
(check-equal? (sort (keyed-node-links (car big-blocks)) string<?)
              (sort (for/list ([b (in-list (cdr big-blocks))]) (cid->string (drisl-cid b))) string<?)
              "the root links exactly its buckets")

(define one-changed (cons (cons "days/2026/7.json" "changed") (remove (assoc "days/2026/7.json" big) big)))
(define after (keyed-tree-blocks one-changed))
(check-equal? (length (remove* big-blocks after)) 2
              "one key changed: a new root and one new bucket, every other block shared")
(check-exn #rx"duplicate key" (lambda () (keyed-tree-blocks (cons (car big) big)))
           "a duplicate key is refused at any size")

;; A node says what it is: a two-element array under NODE-TAG, where a leaf is always
;; a map, so the two never depend on what a leaf's values happen to be.
(check-equal? (car (car big-blocks)) NODE-TAG)
(check-pred hash? (cadr (car big-blocks)))
(check-false (keyed-node? (keyed-block (many 3))) "a leaf is a map, never a node")
(check-false (keyed-node? (keyed-block '())) "nor is the empty map")
(check-true (keyed-node? (cadr (car big-blocks)))
            "the untagged {bucket -> CID} node 3a84ea4 wrote still reads as one, until retention clears it")
(check-equal? (sort (keyed-node-links (cadr (car big-blocks))) string<?)
              (sort (keyed-node-links (car big-blocks)) string<?))
