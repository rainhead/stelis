#lang racket/base

;; Content-addressing for directory ('dir) artifacts (st-cly).
;;
;; A 'file artifact is hashed by its bytes (cache.rkt); a 'dir artifact is a whole
;; directory TREE — a data-dependent output SET (species-maps, place-maps, feeds:
;; each a directory of per-entity files under EXPORT_DIR). This gives such a tree a
;; single content hash the same way relation-digest.rkt gives a db-relation one: an
;; ORDER-INDEPENDENT digest, so the (possibly OS-dependent) order the filesystem
;; enumerates entries in never changes the result.
;;
;; Shape (st-1e5 moved the roll-up to keyed-block.rkt; see it for why):
;;   * every regular file under `dir' (recursively) contributes one
;;     relative-path -> sha1-of-bytes entry — both its LOCATION and its CONTENT, so
;;     a moved/renamed file changes the digest, not only an edited one.
;;   * those entries ARE the digest: the tree's address is the CID of them as a
;;     DRISL block, so order-independence comes from the encoding (DRISL sorts map
;;     keys) rather than from `dir-relpaths' happening to sort. The walk is still
;;     sorted, because fan-out-key.rkt wants it that way.
;;   * that sorted file walk is the shared substrate: fan-out-key.rkt (st-tul)
;;     matches templates against these relative paths by NAME (it needs no hashes),
;;     while this digest pairs each with its content hash. Eventual H2 delta
;;     propagation is what consumes the full (path -> hash) pairs.
;;
;; Absent/empty: #f when `dir' isn't an existing directory (nothing to address);
;; an existing but empty directory digests as the CID of the empty block — a real
;; address for "a directory with nothing in it", distinct from #f's "no directory".

(require racket/path
         racket/string
         file/sha1
         "keyed-block.rkt")

(provide tree-digest tree-hashes dir-relpaths)

;; dir-relpaths : path-string -> (listof string)
;; Every regular file under `dir', as a SORTED list of "/"-joined relative paths
;; (posix separators, so a template like "genus/{}.svg" matches regardless of OS).
;; The single directory-walk primitive both tree-digest and fan-out-key.rkt share.
(define (dir-relpaths dir)
  (define root (path->complete-path dir))
  (sort (for/list ([f (in-directory dir)] #:when (file-exists? f))
          (string-join (map path->string
                            (explode-path (find-relative-path root (path->complete-path f))))
                       "/"))
        string<?))

;; tree-hashes : path-string -> (or/c (listof (cons string string)) #f)
;; The per-file layer under the digest: each "/"-joined relative path paired with
;; its content hash, sorted by path (so the list is order-independent, same as the
;; digest). #f when `dir' isn't an existing directory. This is the (path -> hash)
;; map the digest rolls up — exposed so per-KEY observations (st-6dv) can record
;; which fan-out members changed, and H2 delta propagation can attribute change to
;; one key rather than rebuilding the whole set.
(define (tree-hashes dir)
  (and (directory-exists? dir)
       (for/list ([rel (in-list (dir-relpaths dir))])
         (cons rel (call-with-input-file (rel->path dir rel) sha1)))))

;; tree-digest : path-string -> (or/c string #f)
;; The order-independent content hash of the directory tree rooted at `dir', or #f
;; when `dir' isn't an existing directory (the caller then treats it as absent —
;; e.g. an input that isn't content-addressable, forcing a conservative rerun).
;; It is the CID of `tree-hashes' as a keyed block (st-1e5) — so the digest does not
;; merely AGREE with the per-key pairs, it IS their address, and order-independence
;; is now the encoding's property rather than a habit of every caller.
(define (tree-digest dir)
  (define pairs (tree-hashes dir))
  (and pairs (keyed-block-digest pairs)))

;; rebuild the on-disk path of a "/"-joined relative path under `dir'.
(define (rel->path dir rel) (apply build-path dir (string-split rel "/")))
