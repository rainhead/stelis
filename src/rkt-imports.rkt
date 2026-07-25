#lang racket/base

;; Transitive LOCAL requires of a Racket module (st-egh) — the Racket twin of
;; py-imports.rkt.
;;
;; A `derivation' node (st-ozp) runs a transform INSIDE the engine, so Stelis's
;; own source is that task's code and must join its input address. Listing the
;; paths by hand does not work: taxon-derive.rkt requires duckdb.rkt, and an edit
;; there changes what every taxonomy read does while leaving the recorded
;; code-hashes untouched — inputs unchanged, recipe unchanged, so the node
;; cache-skips and the breakage stays invisible. Found by review, not by a test.
;;
;; That is precisely the failure py-imports.rkt was built to prevent on the PYTHON
;; side (st-6ga/st-whi: scan a script's local imports, make each helper a 'code
;; artifact, walk the closure). The in-engine transform had WEAKER code tracking
;; than the external ones, which is backwards — its code is the engine.
;;
;; Same authoring-time, read-based approach as py-imports: a scan, not a loaded
;; module graph. Nothing is instantiated, so this is safe to call while the graph
;; is still being authored.
;;
;; SCOPE, deliberately: only STRING requires are followed — the project's own
;; relative-path modules. Collection requires (racket/base, json, datalog) are
;; NOT followed and NOT hashed: they are library dependencies pinned by the
;; package installation, not source this repo edits. A `datalog' package upgrade
;; therefore does not invalidate; that is a known, recorded limit, and the same
;; one the Python side has for installed packages.

(require racket/list
         racket/path
         racket/set)

(provide module-local-requires
         rkt-import-closure)

;; module-local-requires : path-string -> (listof path)
;; The modules `p' requires by relative path, resolved against p's own directory.
;; Over-approximates on purpose: every string literal inside any `require' form is
;; taken, wherever it sits (a submodule, `for-syntax', `only-in'). Over-hashing
;; costs an occasional extra rebuild; under-hashing costs a false cache hit, and
;; only one of those is a correctness bug.
;; A file that cannot be read yields '() rather than raising — a scan that fails
;; must not take down graph authoring, and the caller stays conservative because
;; the entry module itself is still hashed.
(define (module-local-requires p)
  (define datum
    (with-handlers ([exn:fail? (lambda (_) #f)])
      (parameterize ([read-accept-reader #t] [read-accept-lang #t])
        (call-with-input-file p read))))
  (cond
    [(not datum) '()]
    [else
     (define dir (path-only (path->complete-path p)))
     (for/list ([s (in-list (require-strings datum))])
       (simplify-path (build-path dir s)))]))

;; every string literal appearing inside a `require' form, anywhere in the datum
(define (require-strings x)
  (cond
    [(and (pair? x) (eq? 'require (car x))) (strings-in (cdr x))]
    [(pair? x) (append (require-strings (car x)) (require-strings (cdr x)))]
    [else '()]))

(define (strings-in x)
  (cond
    [(string? x) (list x)]
    [(pair? x) (append (strings-in (car x)) (strings-in (cdr x)))]
    [else '()]))

;; rkt-import-closure : path-string ... -> (listof path)
;; The transitive closure of local requires from `entries', entries INCLUDED,
;; deduplicated and sorted so the resulting code list is stable across runs (the
;; cache hashes it as a set of path->hash pairs, and a stable order keeps the
;; recorded entry byte-identical build to build).
;;
;; A required path that does not exist is kept but not traversed: the cache then
;; reports it unresolvable and forces a rerun, which is the conservative outcome.
(define (rkt-import-closure . entries)
  (let loop ([frontier (map (lambda (p) (simplify-path (path->complete-path p))) entries)]
             [seen (set)])
    (cond
      [(null? frontier) (sort (set->list seen) path<?)]
      [(set-member? seen (car frontier)) (loop (cdr frontier) seen)]
      [else
       (define p (car frontier))
       (define next (if (file-exists? p) (module-local-requires p) '()))
       (loop (append next (cdr frontier)) (set-add seen p))])))

(define (path<? a b) (string<? (path->string a) (path->string b)))
