#lang racket/base

;; Unit tests for tree-digest (st-cly): the order-independent content hash of a
;; directory TREE. The properties that matter — order-independence, sensitivity to
;; content AND location, recursion, and the #f-on-absent contract.

(require rackunit
         racket/file
         "tree-digest.rkt")

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

(delete-directory/files tmp)
