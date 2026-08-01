#lang racket/base

;; DRISL (st-b7v): the deterministic CBOR profile a DASL block is written in —
;; the encoding half of the story [`dasl.rkt`](dasl.rkt) addresses. atproto's data
;; model calls DRISL "the successor to DAG-CBOR", and it shares dag-cbor's codec
;; number (0x71); it is a strict subset of CBOR Core, not a fork of it.
;;
;; WHY THIS EXISTS. Determinism is a day-one DESIGN property, and today it rests on
;; Racket's printer: graph-digest hashes `(format "~s" datum)`, and digest-of-pairs
;; hashes "path=hash" lines. Both are canonical only by habit. A DRISL block is
;; canonical by specification — one value has exactly one byte sequence — which is
;; what lets its sha-256 be an identity rather than a fingerprint of a printing.
;;
;; THE DATA MODEL, in Racket terms:
;;
;;     'null                     <-> f6           (drisl-null)
;;     #t / #f                   <-> f5 / f4
;;     exact-integer             <-> major 0/1, the full [-(2^64), 2^64-1]
;;     flonum                    <-> fb, ALWAYS 64-bit, never NaN or an infinity
;;     bytes                     <-> major 2
;;     string                    <-> major 3 (valid UTF-8, never normalized)
;;     list                      <-> major 4
;;     immutable hash, STRING keys <-> major 5, canonically ordered
;;     cid (dasl.rkt)            <-> tag 42 over the 0x00-prefixed link bytes
;;
;; Anything else — a symbol, a rational, a mutable box, a hash with symbol keys —
;; has no DRISL encoding and is refused. Callers holding symbol-keyed data (the
;; history envelope does) convert at this boundary; that is st-1e5's work.
;;
;; MAP KEY ORDER is length-first, then bytewise. Two conventions exist in the wild
;; (RFC 7049 canonical, which dag-cbor took, vs RFC 8949 4.2.1's bytewise-on-
;; encoded-key), and for DRISL they are the SAME rule: a CBOR text string's head
;; byte is monotonic in length (0x60-0x77, then 0x78+, 0x79+ ...), so comparing
;; encoded keys bytewise sorts by length first anyway — and DRISL admits no
;; non-string keys, which is the only case where the two would diverge. The
;; vendored fixture "map keys in correct order" is tagged BOTH rfc8949 and
;; dag-cbor, which is the suite asserting exactly that.
;;
;; STRICTNESS IS CONFORMANCE, not defensiveness. The decoder refuses non-minimal
;; heads, indefinite lengths, any tag but 42, non-string map keys, out-of-order or
;; duplicate keys, 16- and 32-bit floats, NaN and infinities, bignums, undefined
;; and unassigned simple values, invalid UTF-8, and trailing bytes after the
;; top-level item. Every one of those is an `invalid_in` case in
;; vendor/dasl-testing — the failing side is the DECODER. The reason is not
;; tidiness: each would be a SECOND spelling of a value that already has one, and
;; two spellings of one value is precisely what a content-addressed store cannot
;; survive.

(require racket/contract
         (only-in racket/math nan? infinite?)
         "dasl.rkt")

(provide drisl-null
         (contract-out
          [drisl-encode (-> any/c bytes?)]
          [drisl-decode (-> bytes? any/c)]
          [drisl-cid    (-> any/c cid?)]))

;; The absence of a value. A distinct symbol rather than #f, which DRISL already
;; spends on the boolean, and rather than Racket's `null` (the empty list), which
;; DRISL already spends on the empty array.
(define drisl-null 'null)

(define MAX-UINT64 (sub1 (expt 2 64)))

;; --- Encoding -----------------------------------------------------------------

;; drisl-encode : any -> bytes
;; The canonical bytes for a value. Total on the data model above and an error
;; everywhere else — there is no lenient mode, because a lenient encoder is how a
;; second spelling gets into the store.
(define (drisl-encode v)
  (define out (open-output-bytes))
  (encode-value v out)
  (get-output-bytes out))

;; drisl-cid : any -> cid
;; The value's block address: its canonical bytes, addressed as DRISL. This is the
;; primitive st-1e5 is built on — an artifact's roll-up digest stops being a
;; computation OVER its parts and becomes the address OF the block holding them.
(define (drisl-cid v) (content->cid (drisl-encode v) 'drisl))

(define (encode-value v out)
  (cond
    [(eq? v drisl-null) (write-byte #xf6 out)]
    [(eq? v #t) (write-byte #xf5 out)]
    [(eq? v #f) (write-byte #xf4 out)]
    [(exact-integer? v) (encode-integer v out)]
    [(flonum? v) (encode-flonum v out)]
    [(bytes? v)
     (write-head 2 (bytes-length v) out)
     (write-bytes v out)]
    [(string? v)
     (define bs (string->bytes/utf-8 v))
     (write-head 3 (bytes-length bs) out)
     (write-bytes bs out)]
    [(list? v)
     (write-head 4 (length v) out)
     (for ([x (in-list v)]) (encode-value x out))]
    [(hash? v) (encode-map v out)]
    [(cid? v) (encode-cid v out)]
    [else (error 'drisl-encode "no DRISL encoding for ~e" v)]))

(define (encode-integer v out)
  (cond
    [(negative? v)
     (unless (>= v (- (add1 MAX-UINT64)))
       (error 'drisl-encode "integer ~a is below -(2^64); DRISL has no bignums" v))
     (write-head 1 (- -1 v) out)]
    [else
     (unless (<= v MAX-UINT64)
       (error 'drisl-encode "integer ~a exceeds 2^64-1; DRISL has no bignums" v))
     (write-head 0 v out)]))

(define (encode-flonum v out)
  ;; Not representable, rather than merely discouraged: a content address for NaN
  ;; would have to answer whether two NaNs are the same value, and there is no
  ;; answer. Note -0.0 IS encodable and keeps its sign bit.
  (when (or (nan? v) (infinite? v))
    (error 'drisl-encode "~a is not in the DRISL data model" v))
  (write-byte #xfb out)
  (write-bytes (real->floating-point-bytes v 8 #t) out))

(define (encode-map v out)
  (define pairs (hash->list v))
  (for ([p (in-list pairs)])
    (unless (string? (car p))
      (error 'drisl-encode "DRISL map keys must be strings; got ~e" (car p))))
  (define sorted (sort pairs drisl-key<? #:key car))
  (write-head 5 (length sorted) out)
  (for ([p (in-list sorted)])
    (encode-value (car p) out)
    (encode-value (cdr p) out)))

(define (encode-cid v out)
  ;; Tag 42, minimally headed (d8 2a), over the link bytes — never the long form
  ;; d9 00 2a, which the fixtures reject as "long CID tag".
  (write-head 6 42 out)
  (define link (cid->link-bytes v))
  (write-head 2 (bytes-length link) out)
  (write-bytes link out))

;; drisl-key<? : string string -> boolean
;; Canonical map-key order: shorter UTF-8 first, then bytewise. See the header for
;; why this is simultaneously dag-cbor's rule and RFC 8949's.
(define (drisl-key<? a b)
  (define ab (string->bytes/utf-8 a))
  (define bb (string->bytes/utf-8 b))
  (cond
    [(< (bytes-length ab) (bytes-length bb)) #t]
    [(> (bytes-length ab) (bytes-length bb)) #f]
    [else (bytes<? ab bb)]))

;; write-head : nat nat output-port -> void
;; Major type plus argument in the SHORTEST form that holds it — the rule that
;; makes every `unnecessary N-byte ...` fixture an invalid input.
(define (write-head major n out)
  (define (tag ai) (write-byte (+ (arithmetic-shift major 5) ai) out))
  (cond
    [(< n 24) (tag n)]
    [(< n 256) (tag 24) (write-byte n out)]
    [(< n 65536) (tag 25) (write-bytes (integer->integer-bytes n 2 #f #t) out)]
    [(< n 4294967296) (tag 26) (write-bytes (integer->integer-bytes n 4 #f #t) out)]
    [(<= n MAX-UINT64) (tag 27) (write-bytes (integer->integer-bytes n 8 #f #t) out)]
    [else (error 'drisl-encode "argument ~a exceeds 2^64-1" n)]))

;; --- Decoding -----------------------------------------------------------------

;; drisl-decode : bytes -> any
;; Exactly one value, then end of input. A CBOR sequence (the "concatenated
;; objects" fixture) is refused: a block is one value, and bytes past it would be
;; content the address does not cover.
(define (drisl-decode bs)
  (define in (open-input-bytes bs))
  (define v (read-value in))
  (unless (eof-object? (peek-byte in))
    (fail "trailing bytes after the top-level item"))
  v)

(define (fail fmt . args)
  (apply error 'drisl-decode fmt args))

(define (read-byte! in)
  (define b (read-byte in))
  (when (eof-object? b) (fail "input ended mid-value"))
  b)

(define (read-bytes! in n)
  (define bs (read-bytes n in))
  (unless (and (bytes? bs) (= n (bytes-length bs)))
    (fail "input ended mid-value: wanted ~a bytes" n))
  bs)

(define (read-value in)
  (define b (read-byte! in))
  (define major (arithmetic-shift b -5))
  (define ai (bitwise-and b 31))
  (case major
    [(0) (read-count in ai)]
    [(1) (- -1 (read-count in ai))]
    [(2) (read-bytes! in (read-count in ai))]
    [(3) (read-text in (read-count in ai))]
    [(4) (for/list ([_ (in-range (read-count in ai))]) (read-value in))]
    [(5) (read-map in (read-count in ai))]
    [(6) (read-tagged in ai)]
    [else (read-simple in ai)]))

;; read-count : input-port nat -> nat
;; The head's argument, refusing every non-shortest spelling of it. This one
;; function is what makes `1801` (1 written in two bytes) an error rather than 1 —
;; and it is load-bearing for content addressing, not pedantry.
(define (read-count in ai)
  (define (wide n bytes least)
    (when (< n least)
      (fail "~a is written in ~a bytes but fits in fewer; DRISL heads are minimal" n bytes))
    n)
  (cond
    [(< ai 24) ai]
    [(= ai 24) (wide (read-byte! in) 1 24)]
    [(= ai 25) (wide (integer-bytes->integer (read-bytes! in 2) #f #t) 2 256)]
    [(= ai 26) (wide (integer-bytes->integer (read-bytes! in 4) #f #t) 4 65536)]
    [(= ai 27) (wide (integer-bytes->integer (read-bytes! in 8) #f #t) 8 4294967296)]
    [(= ai 31) (fail "indefinite lengths are not in DRISL")]
    [else (fail "additional information ~a is reserved" ai)]))

(define (read-text in n)
  (define bs (read-bytes! in n))
  (with-handlers ([exn:fail? (lambda (_) (fail "text string is not valid UTF-8"))])
    (bytes->string/utf-8 bs)))

;; read-map : input-port nat -> hash
;; Keys must be strings, strictly ascending in canonical order. Checking the order
;; while READING is what makes a re-encode byte-identical: a decoder that accepted
;; any order would silently re-sort, and one block would have had two spellings.
(define (read-map in n)
  (let loop ([i 0] [prev #f] [acc (hash)])
    (cond
      [(= i n) acc]
      [else
       (define key (read-value in))
       (unless (string? key)
         (fail "map keys must be text strings; got ~e" key))
       (when prev
         (cond
           [(string=? prev key) (fail "duplicate map key ~s" key)]
           [(not (drisl-key<? prev key))
            (fail "map key ~s follows ~s, which is not canonical order" key prev)]))
       (define val (read-value in))
       (loop (add1 i) key (hash-set acc key val))])))

(define (read-tagged in ai)
  (define tag (read-count in ai))
  (unless (= tag 42)
    (fail "tag ~a is not in DRISL (only 42, the CID link)" tag))
  (define b (read-byte! in))
  (unless (= 2 (arithmetic-shift b -5))
    (fail "tag 42 must wrap a byte string"))
  (link-bytes->cid (read-bytes! in (read-count in (bitwise-and b 31)))))

(define (read-simple in ai)
  (case ai
    [(20) #f]
    [(21) #t]
    [(22) drisl-null]
    [(23) (fail "'undefined' is not in the DRISL data model")]
    [(25) (fail "half-precision floats are not in DRISL; floats are always 64-bit")]
    [(26) (fail "single-precision floats are not in DRISL; floats are always 64-bit")]
    [(27)
     (define x (floating-point-bytes->real (read-bytes! in 8) #t))
     (when (or (nan? x) (infinite? x))
       (fail "NaN and infinities are not in the DRISL data model"))
     x]
    [(31) (fail "indefinite-length break outside any indefinite-length item")]
    [else (fail "simple value ~a is unassigned" ai)]))
