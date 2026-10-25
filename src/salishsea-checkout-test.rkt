#lang racket/base

;; Every code file the salishsea graph declares exists in the checkout. A declared
;; file that is gone makes its task's input address unresolvable, so the task can
;; never be skipped: when salishsea #664 deleted src/supabase.ts, eight tasks that
;; named it reran on every five-minute build for sixteen days, and nothing said so
;; but --explain (st-wn4). Needs the checkout, so CI, which has none, skips. Files
;; under dist/ are checked when the checkout has a dist/: the site build writes them,
;; and a Vite input renamed there strands the page shells the same way. A checkout
;; that has never run the site build has no dist/, and its dist/ files are skipped.

(require rackunit
         racket/path
         racket/string
         "model.rkt"
         "salishsea.rkt")

(cond
  [(not (file-exists? (build-path SALISHSEA "package.json")))
   (printf "salishsea-checkout-test: no salishsea checkout at ~a — skipping.\n" SALISHSEA)]
  [else
   (define dist (path->string (simplify-path (build-path SALISHSEA "dist"))))
   (define built? (directory-exists? dist))
   (for* ([g (in-list (list salishsea-graph salishsea-ingest-graph))]
          [(name t) (in-hash (graph-tasks g))]
          [inv (in-value (task-invoke t))]
          #:when (recipe? inv)
          [c (in-list (recipe-code inv))]
          #:unless (optional-code? c)
          [p (in-value (path->string (simplify-path c)))]
          #:unless (and (not built?) (string-prefix? p dist)))
     (check-true (or (file-exists? p) (directory-exists? p))
                 (format "~a declares ~a as code, which the checkout does not have" name p)))])
