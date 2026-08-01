#lang racket/base

;; Unit tests for tree-digest (st-cly): the order-independent content hash of a
;; directory TREE. The properties that matter — order-independence, sensitivity to
;; content AND location, recursion, and the #f-on-absent contract.

(require rackunit
         racket/file
         file/sha1
         "tree-digest.rkt"
         "keyed-block.rkt")

(define tmp (make-temporary-file "stelis-tree-test-~a" 'directory))
(define (in name) (build-path tmp name))

;; absent / empty ---------------------------------------------------------------
(check-false (tree-digest (in "nope")) "a non-existent directory digests to #f")

(define empty-dir (in "empty"))
(make-directory empty-dir)
(check-pred string? (tree-digest empty-dir) "an existing empty directory has a digest")

;; a small tree with a nested subdir --------------------------------------------
(define a (in "a"))
(make-directory a)
(make-directory (build-path a "genus"))
(display-to-file "alpha" (build-path a "one.txt"))
(display-to-file "beta"  (build-path a "genus" "two.txt"))
(define d0 (tree-digest a))
(check-pred string? d0)

;; order-independence: a byte-identical tree built file-by-file in a DIFFERENT
;; creation order digests identically (the sort, not the FS traversal, decides).
(define b (in "b"))
(make-directory b)
(make-directory (build-path b "genus"))
(display-to-file "beta"  (build-path b "genus" "two.txt")) ; nested first this time
(display-to-file "alpha" (build-path b "one.txt"))
(check-equal? (tree-digest b) d0 "same tree, different creation order -> same digest")

;; content sensitivity: changing one file's bytes changes the digest.
(display-to-file "ALPHA!" (build-path b "one.txt") #:exists 'replace)
(check-not-equal? (tree-digest b) d0 "an edited file changes the tree digest")

;; location sensitivity: same bytes at a different relative path -> different digest.
(define c (in "c"))
(make-directory c)
(display-to-file "alpha" (build-path c "renamed.txt")) ; same content as a/one.txt...
(make-directory (build-path c "genus"))
(display-to-file "beta"  (build-path c "genus" "two.txt"))
(check-not-equal? (tree-digest c) d0 "a moved/renamed file changes the tree digest")

;; tree-hashes: the per-file layer under the digest (st-6dv) --------------------
(check-false (tree-hashes (in "nope")) "no directory -> no per-file pairs")
(check-equal? (tree-hashes a)
              (list (cons "genus/two.txt" (sha1 (open-input-string "beta")))
                    (cons "one.txt"       (sha1 (open-input-string "alpha"))))
              "each file paired with its content hash, sorted by relative path")
;; The digest is not merely derived from the pairs, it is their ADDRESS (st-1e5) —
;; so the two granularities cannot drift apart, and there is no second computation.
(check-equal? (keyed-block-digest (tree-hashes a)) (tree-digest a)
              "tree-digest is the CID of tree-hashes as a keyed block")

;; Order-independence now belongs to the ENCODING, not to the caller's sorting:
;; DRISL orders map keys canonically, so a shuffled pair list is the same address.
(check-equal? (keyed-block-digest (reverse (tree-hashes a))) (tree-digest a)
              "the same map digests identically however the pairs were ordered")

;; The old "<key>=<value>" line join could be spelled two ways — {"a=b" -> "c"} and
;; {"a" -> "b=c"} both rendered "a=b=c". A block has no delimiter to smuggle.
(check-not-equal? (keyed-block-digest '(("a=b" . "c")))
                  (keyed-block-digest '(("a" . "b=c")))
                  "keys and values can no longer collide through the separator")

(delete-directory/files tmp)
