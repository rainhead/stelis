#lang racket/base

;; The content-addressed block store under `.stelis/blocks/` (st-1e5, ADR 0010).
;;
;; WHAT IT IS FOR. The observation history is the one part of state DESIGNED to
;; grow forever, and it was growing badly: a trace-record carried its keyed
;; artifacts' whole (key -> hash) map INLINE, so every build that re-produced
;; `notes/` rewrote a line naming every species, whether or not any of them moved.
;; Here a map is written once, under its own address, and the record names it. Two
;; builds that observed the same map share one block — so the history's growth
;; tracks how often things CHANGE rather than how often the build runs.
;;
;; WHAT IT IS NOT. This gives dedup of IDENTICAL maps, not per-KEY sharing. One
;; changed species still writes a whole new block. Real per-key sharing needs a
;; trie, which is a separate and much larger design; do not describe this as a
;; Merkle tree, because it is one node deep.
;;
;; THE NAME IS A CLAIM, AND `block-ref` CHECKS IT. A block's filename is the CID of
;; its own bytes, so reading re-addresses what it read and refuses a mismatch. That
;; is the property a hash-in-a-field-beside-the-payload cannot give: silent
;; corruption is DETECTED here rather than decoded into a plausible-looking value.
;;
;; MISSING IS NOT FATAL — same contract as the cache sidecars, the trace, and the
;; history log. An absent, unreadable, corrupt, or mis-addressed block reads as #f,
;; and the caller degrades (a timeline loses a point; a graph snapshot is
;; unavailable). Deleting `.stelis/` forgets, it never breaks.

(require racket/contract
         racket/file
         (only-in "dasl.rkt" cid->string content->cid)
         (only-in "drisl.rkt" drisl-encode drisl-decode drisl-cid))

(provide (contract-out
          [blocks-dir  (-> path-string? path?)]
          [block-path  (-> path-string? string? path?)]
          [block-put!  (-> path-string? any/c string?)]
          [block-ref   (-> path-string? string? any/c)]))

(define (blocks-dir state-dir) (build-path state-dir "blocks"))

;; A block's file is named by its CID and nothing else — no extension to strip, no
;; second naming scheme that could disagree with the address.
(define (block-path state-dir cid) (build-path (blocks-dir state-dir) cid))

;; block-put! : path-string any -> string
;; Store a DRISL value and return its CID. Content-addressed, so storing the same
;; value twice is a no-op rather than a rewrite — which is exactly the dedup this
;; module exists for. Raises only if the value has no DRISL encoding (a bug in the
;; caller, not a state condition).
(define (block-put! state-dir v)
  (define bytes (drisl-encode v))
  (define cid (cid->string (drisl-cid v)))
  (define f (block-path state-dir cid))
  (unless (file-exists? f)
    (make-directory* (blocks-dir state-dir))
    ;; 'replace rather than 'error: two concurrent builds may write the same block,
    ;; and since the name is the content they cannot disagree about what is in it.
    (call-with-output-file f #:exists 'replace
      (lambda (o) (write-bytes bytes o))))
  cid)

;; block-ref : path-string string -> (or/c any #f)
;; The stored value, or #f when it is absent, unreadable, not valid DRISL, or does
;; not hash to the name it was filed under. The last case is the point: a block
;; that has been corrupted on disk is refused rather than returned.
(define (block-ref state-dir cid)
  (define f (block-path state-dir cid))
  (and (file-exists? f)
       (with-handlers ([exn:fail? (lambda (_) #f)])
         (define bytes (file->bytes f))
         (and (string=? cid (cid->string (content->cid bytes 'drisl)))
              (drisl-decode bytes)))))
