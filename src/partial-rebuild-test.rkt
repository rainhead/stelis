#lang racket/base

;; Tests the executor-level partial-rebuild primitive (st-pd1 B1): run-task honors
;; #:rebuild-keys by injecting STELIS_REBUILD_KEYS, an exporter that reads it emits
;; only those keys into the existing EXPORT_DIR (merge in place), and prune-keys!
;; retracts removed keys. A synthetic /bin/sh exporter stands in for a real one, so
;; the mechanism is proven hermetically with identity key->relpath.

(require rackunit
         racket/file
         "model.rkt"
         "cache.rkt"
         "exec.rkt")

;; a synthetic exporter: writes one file per key into $EXPORT_DIR/maps, with
;; content "<key>:<TAG>". Honors STELIS_REBUILD_KEYS (only those keys); absent it,
;; writes the full set a/b/c. TAG varies content across builds so a rebuild shows.
(define script #<<SH
mkdir -p "$EXPORT_DIR/maps"
if [ -n "${STELIS_REBUILD_KEYS+set}" ]; then keys="$STELIS_REBUILD_KEYS"; else keys='a
b
c'; fi
printf '%s\n' "$keys" | while IFS= read -r k; do
  if [ -n "$k" ]; then printf '%s' "$k:$TAG" > "$EXPORT_DIR/maps/$k"; fi
done
SH
  )

(define runtimes (hash 'sh (runtime 'sh '("/bin/sh" "-c") "sh")))
(define g
  (build-graph
   (list (make-task 'export 'transform #:outputs '(maps) #:invoke (recipe 'sh (list script))))
   (list (make-artifact 'maps 'dir))))

(define out (make-temporary-file "stelis-partial-~a" 'directory))
(define maps (build-path out "maps"))
(define (env tag) (list (cons "EXPORT_DIR" (path->string out)) (cons "TAG" tag)))
(define (content k) (file->string (build-path maps k)))
(define (files) (sort (map path->string (directory-list maps)) string<?))

;; 1. full build (no rebuild-keys): the whole set at v1
(check-eqv? 0 (run-task g 'export runtimes #:env (env "v1")))
(check-equal? (files) '("a" "b" "c") "full build writes every key")
(check-equal? (content "b") "b:v1")

;; 2. PARTIAL rebuild of just "b": only b is rewritten, a and c untouched (merge)
(check-eqv? 0 (run-task g 'export runtimes #:env (env "v2") #:rebuild-keys '("b")))
(check-equal? (files) '("a" "b" "c") "partial rebuild leaves the set complete")
(check-equal? (content "b") "b:v2" "the targeted key was rebuilt")
(check-equal? (content "a") "a:v1" "an untouched key keeps its prior content (merge in place)")
(check-equal? (content "c") "c:v1" "...and so does the other")

;; 3. retraction: prune-keys! deletes removed keys' files, leaves the rest
(prune-keys! maps '("c"))
(check-equal? (files) '("a" "b") "prune-keys! removes exactly the retracted key")
(check-equal? (content "b") "b:v2" "surviving keys are untouched by the prune")

;; 4. prune is idempotent — pruning an absent key is a no-op
(prune-keys! maps '("c"))
(check-equal? (files) '("a" "b") "pruning an already-absent key does nothing")

;; 5. no rebuild-keys given -> STELIS_REBUILD_KEYS not set -> full rebuild restores all
(check-eqv? 0 (run-task g 'export runtimes #:env (env "v3")))
(check-equal? (files) '("a" "b" "c") "a full rebuild (no keys) re-emits the whole set")
(check-equal? (content "a") "a:v3" "full rebuild rewrites every key")

;; 6. the empty-keys contract (st-pd1): #:rebuild-keys '() SETS the var (to "") ->
;; partial-of-NOTHING, distinct from unset=full. A pure-retraction rerun writes no
;; keys (the exporter honors set-vs-unset), leaving the prior build untouched.
(check-eqv? 0 (run-task g 'export runtimes #:env (env "v4") #:rebuild-keys '()))
(check-equal? (files) '("a" "b" "c") "empty rebuild-keys rebuilds nothing (merge preserved)")
(check-equal? (content "a") "a:v3" "no key was rewritten — v3 content survives")

(delete-directory/files out)

;; --- driven through run-plan, via #:rebuild-keys-of (st-pd1 B2) ----------------
;; The executor honors a caller-supplied partial plan during a real ordered build:
;; a task that reruns (input changed) rebuilds only the given keys and prunes the
;; removed ones, merging into the prior build's 'dir. `src' is an input whose change
;; forces the rerun; the exporter itself ignores it (it keys off TAG/the env var).
(define g2
  (build-graph
   (list (make-task 'export 'transform #:inputs '(src) #:outputs '(maps)
                    #:invoke (recipe 'sh (list script))))
   (list (make-artifact 'src 'file) (make-artifact 'maps 'dir))))

(define root (make-temporary-file "stelis-partial2-~a" 'directory))
(define odir (build-path root "out"))
(make-directory odir)
(define src-file (build-path root "src.txt"))
(define maps2 (build-path odir "maps"))
(define (resolve a export-dir)
  (case a [(maps) (build-path export-dir "maps")] [(src) src-file] [else #f]))
(define env2 (make-build-env resolve odir (build-path root "cache")))
(define (env-for tag) (list (cons "EXPORT_DIR" (path->string odir)) (cons "TAG" tag)))
(define (files2) (sort (map path->string (directory-list maps2)) string<?))
(define (content2 k) (file->string (build-path maps2 k)))

;; build 1: src=v1, no partial plan -> full build of a/b/c
(display-to-file "v1" src-file #:exists 'replace)
(let-values ([(_s _r) (run-plan g2 '(export) runtimes #:env (env-for "v1") #:context env2
                                #:state-dir (build-path root ".stelis"))]) (void))
(check-equal? (files2) '("a" "b" "c") "full first build")

;; build 2: src changes (forces a rerun); caller's partial plan rebuilds b, prunes c
(display-to-file "v2" src-file #:exists 'replace)
(let-values ([(_s _r) (run-plan g2 '(export) runtimes #:env (env-for "v2") #:context env2
                                #:state-dir (build-path root ".stelis")
                                #:rebuild-keys-of
                                (lambda (n) (if (eq? n 'export) (cons '("b") '("c")) #f)))]) (void))
(check-equal? (files2) '("a" "b") "run-plan partial: b rebuilt in place, c pruned")
(check-equal? (content2 "b") "b:v2" "the targeted key was rebuilt to the new tag")
(check-equal? (content2 "a") "a:v1" "an untouched key kept its prior content (merge)")

;; build 3: the merge basis is TAMPERED (st-243) — the on-disk dir no longer
;; matches the last clean run's receipt, so the caller's partial plan is refused
;; and the task rebuilds FULLY (every key rewritten, nothing pruned).
(display-to-file "hand-edited" (build-path maps2 "a") #:exists 'replace)
(display-to-file "v3" src-file #:exists 'replace)
(let-values ([(_s _r) (run-plan g2 '(export) runtimes #:env (env-for "v3") #:context env2
                                #:state-dir (build-path root ".stelis")
                                #:rebuild-keys-of
                                (lambda (n) (if (eq? n 'export) (cons '("b") '("a")) #f)))]) (void))
(check-equal? (files2) '("a" "b" "c")
              "a drifted dir forces a full rebuild: the whole set re-emitted, no prune")
(check-equal? (content2 "a") "a:v3" "the tampered key was rebuilt from scratch")
(check-equal? (content2 "c") "c:v3" "the previously-pruned key returns — full, not merged")

;; build 4: the receipt now reflects build 3's full rebuild, so partial works again
(display-to-file "v4" src-file #:exists 'replace)
(let-values ([(_s _r) (run-plan g2 '(export) runtimes #:env (env-for "v4") #:context env2
                                #:state-dir (build-path root ".stelis")
                                #:rebuild-keys-of
                                (lambda (n) (if (eq? n 'export) (cons '("b") '()) #f)))]) (void))
(check-equal? (content2 "b") "b:v4" "with a clean receipt the partial path re-engages")
(check-equal? (content2 "a") "a:v3" "…merging into the intact prior build")

(delete-directory/files root)
