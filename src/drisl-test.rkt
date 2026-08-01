#lang racket/base

;; Conformance + unit tests for DRISL (st-b7v).
;;
;; The bulk of this file is not hand-written assertions but a RUNNER over the
;; vendored fixtures in vendor/dasl-testing (see its README for provenance and the
;; pinned upstream commit). That is deliberate: the encoding's authority is the
;; suite, and hand-transcribed cases would drift from it silently.
;;
;; WHICH CASES WE RUN. The suite covers several specs at once and its cases
;; CONTRADICT each other across tags on purpose — half-precision `f93e00` is a
;; valid `rfc8949` roundtrip and an invalid `dag-cbor` input. Upstream runs all of
;; them and publishes a matrix; a single implementation cannot pass all of them and
;; is not meant to. So we run the tags DRISL and the DASL CID actually consist of —
;; `dag-cbor`, `basic`, `dasl-cid` — and skip the rest rather than pretend. The
;; skipped count is asserted below, so a fixture refresh that adds cases in a tag we
;; claim shows up as a failure instead of vanishing into the skip pile.
;;
;; ONE NAMED EXCLUSION: "Big DASL CID" is BDASL (blake3, multihash 0x1e). dasl.rkt
;; implements sha-256 only, by decision, so that case is skipped by name.
;;
;; `invalid_out` cases cannot be run from fixture bytes here. Upstream decodes them
;; with a PERMISSIVE CBOR library and then asks the strict encoder to refuse the
;; resulting value; we have no permissive reader (and want none). So those cases are
;; covered at the bottom by constructing the offending Racket value directly, which
;; is the same assertion without the second parser.

(require rackunit
         json
         racket/list
         racket/path
         racket/runtime-path
         (only-in file/sha1 hex-string->bytes bytes->hex-string)
         "dasl.rkt"
         "drisl.rkt")

(define-runtime-path fixtures-dir "../vendor/dasl-testing/fixtures/cbor")

;; The specs this repo claims. A case is ours if it carries any of these tags.
(define CLAIMED '("basic" "dag-cbor" "dasl-cid"))

;; name -> why it is skipped despite carrying a claimed tag.
(define SKIP-BY-NAME
  (hash "Big DASL CID"
        "BDASL: blake3 (0x1e), and dasl.rkt is sha-256 only"))

(define (claimed? test)
  (and (not (hash-has-key? SKIP-BY-NAME (hash-ref test 'name "")))
       (for/or ([t (in-list (hash-ref test 'tags '()))])
         (member t CLAIMED))
       #t))

;; --- The runner ---------------------------------------------------------------

(define ran 0)
(define skipped 0)

(define (run-fixture-file path)
  (define tests (call-with-input-file path read-json))
  (for ([t (in-list tests)])
    (define name (hash-ref t 'name))
    (define type (hash-ref t 'type))
    (define data (hex-string->bytes (hash-ref t 'data)))
    (define label (format "~a [~a] ~a" (file-name-from-path path) type name))
    (cond
      [(not (claimed? t)) (set! skipped (add1 skipped))]
      ;; see the header: run from a constructed value instead, at the bottom
      [(string=? type "invalid_out") (set! skipped (add1 skipped))]
      [else
       (set! ran (add1 ran))
       (case type
         [("roundtrip")
          ;; Decoding then re-encoding must reproduce the bytes EXACTLY. This is
          ;; the property the whole design leans on: one value, one spelling.
          (check-equal? (bytes->hex-string (drisl-encode (drisl-decode data)))
                        (bytes->hex-string data)
                        label)]
         [("invalid_in")
          (check-exn exn:fail? (lambda () (drisl-decode data)) label)]
         [else (fail (format "unknown fixture type ~s in ~a" type label))])])))

(for ([p (in-list (sort (map path->string (directory-list fixtures-dir)) string<?))])
  (run-fixture-file (build-path fixtures-dir p)))

;; Pin the split so a fixture refresh cannot quietly move cases out of coverage.
(check-equal? ran 82 "fixture cases actually executed")
(check-equal? skipped 22 "fixture cases skipped (unclaimed tags, invalid_out, BDASL)")
(check-equal? (+ ran skipped) 104 "every vendored case is accounted for, one way or the other")

;; --- invalid_out, as constructed values ---------------------------------------

(check-exn #rx"keys must be strings" (lambda () (drisl-encode (hash 1 0)))
           "map with int key")
(check-exn #rx"not in the DRISL data model" (lambda () (drisl-encode +nan.0)) "NaN")
(check-exn #rx"not in the DRISL data model" (lambda () (drisl-encode +inf.0)) "Inf")
(check-exn #rx"not in the DRISL data model" (lambda () (drisl-encode -inf.0)) "-Inf")
(check-exn #rx"no bignums" (lambda () (drisl-encode (expt 2 64))) "bignum, positive")
(check-exn #rx"no bignums" (lambda () (drisl-encode (- (add1 (expt 2 64)))))
           "bignum, negative")
;; The remaining invalid_out fixtures — 'undefined', an unassigned simple value, a
;; datetime tag — have no Racket value that maps to them at all, so refusal is
;; structural: encode-value's else clause has nothing to dispatch on.
(check-exn #rx"no DRISL encoding" (lambda () (drisl-encode 'undefined)) "a bare symbol")
(check-exn #rx"no DRISL encoding" (lambda () (drisl-encode 1/2)) "a rational")
(check-exn #rx"no DRISL encoding" (lambda () (drisl-encode (vector 1 2))) "a vector")

;; --- The data model, as unit tests --------------------------------------------

(define (round-trip v) (drisl-decode (drisl-encode v)))

(check-equal? (round-trip drisl-null) drisl-null "null survives")
(check-equal? (round-trip '()) '() "the empty array is a list, not null")
(check-equal? (round-trip (hash)) (hash) "the empty map")
(check-equal? (round-trip (list 1 "two" #"three" #t drisl-null))
              (list 1 "two" #"three" #t drisl-null)
              "a heterogeneous array")
(check-equal? (round-trip (hash "a" 1 "aa" 2 "b" 3)) (hash "a" 1 "aa" 2 "b" 3)
              "a map keyed in an order that is not its canonical one")
(check-equal? (round-trip -0.0) -0.0 "negative zero keeps its sign")
(check-equal? (round-trip (expt 2 53)) (expt 2 53) "beyond JS's safe integers")

;; Canonical order is a property of the ENCODING, not of the caller's insertion
;; order — the whole point, since a Racket hash has no order to preserve.
(check-equal? (bytes->hex-string (drisl-encode (hash "b" 2 "aa" 3 "a" 1)))
              "a361610161620262616103"
              "keys emit length-first regardless of how the hash was built")

;; --- The seam to dasl.rkt -----------------------------------------------------

(define c (content->cid #"" 'raw))

(check-equal? (round-trip c) c "a CID survives a round trip as a value")
(check-equal? (round-trip (hash "link" c)) (hash "link" c) "...and nested in a map")
(check-eq? (cid-codec (drisl-cid (hash "a" 1))) 'drisl
           "drisl-cid addresses a block as DRISL, not as a raw blob")
(check-equal? (drisl-cid (hash "a" 1 "b" 2)) (drisl-cid (hash "b" 2 "a" 1))
              "two hashes with the same contents get the same address")
(check-not-equal? (drisl-cid (hash "a" 1)) (drisl-cid (hash "a" 2))
                  "and different contents get different ones")

;; --- Regressions from the st-b7v review ---------------------------------------

;; An eq?-keyed hash can hold two DISTINCT string objects that are `equal?`, which
;; would encode as a duplicate map key — bytes this module's own decoder refuses.
(let ([a (string-copy "k")] [b (string-copy "k")])
  (check-equal? (hash-count (hasheq a 1 b 2)) 2 "eq? keys really can collide this way")
  (check-exn #rx"equal\\?-keyed" (lambda () (drisl-encode (hasheq a 1 b 2)))
             "so an eq?-keyed hash is refused outright")
  (check-exn #rx"equal\\?-keyed" (lambda () (drisl-encode (hasheq "k" 1)))
             "...even when it happens to hold only one key"))
(check-equal? (drisl-decode (drisl-encode (make-hash '(("k" . 1))))) (hash "k" 1)
              "a MUTABLE equal?-keyed hash is fine: mutability was never the risk")

;; The one-byte simple-value form (major 7, ai 24) puts the value in the NEXT byte,
;; so a diagnostic that reports the nibble names the head instead of the fault.
(check-exn #rx"simple value 32 is unassigned"
           (lambda () (drisl-decode (hex-string->bytes "f820")))
           "f820 is simple value 32, not 24")
(check-exn #rx"simple value 0 is written in two bytes"
           (lambda () (drisl-decode (hex-string->bytes "f800")))
           "and a value under 32 in that form is non-minimal besides")
