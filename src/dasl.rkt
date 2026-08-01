#lang racket/base

;; DASL primitives (st-b7v): ONE spec'd canonical encoding for state.
;;
;; State carried THREE ad-hoc answers to "what are these bytes' identity?" — raw
;; bytes -> sha1 (cache.rkt), "path=hash" lines joined by \n -> sha1
;; (tree-digest.rkt's digest-of-pairs), and (format "~s" datum) -> sha1 (model.rkt's
;; graph-digest). So DESIGN's day-one determinism commitment rested on Racket's
;; printer and on hash iteration order staying put across versions. DASL replaces
;; them with a spec, and with an address that says what it addresses. Two are now
;; retired — the graph snapshot (st-b7v) and digest-of-pairs (st-1e5, see
;; keyed-block.rkt); a plain 'file artifact's sha1 is the one that remains.
;;
;; THIS SLICE IS CID ONLY. DRISL (the CBOR profile) is the next commit, and the
;; keyed-observation payoff — where an artifact's roll-up digest BECOMES the CID of
;; its per-key block, so cache.rkt's asserted "the two granularities can never
;; disagree" turns structural — is st-1e5. Nothing here is wired into the cache or
;; the history yet; sha1 remains the live content hash until it is.
;;
;; A CID here is exactly the DASL profile of CIDv1, nothing wider:
;;
;;     0x01  0x55 | 0x71   0x12   0x20   <32-byte sha-256 digest>
;;     ver   codec          sha-256 size
;;
;; codec 0x55 = raw (a blob: file bytes) and 0x71 = DRISL (a structured block;
;; the same code dag-cbor uses — atproto's data model calls DRISL its successor).
;; Every other CIDv1 is REFUSED, and each refusal is its own case in
;; hyphacoop/dasl-testing's fixtures/cbor/cid.json: CIDv0, a codec that is neither
;; raw nor cbor, SHA-1, a digest whose length disagrees with the declared size, a
;; link missing its 0x00 prefix, and tag 42 written long-form (d9002a, not d82a).
;;
;; STRICT BY DECISION, not by taste. The suite types out-of-order map keys,
;; duplicate keys, integer keys, and every malformed CID above as `invalid_in` —
;; the failing side is the DECODER, so rejecting is conformance, not defensiveness.
;; Hence the parsers here raise rather than return #f: a caller that wants a soft
;; answer wraps, but nothing gets to quietly accept a non-DASL address.
;;
;; The base32 is RFC 4648, lowercase, UNPADDED — the multibase `b` form. Racket's
;; `base32` package cannot serve: it implements CROCKFORD base32 (it folds O/o->0
;; and I/L/l/i->1, and puts `c` at index 12), which is a different alphabet
;; entirely. Its source also carries no license, so this is written from the RFC.

(require racket/contract
         (only-in sha sha256))

(provide (contract-out
          [cid?         predicate/c]
          [cid-codec    (-> cid? (or/c 'raw 'drisl))]
          [cid-digest   (-> cid? bytes?)]
          [make-cid     (-> (or/c 'raw 'drisl) bytes? cid?)]
          [content->cid (-> bytes? (or/c 'raw 'drisl) cid?)]
          [cid->string  (-> cid? string?)]
          [string->cid  (-> string? cid?)]
          [cid->bytes   (-> cid? bytes?)]
          [bytes->cid   (-> bytes? cid?)]
          [cid->link-bytes (-> cid? bytes?)]
          [link-bytes->cid (-> bytes? cid?)]
          [base32-encode (-> bytes? string?)]
          [base32-decode (-> string? bytes?)]))

;; --- The profile's constants --------------------------------------------------

(define CID-VERSION 1)
(define CODEC-RAW   #x55)
(define CODEC-DRISL #x71)
(define HASH-SHA256 #x12)
(define DIGEST-SIZE #x20)   ; 32 bytes, and the only size the profile admits
(define CID-BYTES   (+ 4 DIGEST-SIZE))

;; The multibase prefix for base32-lower. Only this one is legal in DASL, so it is
;; a constant rather than a lookup: an unknown prefix is a rejection, not a dispatch.
(define MULTIBASE-B32 #\b)

(define (codec->byte c) (case c [(raw) CODEC-RAW] [(drisl) CODEC-DRISL]))
(define (byte->codec b)
  (cond [(= b CODEC-RAW) 'raw] [(= b CODEC-DRISL) 'drisl] [else #f]))

;; --- The CID itself -----------------------------------------------------------

;; codec  : 'raw | 'drisl — what the addressed bytes ARE, which is the whole reason
;;          a CID beats a bare hash string: the address carries its own kind.
;; digest : bytes — the 32-byte sha-256 of those bytes.
;; Constructed only through make-cid / the parsers, all of which validate, so a
;; cid? value is by construction a legal DASL CID (hence no struct-out: the raw
;; constructor would be a way around that, cf. trace.rkt naming its parts).
(struct cid (codec digest)
  #:transparent #:omit-define-syntaxes #:constructor-name make-cid*)

(define (make-cid codec digest)
  (unless (= DIGEST-SIZE (bytes-length digest))
    (error 'make-cid "sha-256 digest must be ~a bytes; got ~a"
           DIGEST-SIZE (bytes-length digest)))
  (make-cid* codec digest))

;; content->cid : bytes (or/c 'raw 'drisl) -> cid
;; Address these bytes. DASL's CID spec says resources SHOULD NOT be chunked into a
;; Merkle tree but hashed whole — so this is the only way content becomes an
;; address, and there is deliberately no chunking knob.
(define (content->cid bs codec) (make-cid codec (sha256 bs)))

;; --- Binary form --------------------------------------------------------------

(define (cid->bytes c)
  (bytes-append (bytes CID-VERSION (codec->byte (cid-codec c)) HASH-SHA256 DIGEST-SIZE)
                (cid-digest c)))

;; bytes->cid : bytes -> cid
;; Each rejection names the restriction it enforces, because these messages are how
;; a future reader learns the profile without re-reading the spec.
(define (bytes->cid bs)
  (define n (bytes-length bs))
  ;; CIDv0 is a bare multihash (0x12 0x20 ...) with no version or codec byte —
  ;; worth its own message, since it is a real CID, just not one DASL admits.
  (when (and (>= n 2) (= HASH-SHA256 (bytes-ref bs 0)) (= DIGEST-SIZE (bytes-ref bs 1)))
    (error 'bytes->cid "CIDv0 is not a DASL CID (only version 1)"))
  ;; Header before length, so that a SHA-1 CID (whose digest is 20 bytes, hence
  ;; also the wrong total) is rejected as "not sha-256" rather than as a size
  ;; mismatch. The diagnostic should name the restriction that was actually broken.
  (unless (>= n 4)
    (error 'bytes->cid "too short to be a CID: ~a bytes" n))
  (unless (= CID-VERSION (bytes-ref bs 0))
    (error 'bytes->cid "unsupported CID version ~a (only 1)" (bytes-ref bs 0)))
  (define codec (byte->codec (bytes-ref bs 1)))
  (unless codec
    (error 'bytes->cid "codec 0x~x is neither raw (0x55) nor DRISL (0x71)"
           (bytes-ref bs 1)))
  (unless (= HASH-SHA256 (bytes-ref bs 2))
    (error 'bytes->cid "hash 0x~x is not sha-256 (0x12)" (bytes-ref bs 2)))
  (unless (= DIGEST-SIZE (bytes-ref bs 3))
    (error 'bytes->cid "declared digest size ~a is not ~a" (bytes-ref bs 3) DIGEST-SIZE))
  ;; Header is well-formed, so a wrong total means the digest present disagrees
  ;; with the size the header declared.
  (unless (= n CID-BYTES)
    (error 'bytes->cid "declared a ~a-byte digest but carries ~a bytes"
           DIGEST-SIZE (- n 4)))
  (make-cid* codec (subbytes bs 4)))

;; --- Link form (what a DRISL block will carry under tag 42) -------------------
;; The 0x00 prefix is the identity multibase: inside CBOR a CID is a BYTE string,
;; so it needs the "no textual encoding" marker that its string form spends on `b`.

(define (cid->link-bytes c) (bytes-append (bytes 0) (cid->bytes c)))

(define (link-bytes->cid bs)
  (when (zero? (bytes-length bs))
    (error 'link-bytes->cid "empty CID"))
  (unless (zero? (bytes-ref bs 0))
    (error 'link-bytes->cid "CID link is missing its leading 0x00 (identity multibase)"))
  (bytes->cid (subbytes bs 1)))

;; --- String form --------------------------------------------------------------

(define (cid->string c) (string-append (string MULTIBASE-B32) (base32-encode (cid->bytes c))))

(define (string->cid s)
  (when (zero? (string-length s))
    (error 'string->cid "empty string is not a CID"))
  (unless (char=? MULTIBASE-B32 (string-ref s 0))
    (error 'string->cid "multibase prefix ~s is not `b` (base32 lower)" (string-ref s 0)))
  (bytes->cid (base32-decode (substring s 1))))

;; --- base32, RFC 4648, lowercase, unpadded ------------------------------------

(define B32-ALPHABET "abcdefghijklmnopqrstuvwxyz234567")

(define B32-VALUES
  (let ([v (make-vector 128 #f)])
    (for ([ch (in-string B32-ALPHABET)] [i (in-naturals)])
      (vector-set! v (char->integer ch) i))
    (vector->immutable-vector v)))

;; The bit-accumulator both directions share: feed whole units in at one width,
;; drain them at the other, and keep only the bits not yet emitted.
(define (low-bits acc n) (bitwise-and acc (sub1 (arithmetic-shift 1 n))))

(define (base32-encode bs)
  (define out (open-output-string))
  (let loop ([i 0] [acc 0] [bits 0])
    (cond
      [(>= bits 5)
       (define rest (- bits 5))
       (write-char (string-ref B32-ALPHABET (arithmetic-shift acc (- rest))) out)
       (loop i (low-bits acc rest) rest)]
      [(< i (bytes-length bs))
       (loop (add1 i) (+ (arithmetic-shift acc 8) (bytes-ref bs i)) (+ bits 8))]
      ;; A trailing partial group is left-aligned and zero-filled — and NOT padded
      ;; out to a block with `=`, which is what "unpadded" costs on this side.
      [(positive? bits)
       (write-char (string-ref B32-ALPHABET (arithmetic-shift acc (- 5 bits))) out)]
      [else (void)]))
  (get-output-string out))

(define (base32-decode s)
  (define out (open-output-bytes))
  (define-values (acc bits)
    (for/fold ([acc 0] [bits 0]) ([ch (in-string s)])
      (define i (char->integer ch))
      (define v (and (< i 128) (vector-ref B32-VALUES i)))
      (unless v
        ;; Catches uppercase and `=` too: this alphabet is lowercase and unpadded,
        ;; so accepting either would let two spellings name one CID.
        (error 'base32-decode "~s is not an RFC 4648 lowercase base32 character" ch))
      (define acc* (+ (arithmetic-shift acc 5) v))
      (define bits* (+ bits 5))
      (cond
        [(>= bits* 8)
         (define rest (- bits* 8))
         (write-byte (arithmetic-shift acc* (- rest)) out)
         (values (low-bits acc* rest) rest)]
        [else (values acc* bits*)])))
  ;; Leftovers must be a genuine partial group (< 5 bits would have been another
  ;; character) and must be the zero fill the encoder wrote. Anything else is a
  ;; second spelling of the same bytes, which content-addressing cannot afford.
  (unless (< bits 5)
    (error 'base32-decode "trailing ~a bits form an unconsumed character" bits))
  (unless (zero? acc)
    (error 'base32-decode "trailing bits are not zero-filled"))
  (get-output-bytes out))
