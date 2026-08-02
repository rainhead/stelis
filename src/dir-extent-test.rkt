#lang racket/base

;; Unit tests for derived 'dir extents (st-hdm). The properties that matter — a
;; nested 'dir artifact is carved OUT of the one containing it, and only that one;
;; siblings and unrelated trees are untouched; a prefix that is not a path boundary
;; is not "inside"; the carve-out is real on disk (the digest and the per-key map
;; both stop at the boundary); and two artifacts claiming the SAME root is refused,
;; because neither carves out the other.

(require rackunit
         racket/file
         racket/list
         "model.rkt"
         "dir-extent.rkt"
         "tree-digest.rkt")

;; --- the walk-level exclusion ------------------------------------------------

(define root (make-temporary-file "stelis-extent-~a" 'directory))
(define (touch rel content)
  (define p (build-path root rel))
  (make-directory* (let-values ([(d _n _dir?) (split-path p)]) d))
  (display-to-file content p #:exists 'replace))

(make-directory* (build-path root "assets"))
(make-directory* (build-path root "data"))
(make-directory* (build-path root "species"))
(touch "index.html" "home")
(touch "species/mixtus.html" "page")
(touch "assets/app-abc.js" "chunk")
(touch "data/manifest.json" "{}")

(let ([all (tree-hashes root)]
      [carved (tree-hashes root #:exclude (list (build-path root "assets")
                                                (build-path root "data")))])
  (check-equal? (map car all)
                '("assets/app-abc.js" "data/manifest.json" "index.html" "species/mixtus.html")
                "unexcluded, a 'dir is its whole tree — the behaviour before st-hdm")
  (check-equal? (map car carved) '("index.html" "species/mixtus.html")
                "excluded roots drop out, and the loose top-level file stays")
  ;; the digest follows the parts for free: tree-digest IS keyed-block-digest over
  ;; tree-hashes (st-1e5), so there is one seam, not two that could disagree.
  (check-not-equal? (tree-digest root)
                    (tree-digest root #:exclude (list (build-path root "assets")))
                    "excluding changes the digest, because the digest IS the parts' address")
  (check-equal? (tree-digest root #:exclude '()) (tree-digest root)
                "an empty exclusion is exactly the unexcluded digest"))

;; a file whose NAME merely starts with an excluded root's name is not inside it —
;; the check must be on path boundaries, not string prefixes.
(touch "assetsX.html" "not in assets/")
(let ([carved (tree-hashes root #:exclude (list (build-path root "assets")))])
  (check-true (and (member "assetsX.html" (map car carved)) #t)
              "a sibling sharing a name prefix is NOT excluded"))

;; --- the derivation ----------------------------------------------------------

;; _site holds the pages; assets/ and data/ are other artifacts' output. `other`
;; is an unrelated tree, and `deep` sits inside assets/ to check that a carve-out
;; is attributed to its IMMEDIATE container's ancestors too.
(define paths
  (hash 'site   (build-path root)
        'assets (build-path root "assets")
        'data   (build-path root "data")
        'deep   (build-path root "assets" "nested")
        'other  (build-path root 'up "elsewhere")))

(define g
  (build-graph
   (list (make-task 'render 'transform #:outputs '(site) #:invoke (recipe 'sh '("true")))
         (make-task 'bundle 'transform #:outputs '(assets) #:invoke (recipe 'sh '("true")))
         (make-task 'place  'transform #:outputs '(data)  #:invoke (recipe 'sh '("true")))
         (make-task 'deeper 'transform #:outputs '(deep)  #:invoke (recipe 'sh '("true")))
         (make-task 'far    'transform #:outputs '(other) #:invoke (recipe 'sh '("true"))))
   (list (make-artifact 'site 'dir) (make-artifact 'assets 'dir)
         (make-artifact 'data 'dir) (make-artifact 'deep 'dir)
         (make-artifact 'other 'dir))))

(define resolve (lambda (a) (hash-ref paths a #f)))
(define excl (make-dir-exclusions g resolve))

(let ([site (map path->string (excl 'site))])
  (check-equal? (length site) 3 "site carves out assets/, data/ and the nested one")
  (check-true (and (member (path->string (build-path root "assets")) site) #t))
  (check-true (and (member (path->string (build-path root "data")) site) #t))
  (check-false (member (path->string (path->complete-path (build-path root 'up "elsewhere"))) site)
               "an unrelated tree is not carved out of site"))

(check-equal? (map path->string (excl 'assets))
              (list (path->string (build-path root "assets" "nested")))
              "assets carves out only what is inside IT, not its sibling data/")
(check-equal? (excl 'data) '() "a directory with no lodgers excludes nothing")
(check-equal? (excl 'deep) '() "…and neither does the innermost one")
(check-equal? (excl 'other) '() "an unrelated tree is unaffected")

;; an artifact the resolver cannot place can neither carve nor be carved
(let ([partial (make-dir-exclusions g (lambda (a) (if (eq? a 'assets) #f (resolve a))))])
  (check-equal? (length (partial 'site)) 2
                "an unresolvable artifact drops out rather than being invented")
  (check-equal? (partial 'assets) '()))

;; a non-'dir artifact is not an extent at all
(let* ([g2 (build-graph
            (list (make-task 't 'transform #:outputs '(d f) #:invoke (recipe 'sh '("true"))))
            (list (make-artifact 'd 'dir) (make-artifact 'f 'file)))]
       [e (make-dir-exclusions g2 (lambda (a) (hash-ref (hash 'd root
                                                             'f (build-path root "index.html"))
                                                        a #f)))])
  (check-equal? (e 'd) '() "a 'file inside a 'dir is not a carve-out — only 'dir artifacts are")
  (check-equal? (e 'f) '()))

;; --- the refusal --------------------------------------------------------------

(check-not-exn (lambda () (check-dir-extents g resolve))
               "nesting is the mechanism, not an error")

(let* ([gdup (build-graph
              (list (make-task 'a 'transform #:outputs '(one) #:invoke (recipe 'sh '("true")))
                    (make-task 'b 'transform #:outputs '(two) #:invoke (recipe 'sh '("true"))))
              (list (make-artifact 'one 'dir) (make-artifact 'two 'dir)))]
       [same (lambda (_a) root)])
  (check-exn #rx"same root"
             (lambda () (check-dir-extents gdup same))
             "two artifacts claiming one directory: neither carves out the other"))

;; --- the property that motivates deriving rather than declaring -----------------
;; A NEW producer inside an existing tree carves itself out automatically. With a
;; hand-written exclusion list this is exactly the step that gets forgotten, and
;; the failure is silent: the outer artifact's digest absorbs output it does not
;; produce, and two tasks claim the same bytes.
(let* ([g+ (build-graph
            (list (make-task 'render 'transform #:outputs '(site) #:invoke (recipe 'sh '("true")))
                  (make-task 'newbie 'transform #:outputs '(fresh) #:invoke (recipe 'sh '("true"))))
            (list (make-artifact 'site 'dir) (make-artifact 'fresh 'dir)))]
       [e+ (make-dir-exclusions g+ (lambda (a)
                                     (case a
                                       [(site) root]
                                       [(fresh) (build-path root "species")]
                                       [else #f])))])
  (check-equal? (map path->string (e+ 'site))
                (list (path->string (build-path root "species")))
                "a producer added later is carved out without anyone updating a list"))

(delete-directory/files root)
