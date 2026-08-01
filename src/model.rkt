#lang racket/base

;; The build-graph model and the minimal-upstream plan computation.
;; See docs/adr/0001-build-graph-model.md for the design and its reasons.
;;
;; The graph is bipartite: task nodes consume and produce artifact nodes.
;; A single source of truth for producer edges: a task's `outputs' list. An
;; artifact with no producing task is an external/ingestion leaf.

(require racket/list
         racket/set
         (only-in "dasl.rkt" cid->string)
         (only-in "drisl.rkt" drisl-cid))

(provide (struct-out artifact)
         (struct-out task)
         (struct-out graph)
         (struct-out runtime)
         recipe recipe? recipe-runtime recipe-args recipe-code
         derivation derivation? derivation-label derivation-run derivation-code
         invoke-code
         recipe->argv
         make-artifact
         make-task
         build-graph
         producer-of
         producers-of-inputs
         code-closure
         required-tasks
         topo-sort
         plan
         GRAPH-SNAPSHOT-VERSION
         graph->datum
         graph->drisl
         drisl->graph-datum
         graph-digest)

;; --- Node types -------------------------------------------------------------

;; An artifact node: a logical dataset.
;;   name        : symbol
;;   kind        : 'file | 'dir | 'db-relation | 'external | 'token | 'code
;;                 'dir is a directory TREE — a data-dependent output SET, content-
;;                 addressed by an order-independent tree digest (tree-digest.rkt).
;;                 'code is a source FILE consumed as an input (a shared Python
;;                 helper, st-whi): hashed by its bytes like a 'file, but the
;;                 cache reports a change to it as 'code-changed, not
;;                 'input-changed — the kind IS the reason partition.
;;   fingerprint : content/version fingerprint; #f until computed (see cache.rkt)
;;   provenance  : 'derived (safe to destroy and rebuild) | 'authoritative
;;                 (forward-only; never rebuilt from scratch — migrations only)
;;   keyed-by    : #f, or (for a 'dir) a declaration of the key SET the
;;                 directory's files fan out over: a list of fan-out branches
;;                 (columns of an input relation, st-tul), a manifest-key
;;                 (exporter-emitted manifest, st-q6i), or a store-keyed identity
;;                 (a keyed store's exact keyset, st-243). Opaque here —
;;                 interpreted by fan-out-key.rkt; it lets the SET be verified,
;;                 not just the tree hashed.
;;   imports     : ('code only) the code artifacts this file DIRECTLY imports —
;;                 the helper→helper edges (st-whi). Task→helper edges are
;;                 ordinary task inputs; transitive dependence is the walk over
;;                 these (code-closure below / plan-datalog's imports rule), so
;;                 nothing flattens the closure into a stored list. '() otherwise.
(struct artifact (name kind fingerprint provenance keyed-by imports) #:transparent)

;; A task node.
;;   name    : symbol  (matches the run.py step name)
;;   kind    : 'transform | 'gate | 'boundary
;;   inputs  : (listof symbol)  artifact names it consumes
;;   outputs : (listof symbol)  artifact names it produces
;;   invoke  : execution recipe (see exec.rkt), or #f for a task without one
(struct task (name kind inputs outputs invoke) #:transparent)

;; Keyword smart-constructors so the reserved slots default to #f and the
;; authored graph reads cleanly.
(define (make-artifact name kind
                       #:fingerprint [fingerprint #f]
                       #:provenance [provenance 'derived]
                       #:keyed-by [keyed-by #f]
                       #:imports [imports '()])
  (artifact name kind fingerprint provenance keyed-by imports))

(define (make-task name kind
                   #:inputs [inputs '()]
                   #:outputs [outputs '()]
                   #:invoke [invoke #f])
  (task name kind inputs outputs invoke))

;; --- Execution recipe types ---------------------------------------------------
;; The TYPES behind a task's `invoke' slot live here rather than exec.rkt so the
;; cache layer can content-address a recipe without depending on the executor
;; (exec.rkt requires cache.rkt). The BEHAVIOR — launching subprocesses — stays
;; in exec.rkt, which re-provides these names for its existing callers.

;; A hermetic runtime: how to launch a task in a pinned interpreter/env.
;;   name   : symbol
;;   launch : (listof string)  argv prefix, e.g. '("uv" "run" "--directory" D "python")
;;   label  : string           short display tag, e.g. "uv/3.14"
(struct runtime (name launch label) #:transparent)

;; A task's invocation: a runtime (by name) + the task-specific argv tail, plus
;; the CODE behind the command (st-top) — the named script file(s) it executes,
;; as resolved paths. Task code is an input to the task's output, so the cache
;; hashes each file's content into the input address: editing a script
;; invalidates its cache exactly like editing data would. Named files only —
;; transitive imports are deliberately not traced; a task known to lean on a
;; shared helper declares it in `code' explicitly.
;;   runtime : symbol
;;   args    : (listof string)
;;   code    : (listof path-string) — each a FILE (hashed by its bytes) or a
;;             DIRECTORY (st-0ql: expanded per-file, e.g. dbt's models/); '()
;;             when the command carries no code on disk (an inline sh script)
(struct recipe (runtime args code) #:transparent
  #:omit-define-syntaxes #:constructor-name make-recipe)
(define (recipe runtime args [code '()]) (make-recipe runtime args code))

;; A DERIVATION (st-ozp): a task whose transform runs IN-PROCESS and produces an
;; artifact. The third `invoke' variant, beside `recipe' (shell out) and
;; `rule-check' (in-process, returns a gate verdict but writes nothing).
;;
;; This is the first transform that lives INSIDE the engine, and it crosses the
;; Horizon 1 "transformations stay external" guardrail deliberately — ADR 0008
;; decision 5: what earns Stelis-side is unbounded-depth closure with defeasible
;; override and a native "why", and nothing else. Bounded joins and bulk
;; aggregation stay in dbt/DuckDB.
;;
;; It lives here rather than in exec.rkt for the same reason `recipe' does: the
;; cache layer content-addresses its `code', and exec.rkt requires cache.rkt.
;;   label : string — short display tag (e.g. "taxon-traits")
;;   run   : (check-context -> (values boolean string)) — writes the task's
;;           outputs and returns a verdict plus a human note. #f FAILS the node,
;;           blocking downstream exactly like a non-zero exit.
;;   code  : (listof path-string) — the ENGINE SOURCE implementing the rule (the
;;           rule module itself). When the transform is in-process, Stelis's own
;;           source IS task code: editing the rules must invalidate the cache the
;;           way editing a Python exporter does (st-top's argument, turned inward).
;;           The authored FACTS are not here — they are an input ARTIFACT, so they
;;           show up in --why and the graph snapshot as the data they are.
(struct derivation (label run code) #:transparent
  #:omit-define-syntaxes #:constructor-name make-derivation)
(define (derivation label run [code '()]) (make-derivation label run code))

;; invoke-code : any -> (listof path-string)
;; The code files behind a task's `invoke', whatever variant it is — the one
;; place that knows which variants carry code. '() for a variant that carries
;; none (rule-check, or no invoke at all).
(define (invoke-code inv)
  (cond
    [(recipe? inv)     (recipe-code inv)]
    [(derivation? inv) (derivation-code inv)]
    [else '()]))

;; recipe->argv : recipe (hash symbol->runtime) -> (listof string)
;; The full command: the runtime's launch prefix followed by the recipe's args.
(define (recipe->argv rec runtimes)
  (define rt (hash-ref runtimes (recipe-runtime rec)
                       (lambda ()
                         (error 'recipe->argv "unknown runtime: ~a" (recipe-runtime rec)))))
  (append (runtime-launch rt) (recipe-args rec)))

;; --- The graph --------------------------------------------------------------

;; A graph bundles the nodes plus a derived producer index.
;;   tasks       : hash  symbol -> task
;;   artifacts   : hash  symbol -> artifact
;;   producer-of : hash  artifact-name -> task-name   (derived from task outputs)
(struct graph (tasks artifacts producer-index) #:transparent)

;; build-graph : (listof task) (listof artifact) -> graph
;; Derives the producer index from task outputs (the single source of truth),
;; and checks that no two tasks claim the same output.
(define (build-graph tasks artifacts)
  (define task-table
    (for/hash ([t (in-list tasks)]) (values (task-name t) t)))
  (define artifact-table
    (for/hash ([a (in-list artifacts)]) (values (artifact-name a) a)))
  (define producer-index
    (for*/fold ([acc (hash)]) ([t (in-list tasks)]
                               [out (in-list (task-outputs t))])
      (when (hash-has-key? acc out)
        (error 'build-graph
               "artifact ~a is produced by both ~a and ~a"
               out (hash-ref acc out) (task-name t)))
      (hash-set acc out (task-name t))))
  (graph task-table artifact-table producer-index))

;; producer-of : graph symbol -> (or/c symbol #f)
;; The task that produces artifact `a', or #f if it is an external leaf.
(define (producer-of g a)
  (hash-ref (graph-producer-index g) a #f))

;; producers-of-inputs : graph symbol (symbol -> any/c) -> (listof symbol)
;; The distinct producers of `name's inputs that satisfy `keep?', in input
;; order. The shared shape behind "which upstreams block me / make me stale /
;; are in this plan" — the caller supplies the filter.
(define (producers-of-inputs g name keep?)
  (remove-duplicates
   (for*/list ([in (in-list (task-inputs (hash-ref (graph-tasks g) name)))]
               [p (in-value (producer-of g in))]
               #:when (and p (keep? p)))
     p)))

;; code-closure : graph (listof symbol) -> (listof symbol)
;; The transitive import closure of `seeds' (code-artifact names — typically a
;; task's 'code inputs) over the artifacts' `imports' edges, sorted, seeds
;; included. This is the plain-Racket twin of plan-datalog's imports rule (the
;; same two-planner parity as required-tasks): the cache walks it to address a
;; task's full code dependence without any layer flattening the closure into a
;; stored list. A name with no artifact record is kept but not traversed — the
;; cache then fails to resolve it and stays conservative.
(define (code-closure g seeds)
  (let loop ([frontier seeds] [seen (set)])
    (cond
      [(null? frontier) (sort (set->list seen) symbol<?)]
      [(set-member? seen (car frontier)) (loop (cdr frontier) seen)]
      [else
       (define a (hash-ref (graph-artifacts g) (car frontier) #f))
       (loop (append (if a (artifact-imports a) '()) (cdr frontier))
             (set-add seen (car frontier)))])))

;; --- Plan: minimal upstream + topological order -----------------------------

;; required-tasks : graph symbol -> (setof symbol)
;; The set of task names that must run to produce `target' (an artifact name).
;; Walks backward: to make an artifact, run its producer task; that task needs
;; its input artifacts; recurse. External leaves (no producer) stop the walk.
(define (required-tasks g target)
  (let loop ([artifact-name target] [seen (set)])
    (define producer (producer-of g artifact-name))
    (cond
      [(not producer) seen]                 ; external leaf: nothing to run
      [(set-member? seen producer) seen]    ; already accounted for
      [else
       (define t (hash-ref (graph-tasks g) producer))
       (for/fold ([seen (set-add seen producer)])
                 ([in (in-list (task-inputs t))])
         (loop in seen))])))

;; topo-sort : graph (setof symbol) -> (listof symbol)
;; Orders the given task names so every task follows the tasks producing its
;; inputs. Kahn's algorithm over the task-level dependency graph induced by the
;; artifact edges. Errors on a cycle (the build graph must be a DAG).
(define (topo-sort g task-names)
  ;; task-level deps: T depends on the producers of T's inputs that are also
  ;; in the required set.
  (define (deps-of name)
    (define t (hash-ref (graph-tasks g) name))
    (for*/set ([in (in-list (task-inputs t))]
               [p (in-value (producer-of g in))]
               #:when (and p (set-member? task-names p)))
      p))
  (define deps (for/hash ([n (in-set task-names)]) (values n (deps-of n))))
  (let loop ([deps deps] [order '()])
    (cond
      [(zero? (hash-count deps)) (reverse order)]
      [else
       (define ready
         (sort (for/list ([(n ds) (in-hash deps)] #:when (set-empty? ds)) n)
               symbol<?))                    ; sort ready set for stable output
       (when (null? ready)
         (error 'topo-sort "dependency cycle among: ~a" (hash-keys deps)))
       (define done (list->set ready))
       (define deps*
         (for/hash ([(n ds) (in-hash deps)] #:unless (set-member? done n))
           (values n (set-subtract ds done))))
       (loop deps* (append (reverse ready) order))])))

;; plan : graph symbol -> (values (listof symbol) (setof symbol))
;; Returns the required tasks in topological order, and the set of tasks in the
;; graph that were pruned (not upstream of the target) — the pruning is the
;; whole point, so we surface it.
(define (plan g target)
  (define required (required-tasks g target))
  (define ordered (topo-sort g required))
  (define all-tasks (list->set (hash-keys (graph-tasks g))))
  (values ordered (set-subtract all-tasks required)))

;; --- Graph snapshot + digest (st-sds) ---------------------------------------

;; The topology snapshot's own shape version — INDEPENDENT of history.rkt's
;; HISTORY-VERSION (which versions the build-record log). Decoupling them is
;; deliberate: a change to the trace-record shape bumps HISTORY-VERSION but leaves
;; topology snapshots (keyed by graph-hash, unchanged) perfectly readable. Bump
;; this only when graph->datum's shape changes.
;; v2 (st-whi): artifact entries gained a fourth element, the `imports' edge
;; list — helper→helper import edges ARE topology (a new import changes what a
;; task transitively depends on), so they must move the graph digest.
;; v3 (st-b7v): the snapshot is written as a DRISL block and addressed by its CID.
;; The DATUM below is unchanged; what changed is how it is written down and named,
;; so every v2 snapshot on disk is simply unreadable and re-written on next build —
;; in policy, since .stelis/ is derived, disposable, format-versioned state.
(define GRAPH-SNAPSHOT-VERSION 3)

;; graph->datum : graph -> list
;; A `read'-able TOPOLOGY snapshot: nodes (artifact name/kind/provenance/imports)
;; and edges (each task's name/kind/inputs/outputs). This is the shape history
;; persists once per distinct graph, so build N's topology can be reconstructed
;; without re-running Racket, and topology drift between builds is detectable.
;; Deliberately omits recipes (`invoke') and fan-out `keyed-by' branches — those
;; aren't topology; recipe change is the cache's job (recipe-hash), and keyed-by
;; holds opaque structs that don't round-trip through `read'. Artifacts and
;; tasks sort by name so the datum is canonical; inputs/outputs — and an
;; artifact's imports, already sorted by the authoring scan — keep their
;; authored order (deterministic) so the snapshot stays faithful.
(define (graph->datum g)
  (list 'stelis-graph GRAPH-SNAPSHOT-VERSION
        (sort (for/list ([a (in-hash-values (graph-artifacts g))])
                (list (artifact-name a) (artifact-kind a) (artifact-provenance a)
                      (artifact-imports a)))
              symbol<? #:key car)
        (sort (for/list ([t (in-hash-values (graph-tasks g))])
                (list (task-name t) (task-kind t)
                      (task-inputs t) (task-outputs t)))
              symbol<? #:key car)))

;; --- The snapshot as a DRISL block (st-b7v) ----------------------------------
;; The datum above is a Racket shape; this is how it is WRITTEN DOWN. The two are
;; kept apart on purpose: `read'-ability is what makes the datum convenient in
;; Racket, and it is exactly what made the old digest — sha1 over `(format "~s"
;; ...)` — canonical only by habit, resting on Racket's printer rather than on a
;; spec. A DRISL block has one spelling per value by definition, so its sha-256 is
;; the graph's IDENTITY rather than a fingerprint of a printing.
;;
;; Symbols are the whole of the impedance: DRISL has text strings and no symbols,
;; so every name crosses as a string and crosses back through `string->symbol'.
;; Field names are spelled out rather than positional — a block should be legible
;; to a reader that has never seen graph->datum.

(define GRAPH-BLOCK-FORMAT "stelis-graph")

(define (syms->strings xs) (map symbol->string xs))
(define (strings->syms xs) (map string->symbol xs))

;; graph->drisl : graph -> hash
;; The snapshot as a DRISL value, ready for `drisl-encode'.
(define (graph->drisl g)
  (define d (graph->datum g))
  (hash "format" GRAPH-BLOCK-FORMAT
        "version" (cadr d)
        "artifacts" (for/list ([a (in-list (caddr d))])
                      (hash "name" (symbol->string (car a))
                            "kind" (symbol->string (cadr a))
                            "provenance" (symbol->string (caddr a))
                            "imports" (syms->strings (cadddr a))))
        "tasks" (for/list ([t (in-list (cadddr d))])
                  (hash "name" (symbol->string (car t))
                        "kind" (symbol->string (cadr t))
                        "inputs" (syms->strings (caddr t))
                        "outputs" (syms->strings (cadddr t))))))

;; drisl->graph-datum : any -> (or/c list #f)
;; The inverse, back to the graph->datum shape — #f for anything that is not a
;; snapshot block of the version this Stelis speaks. Total and non-raising: a
;; foreign or stale block is a MISS, exactly as an unparseable history line is.
(define (drisl->graph-datum v)
  (define (field h k pred) (define x (hash-ref h k #f)) (and (pred x) x))
  (with-handlers ([exn:fail? (lambda (_) #f)])
    (and (hash? v)
         (equal? GRAPH-BLOCK-FORMAT (field v "format" string?))
         (equal? GRAPH-SNAPSHOT-VERSION (field v "version" exact-integer?))
         (list? (hash-ref v "artifacts" #f))
         (list? (hash-ref v "tasks" #f))
         (list 'stelis-graph GRAPH-SNAPSHOT-VERSION
               (for/list ([a (in-list (hash-ref v "artifacts"))])
                 (list (string->symbol (hash-ref a "name"))
                       (string->symbol (hash-ref a "kind"))
                       (string->symbol (hash-ref a "provenance"))
                       (strings->syms (hash-ref a "imports"))))
               (for/list ([t (in-list (hash-ref v "tasks"))])
                 (list (string->symbol (hash-ref t "name"))
                       (string->symbol (hash-ref t "kind"))
                       (strings->syms (hash-ref t "inputs"))
                       (strings->syms (hash-ref t "outputs"))))))))

;; graph-digest : graph -> string
;; The graph's identity in history: the CID of its snapshot block, in the `b`
;; base32 string form. Same topology twice ⇒ same CID, now by specification.
(define (graph-digest g) (cid->string (drisl-cid (graph->drisl g))))
