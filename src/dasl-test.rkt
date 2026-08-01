#lang racket/base

;; Unit tests for the DASL primitives (st-b7v). Two bodies of evidence, kept
;; visibly separate because they carry different authority:
;;
;;   1. RFC 4648 section 10's own base32 vectors, lowercased and stripped of `=`.
;;      The encoder is the piece with no DASL fixture behind it (every fixture
;;      encodes a CID *inside* CBOR, never its string form), so it is pinned here
;;      against the RFC directly.
;;   2. The CID cases from hyphacoop/dasl-testing's fixtures/cbor/cid.json,
;;      transcribed as the link bytes they carry under tag 42 — each `invalid_in`
;;      case named after the restriction it exists to enforce. Transcribed rather
;;      than read from the repo on purpose: the suite is not a checkout here, and
;;      CI has no network. A real harness that runs the whole suite is separate
;;      work; this is the subset that pins THIS module.
;;
;; The end-to-end anchor is the empty raw CID, which is widely published and
;; therefore checks the entire path — sha-256, the 4-byte header, base32, and the
;; multibase prefix — against a value nothing in this repo produced.

(require rackunit
         (only-in file/sha1 hex-string->bytes)
         "dasl.rkt")

;; --- base32: RFC 4648 section 10, lowercase and unpadded ----------------------

(define rfc4648-vectors
  '(("" . "") ("f" . "my") ("fo" . "mzxq") ("foo" . "mzxw6")
    ("foob" . "mzxw6yq") ("fooba" . "mzxw6ytb") ("foobar" . "mzxw6ytboi")))

(for ([v (in-list rfc4648-vectors)])
  (check-equal? (base32-encode (string->bytes/utf-8 (car v))) (cdr v)
                (format "RFC 4648 vector: encode ~s" (car v)))
  (check-equal? (base32-decode (cdr v)) (string->bytes/utf-8 (car v))
                (format "RFC 4648 vector: decode ~s" (cdr v))))

;; A whole 5-byte group whose eight 5-bit slices are exactly 0..7 — so the low end
;; of the alphabet is pinned position by position, catching a transcription slip
;; the vectors above would not reach.
(check-equal? (base32-encode (bytes #x00 #x44 #x32 #x14 #xC7)) "abcdefgh"
              "the group spelling symbols 0 through 7")

;; Strictness: each rejection below is a second spelling that content-addressing
;; cannot afford — two strings naming one CID.
(check-exn #rx"lowercase base32" (lambda () (base32-decode "MZXW6")) "uppercase")
(check-exn #rx"lowercase base32" (lambda () (base32-decode "mzxw6===")) "padding")
(check-exn #rx"lowercase base32" (lambda () (base32-decode "mzxw0")) "0 is not in the alphabet")
(check-exn #rx"lowercase base32" (lambda () (base32-decode "mzxw1")) "1 is not in the alphabet")
(check-exn #rx"lowercase base32" (lambda () (base32-decode "mzxw8")) "8 is not in the alphabet")
(check-exn #rx"not zero-filled" (lambda () (base32-decode "mzxw7"))
           "a trailing group whose fill bits are not zero")

;; --- The end-to-end anchor ----------------------------------------------------

(define empty-raw-cid "bafkreihdwdcefgh4dqkjv67uzcmw7ojee6xedzdetojuzjevtenxquvyku")

(check-equal? (cid->string (content->cid #"" 'raw)) empty-raw-cid
              "the published empty raw CID, computed end to end")
(check-equal? (cid->string (string->cid empty-raw-cid)) empty-raw-cid
              "and it parses back to itself")
(check-eq? (cid-codec (string->cid empty-raw-cid)) 'raw "its codec reads back as raw")

;; --- CID cases from fixtures/cbor/cid.json ------------------------------------
;; Each `data` below is the tag-42 payload with its 0x00 identity-multibase prefix
;; intact — i.e. exactly what a DRISL decoder will hand link-bytes->cid.

(define (link hex) (hex-string->bytes hex))

;; roundtrip | "valid CID with short tag"
(define valid-link
  (link "00015512205891b5b522d5df086d0ff0b110fbd9d21bb4fc7163af34d08286a2e846f6be03"))
(define valid-cid (link-bytes->cid valid-link))

(check-eq? (cid-codec valid-cid) 'raw "the fixture CID is a raw blob")
(check-equal? (cid->string valid-cid)
              "bafkreicysg23kiwv34eg2d7qweipxwosdo2py4ldv42nbauguluen5v6am"
              "its string form")
(check-equal? (cid->link-bytes valid-cid) valid-link
              "and the link bytes round-trip, 0x00 prefix included")

;; invalid_in | "CID with no null byte" — the same CID without the prefix
(check-exn #rx"leading 0x00"
           (lambda () (link-bytes->cid
                       (link "015512205891b5b522d5df086d0ff0b110fbd9d21bb4fc7163af34d08286a2e846f6be03")))
           "a link must carry the identity multibase")

;; invalid_in | "empty CID"
(check-exn #rx"empty CID" (lambda () (link-bytes->cid (link ""))) "no bytes at all")

;; invalid_in | "invalid CID" — the prefix and nothing after it
(check-exn #rx"too short" (lambda () (link-bytes->cid (link "00"))) "prefix only")

;; invalid_in | "CIDv0"
(check-exn #rx"CIDv0"
           (lambda () (link-bytes->cid
                       (link "00122022ad631c69ee983095b5b8acd029ff94aff1dc6c48837878589a92b90dfea317")))
           "a bare multihash is a real CID, just not a DASL one")

;; invalid_in | "CIDv1 that isn't raw or cbor" — codec 0x70 (dag-pb)
(check-exn #rx"neither raw"
           (lambda () (link-bytes->cid
                       (link "0001701220e9822efc7c48027a5429fdbd988d02b2b8e4eaee8f62c32bd1021dcf922e05de")))
           "only two codecs are blessed")

;; invalid_in | "disallowed hash type (SHA-1)"
(check-exn #rx"not sha-256"
           (lambda () (link-bytes->cid (link "0001551114f572d396fae9206628714fb2ce00f72e94f2258f")))
           "sha-1 is refused as a hash, not merely as a length")

;; invalid_in | "short hash digest" — declared size 0x1f
(check-exn #rx"declared digest size"
           (lambda () (link-bytes->cid
                       (link "000155121f5891b5b522d5df086d0ff0b110fbd9d21bb4fc7163af34d08286a2e846f6be")))
           "the only admissible size is 32")

;; invalid_in | "long hash digest" — declared size 0x21
(check-exn #rx"declared digest size"
           (lambda () (link-bytes->cid
                       (link "00015512215891b5b522d5df086d0ff0b110fbd9d21bb4fc7163af34d08286a2e846f6be0300")))
           "...in both directions")

;; invalid_in | "invalid hash size" — header says 32, only 31 bytes follow
(check-exn #rx"carries 31 bytes"
           (lambda () (link-bytes->cid
                       (link "00015512205891b5b522d5df086d0ff0b110fbd9d21bb4fc7163af34d08286a2e846f6be")))
           "a declared size that disagrees with the digest present")

;; --- Construction ---------------------------------------------------------------

(check-exn #rx"must be 32 bytes" (lambda () (make-cid 'raw #"short"))
           "a CID cannot be built around a non-sha-256 digest")

;; A DRISL block and a raw blob with identical bytes get DIFFERENT addresses —
;; the point of carrying the codec in the address rather than beside it.
(check-not-equal? (cid->string (content->cid #"payload" 'raw))
                  (cid->string (content->cid #"payload" 'drisl))
                  "codec is part of the identity")
(check-eq? (cid-codec (content->cid #"payload" 'drisl)) 'drisl "and it survives the trip")
