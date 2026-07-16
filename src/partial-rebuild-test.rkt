#lang racket/base

;; Tests the executor-level partial-rebuild primitive (st-pd1 B1): run-task honors
;; #:rebuild-keys by injecting STELIS_REBUILD_KEYS, an exporter that reads it emits
;; only those keys into the existing EXPORT_DIR (merge in place), and prune-keys!
;; retracts removed keys. A synthetic /bin/sh exporter stands in for a real one, so
;; the mechanism is proven hermetically with identity key->relpath.

(require rackunit
         racket/file
         "model.rkt"
         "exec.rkt")

;; a synthetic exporter: writes one file per key into $EXPORT_DIR/maps, with
;; content "<key>:<TAG>". Honors STELIS_REBUILD_KEYS (only those keys); absent it,
;; writes the full set a/b/c. TAG varies content across builds so a rebuild shows.
(define script #<<SH
mkdir -p "$EXPORT_DIR/maps"
if [ -n "$STELIS_REBUILD_KEYS" ]; then keys="$STELIS_REBUILD_KEYS"; else keys='a
b
c'; fi
printf '%s\n' "$keys" | while IFS= read -r k; do
  [ -n "$k" ] && printf '%s' "$k:$TAG" > "$EXPORT_DIR/maps/$k"
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

(delete-directory/files out)
