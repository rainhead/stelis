#lang racket/base

;; A keyed artifact's per-key map, AS A BLOCK, and its address (st-1e5, ADR 0010).
;;
;; This retires `digest-of-pairs' — the second of the three ad-hoc canonical forms
;; ADR 0010 set out to replace, after graph-digest's `~s` print (st-b7v).
;;
;; WHAT ACTUALLY CHANGES. Before, a keyed artifact's roll-up digest and its per-key
;; parts were computed SEPARATELY over the same data, and cache.rkt had to assert in
;; prose that "the two granularities can never disagree". Now they are one object:
;; the map is a DRISL block, and the artifact's digest IS that block's CID. The
;; invariant stops being maintained by comment and becomes true by construction —
;; there is no second computation left to drift.
;;
;; TWO REAL BUGS THIS CLOSES, not just tidiness:
;;
;;   1. AMBIGUITY. `digest-of-pairs' joined "<key>=<value>" with newlines, so a key
;;      or value containing `=` or a newline could spell another map's digest:
;;      {"a=b" -> "c"} and {"a" -> "b=c"} both rendered "a=b=c" and collided. Paths
;;      containing "=" are legal on every filesystem we run on. A DRISL map has one
;;      spelling per value and no delimiter to smuggle.
;;
;;   2. CALLER-DEPENDENT ORDER. The old digest was "order-independent" only because
;;      every caller happened to pass sorted pairs — the property lived in the
;;      callers, not the function. DRISL sorts map keys canonically as part of
;;      encoding, so the same map digests identically however it was assembled.
;;
;; WHERE IT APPLIES, AND WHERE IT DELIBERATELY DOES NOT. A 'dir tree and the keyed
;; notes STORE take their identity from exactly these pairs, so for them the CID is
;; the roll-up. A db-relation does NOT: its identity is relation-digest.rkt's
;; ROW-COHERENT digest, because per-column multiset digests alone false-skip on a
;; cross-row value swap (two rows exchange a value; every column's multiset is
;; unchanged, yet the relation changed — st-d5d proved this). Its per-column parts
;; ride ALONGSIDE its identity rather than constituting it, so it is not a caller
;; here. That asymmetry is load-bearing; do not "fix" it.
;;
;; The VALUES stay what they were — a sha1 hex string for a file, "<digest>:<count>"
;; for a store key. The block is content-addressed; what it holds is just data.
;; Making the leaves CIDs too would make this a genuine Merkle node, and would
;; invalidate every recorded hash at once; that is a separate decision.

(require racket/contract
         (only-in "dasl.rkt" cid->string)
         (only-in "drisl.rkt" drisl-cid))

(provide (contract-out
          [keyed-block        (-> (listof (cons/c string? string?)) hash?)]
          [keyed-block-digest (-> (listof (cons/c string? string?)) string?)]))

;; keyed-block : (listof (cons string string)) -> hash
;; The pairs as a DRISL map value. Duplicate keys are an ERROR rather than a
;; last-one-wins collapse: a 'dir cannot hold one path twice and a store cannot hold
;; one key twice, so a duplicate means the reader that produced these pairs is
;; broken, and silently digesting a map with fewer entries than it was handed would
;; hide that behind a plausible-looking address.
(define (keyed-block pairs)
  (for/fold ([h (hash)]) ([p (in-list pairs)])
    (when (hash-has-key? h (car p))
      (error 'keyed-block "duplicate key ~s in a keyed artifact's parts" (car p)))
    (hash-set h (car p) (cdr p))))

;; keyed-block-digest : (listof (cons string string)) -> string
;; That block's CID, in the `b` base32 string form — the artifact's content address.
(define (keyed-block-digest pairs) (cid->string (drisl-cid (keyed-block pairs))))
