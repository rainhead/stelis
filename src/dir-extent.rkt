#lang racket/base

;; WHICH FILES A 'dir ARTIFACT ACTUALLY OWNS (st-hdm).
;;
;; A 'dir artifact used to mean "this whole directory tree". That is true while
;; one producer owns the tree, and stops being true the moment two do. beeatlas's
;; `_site` is the case: Vite writes `assets/`, the data placement step writes
;; `data/`, and Eleventy writes everything else — the pages, plus four loose files
;; at the root (index.html, collectors.html, places.html, species-redirects.map).
;; The page tree is therefore NOT a subtree of anything; it is `_site` minus two
;; carve-outs, and there is no directory that names it.
;;
;; THE EXTENT IS DERIVED, NOT DECLARED. An artifact rooted at P excludes the root
;; of every OTHER 'dir artifact that lies strictly inside P. Nothing is written
;; down twice: the graph already says app-bundle is `_site/assets`, so `_site`'s
;; other resident knows to skip it. The alternative — an #:excluding list on the
;; artifact — is a hand-maintained mirror of other producers' extents, and the
;; failure mode is silent: add a fifth producer, forget the list, and this
;; artifact's digest quietly absorbs output it does not produce. One-producer-per-
;; artifact would degrade from a structural property into a convention.
;;
;; WHAT THIS BUYS BEYOND THE CARVE-OUT: overlap becomes VISIBLE. Two artifacts
;; resolving to the same root is a graph bug Stelis previously could not see at
;; all — both would content-address the same bytes, both would claim to produce
;; them, and early cutoff would compare each against the other's writes.
;; check-dir-extents rejects it before a build.
;;
;; THE COST, ACCEPTED: an artifact's identity now depends on its siblings. Adding
;; a 'dir artifact inside an existing one changes the outer one's digest, so the
;; outer one rebuilds once. That is correct rather than unfortunate — it genuinely
;; no longer produces those files — but it does mean the digest is a fact about
;; the graph, not about the directory alone.
;;
;; NESTING IS THE MECHANISM, NOT AN ERROR. `_site/assets` inside `_site` is the
;; whole point. Only an EXACT collision is rejected, because that is the one case
;; where neither artifact can be said to carve out the other.

(require racket/list
         "model.rkt")

(provide dir-artifact-roots
         make-dir-exclusions
         check-dir-extents)

;; strictly-inside? : path path -> boolean
;; Is `p` a proper descendant of `root`? Equal paths are NOT inside — an artifact
;; does not carve itself out, and an exact collision is check-dir-extents' problem.
(define (strictly-inside? p root)
  ;; Compare EXPLODED elements, never path objects. `/a/b` and `/a/b/` are not
  ;; `equal?` in Racket, and split-path hands back a parent WITH a trailing
  ;; separator — so a naive walk-up comparison silently never matches, and every
  ;; carve-out is quietly lost. Element-wise prefix also gets the other case
  ;; right for free: `/site/assetsX` is not inside `/site/assets` even though one
  ;; string prefixes the other.
  (define pe (explode-path p))
  (define re (explode-path root))
  (and (> (length pe) (length re))
       (equal? re (take pe (length re)))))

;; dir-artifact-roots : graph (symbol -> (or/c path-string #f))
;;                      -> (listof (cons symbol path))
;; Every 'dir artifact that currently resolves to a path, as (name . complete-path).
;; An artifact the resolver cannot place is absent — it can neither be carved out
;; of nor carve anything, and forcing a path here would invent one.
(define (dir-artifact-roots g resolve)
  (sort
   (for*/list ([(name a) (in-hash (graph-artifacts g))]
               #:when (eq? 'dir (artifact-kind a))
               [p (in-value (resolve name))]
               #:when p)
     ;; simplify-path with #f: collapse `.`/`..` WITHOUT consulting the
     ;; filesystem, so the result is deterministic and symlinks are left alone.
     ;; Without it a sibling reached as `<root>/../elsewhere` explodes to a list
     ;; that has root's elements as a prefix, and would be read as nested inside
     ;; the very directory it sits beside.
     (cons name (simplify-path (path->complete-path p) #f)))
   symbol<? #:key car))

;; make-dir-exclusions : graph (symbol -> (or/c path-string #f))
;;                       -> (symbol -> (listof path))
;; The resolver build-env carries: for a 'dir artifact, the roots of the other
;; 'dir artifacts nested inside it. '() for everything else, so a directory with
;; no lodgers behaves exactly as before.
;;
;; The roots are computed ONCE per call to this function, not per lookup — every
;; 'dir hash in a build goes through it, and each would otherwise re-resolve the
;; whole artifact table.
(define (make-dir-exclusions g resolve)
  (define roots (dir-artifact-roots g resolve))
  (lambda (name)
    (define self (assq name roots))
    (if (not self)
        '()
        (for/list ([r (in-list roots)]
                   #:unless (eq? (car r) name)
                   #:when (strictly-inside? (cdr r) (cdr self)))
          (cdr r)))))

;; check-dir-extents : graph (symbol -> (or/c path-string #f)) -> void
;; Reject a graph in which two 'dir artifacts resolve to the SAME root. Nesting is
;; fine and is how a carve-out is expressed; an exact collision is not, because
;; neither artifact carves out the other and both would content-address the same
;; bytes while both claimed to produce them.
;;
;; Checked at pre-build validation, beside the other authoring-time gates, for the
;; same reason: it is a property of how the graph is written, so it should fail
;; while someone is writing it.
(define (check-dir-extents g resolve)
  (define roots (dir-artifact-roots g resolve))
  ;; keyed on EXPLODED elements for the same reason strictly-inside? is: two
  ;; resolvers can spell one directory `/a/b` and `/a/b/`, which are not `equal?`
  ;; — and a collision that hid behind a trailing slash is exactly the one worth
  ;; catching.
  (define by-path (make-hash))
  (for ([r (in-list roots)])
    (hash-update! by-path (explode-path (cdr r)) (lambda (ns) (cons (car r) ns)) '()))
  (for ([(p names) (in-hash by-path)]
        #:when (> (length names) 1))
    (error 'check-dir-extents
           (string-append
            "~a 'dir artifacts resolve to the same root ~a: ~a.\n"
            "  Nesting is how one artifact carves another out of its extent; an exact\n"
            "  collision is not — neither carves out the other, so both would\n"
            "  content-address the same bytes while both claimed to produce them.")
           (length names) (apply build-path p) (sort names symbol<?))))
