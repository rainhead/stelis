#lang racket/base

;; Unit tests for the block store (st-1e5): content-addressed storage under
;; .stelis/blocks/. The three properties that matter are DEDUP (the reason the
;; layer exists — the observation history stops rewriting an unchanged map every
;; build), VERIFICATION (a block's name is a claim about its bytes, and reading
;; checks it), and GRACEFUL ABSENCE (missing or damaged state is #f, never fatal —
;; the same contract the cache sidecars and the history log hold).

(require rackunit
         racket/file
         (only-in "dasl.rkt" cid->string content->cid)
         (only-in "drisl.rkt" drisl-encode)
         "blockstore.rkt")

(define tmp (make-temporary-file "stelis-blockstore-test-~a" 'directory))

;; --- Round trip ----------------------------------------------------------------

(define v (hash "one.txt" "h1" "two.txt" "h2"))
(define cid (block-put! tmp v))

(check-equal? (block-ref tmp cid) v "a stored value reads back identical")
(check-true (file-exists? (block-path tmp cid)) "and lives at its own CID")
(check-equal? (cid->string (content->cid (file->bytes (block-path tmp cid)) 'drisl))
              cid
              "the filename is the CID of the file's own bytes")

;; --- Dedup: the whole point ----------------------------------------------------

(check-equal? (block-put! tmp (hash "two.txt" "h2" "one.txt" "h1")) cid
              "the same map stores under the same CID however it was built")
(check-equal? (length (directory-list (blocks-dir tmp))) 1
              "...and does not write a second file — an unchanged map costs nothing")

(define other (block-put! tmp (hash "one.txt" "CHANGED" "two.txt" "h2")))
(check-not-equal? other cid "a changed value gets a different address")
(check-equal? (length (directory-list (blocks-dir tmp))) 2
              "and only then is a second block written")

;; --- Verification: the name is checked, not trusted -----------------------------

(define damaged (block-put! tmp (hash "victim" "x")))
(check-equal? (block-ref tmp damaged) (hash "victim" "x") "readable before damage")

;; Overwrite with a DIFFERENT but perfectly valid DRISL block. A reader that
;; trusted the filename would hand back the wrong value and never know.
(display-to-file (drisl-encode (hash "victim" "tampered"))
                 (block-path tmp damaged) #:exists 'replace)
(check-false (block-ref tmp damaged)
             "a block that no longer hashes to its own name is refused, not returned")

;; Garbage that is not even DRISL is likewise a miss rather than an exception.
(display-to-file "not cbor at all" (block-path tmp damaged) #:exists 'replace)
(check-false (block-ref tmp damaged) "unparseable bytes read as absent")

;; --- Graceful absence ------------------------------------------------------------

(check-false (block-ref tmp "bafyreiaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa")
             "an unknown CID is #f")
(check-false (block-ref (build-path tmp "no-such-dir") cid)
             "so is a state directory that does not exist")

;; --- Values, not just maps -------------------------------------------------------

(check-equal? (block-ref tmp (block-put! tmp '(1 "two" #"three"))) '(1 "two" #"three")
              "any DRISL value can be a block, not only keyed maps")

(delete-directory/files tmp)
