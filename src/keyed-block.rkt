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

;;
;; CHUNKED (st-ml9.7). A map of more than LEAF-MAX entries is no longer one block but
;; a tree of them: a node maps the next byte of each key's sha256, as two hex digits,
;; to the CID of the block holding the keys in that bucket, and a bucket still too
;; big is split again by the byte after. So when one key of a 4,400-key map changes
;; (salishsea's days/, once a build), history stores one ~1 KB bucket and a ~10 KB
;; root instead of the whole ~250 KB map again. The artifact's digest is the ROOT's
;; CID, so the property above holds unchanged: the address is the stored object. A
;; map of LEAF-MAX entries or fewer is exactly the flat block it always was, with the
;; same CID; only larger maps' addresses changed, once, when this landed.
;;
;; A node is a two-element ARRAY, [NODE-TAG, {bucket -> CID}], and a leaf is always a
;; map, so the two are told apart by shape alone, whatever a leaf's values come to be
;; (they are strings today; if they became CIDs, a test by value type would break).
;; Buckets are by hash rather than by key prefix so the split doesn't depend on what
;; the keys look like: a path's year, a species name, anything spreads the same way.
;; The layout is our own: hash-prefix sharding like IPFS's HAMT directories, in DRISL
;; with CID links like atproto, but neither ecosystem's spec, so nothing outside
;; Stelis reads one of these trees as a map.

(require racket/contract
         racket/list
         (only-in "dasl.rkt" cid->string cid?)
         (only-in "drisl.rkt" drisl-cid))

(provide (contract-out
          [keyed-block        (-> (listof (cons/c string? string?)) hash?)]
          [keyed-block-digest (-> (listof (cons/c string? string?)) string?)]
          [keyed-tree-blocks  (-> (listof (cons/c string? string?)) (listof (or/c hash? list?)))]
          [keyed-node-links   (-> any/c (listof string?))]
          [keyed-node?        (-> any/c boolean?)])
         LEAF-MAX
         NODE-TAG)

;; The most entries a leaf block holds; a larger map is split into buckets.
(define LEAF-MAX 256)

;; A node's first element: what it is, and which layout.
(define NODE-TAG "stelis/keyed-node/1")

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

;; keyed-tree-blocks : (listof (cons string string)) -> (listof hash)
;; Every block of the map's tree, the root first: one flat block for a map of LEAF-MAX
;; entries or fewer, otherwise a node and, below it, its buckets.
(define (keyed-tree-blocks pairs)
  (define flat (keyed-block pairs))   ; refuses a duplicate key, at any size
  (let build ([pairs (hash->list flat)] [depth 0])
    ;; 32 bytes of hash: past them every key in a bucket hashes the same, which only
    ;; one key can, so a leaf is reached long before.
    (cond
      [(or (<= (length pairs) LEAF-MAX) (>= depth 32)) (list (keyed-block pairs))]
      [else
       (define buckets
         (group-by (lambda (p) (bucket (car p) depth)) pairs))
       (define children
         (for/list ([b (in-list buckets)])
           (cons (bucket (car (first b)) depth) (build b (add1 depth)))))
       (cons (list NODE-TAG
                   (for/hash ([c (in-list children)])
                     (values (car c) (drisl-cid (cadr c)))))
             (append* (map cdr children)))])))

;; The two hex digits of byte `depth' of the key's sha256.
(define (bucket key depth)
  (define b (bytes-ref (sha256-bytes (string->bytes/utf-8 key)) depth))
  (string-append (if (< b 16) "0" "") (number->string b 16)))

;; keyed-node? : any -> boolean
;; Whether a stored block is a node of a chunked map rather than a leaf.
;;
;; Also true of the LEGACY node, the bare {bucket -> CID} map written before nodes
;; carried their tag (3a84ea4, deployed 2026-10-03 03:12Z to 03:30Z). Only salishsea's
;; Fly history holds any, and its 30-day retention removes them; this clause can go
;; after 2026-11-03.
(define (keyed-node? v)
  (or (and (list? v) (= 2 (length v)) (equal? (car v) NODE-TAG) (hash? (cadr v)))
      (and (hash? v) (positive? (hash-count v))
           (for/and ([x (in-hash-values v)]) (cid? x)))))

;; keyed-node-links : any -> (listof string)
;; A node's children, as CID strings.
(define (keyed-node-links v)
  (define links (if (list? v) (cadr v) v))
  (for/list ([x (in-hash-values links)] #:when (cid? x)) (cid->string x)))

;; keyed-block-digest : (listof (cons string string)) -> string
;; The map's CID, in the `b` base32 string form — the artifact's content address: its
;; flat block's for a small map, its root node's for a large one.
(define (keyed-block-digest pairs) (cid->string (drisl-cid (first (keyed-tree-blocks pairs)))))
