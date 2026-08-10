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
         runtime runtime? runtime-name runtime-launch runtime-label
         runtime-identity
         recipe recipe? recipe-runtime recipe-args recipe-code
         derivation derivation? derivation-label derivation-run derivation-code
         (struct-out optional-code)
         code-entry-path
         invoke-code
         recipe->argv
         make-artifact
         make-task
         build-graph
         producer-of
         leaf-expectation
         check-graph-leaves
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
;;   provenance  : WHERE IT COMES FROM — and so whether this graph produces it.
;;                 'derived       — a task here produces it; safe to destroy and
;;                                  rebuild. MUST have a producer.
;;                 'authoritative — forward-only state we own (a CRUD store, a
;;                                  curated override file). Never rebuilt from
;;                                  scratch — migrations only. MAY or may not have
;;                                  a producer: a task here can write forward-only
;;                                  state (cache.rkt excludes such outputs from
;;                                  cutoff), and so can a writer outside the graph.
;;                 'upstream      — somebody else's data, snapshotted in (a
;;                                  Bee-Gap extract, a boundary relation loaded
;;                                  outside the nightly). Also unproducible here,
;;                                  but for a different reason than
;;                                  'authoritative: it is not ours to write
;;                                  forward, so there is no migration story — and
;;                                  it MUST NOT have a producer.
;;                 So provenance answers "what may the engine do to this", and
;;                 answers "is the producer in this graph" only for three of the
;;                 four values. See leaf-expectation.
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
;; The two CLOSED vocabularies, as values rather than inlined at each use, so the
;; struct comment above and the checks below cannot drift apart.
(define ARTIFACT-KINDS '(file dir db-relation external token code))
(define ARTIFACT-PROVENANCES '(derived authoritative upstream))

;; ...and they are CHECKED, not merely documented (found in review, 2026-08-06).
;; A typo'd provenance on a PRODUCED artifact is otherwise invisible: it is not a
;; leaf and it has a producer, so check-graph-leaves calls it consistent — and then
;; every cache.rkt site filters `(eq? 'derived ...)', so the output is never
;; observed, never receipted, and early cutoff silently cannot fire. A green build
;; that quietly stopped cutting off is the same failure class the leaf and edge
;; checks exist to remove, and adding a third provenance value widened the way in.
(define (make-artifact name kind
                       #:fingerprint [fingerprint #f]
                       #:provenance [provenance 'derived]
                       #:keyed-by [keyed-by #f]
                       #:imports [imports '()])
  (unless (memq kind ARTIFACT-KINDS)
    (error 'make-artifact "~a: unknown kind ~a — expected one of ~a"
           name kind ARTIFACT-KINDS))
  (unless (memq provenance ARTIFACT-PROVENANCES)
    (error 'make-artifact "~a: unknown provenance ~a — expected one of ~a"
           name provenance ARTIFACT-PROVENANCES))
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
;;   name     : symbol
;;   launch   : (listof string)  argv prefix, e.g. '("uv" "run" "--directory" D "python")
;;   label    : string           short display tag, e.g. "uv/3.14"
;;   identity : (or/c (listof string) #f) — probe argv APPENDED to `launch' whose
;;              stdout names the RESOLVED interpreter (st-jkl), e.g. '("--version").
;;              The pin file a launch reads (.nvmrc) is a RANGE and a request; the
;;              interpreter that answers it is an INPUT to the bytes, so its
;;              observed identity joins the task's input address like any other
;;              input observation (cache.rkt). Through-the-launch on purpose: the
;;              probe must see exactly the interpreter the tasks get, warning
;;              fallbacks and all. #f = this runtime declares no identity worth
;;              observing (sh), or its launch cannot be probed without side
;;              effects at plan time (uv run syncs the venv at first touch, dbt's
;;              uvx resolves over the network) — those need their own decision.
(struct runtime (name launch label identity) #:transparent
  #:omit-define-syntaxes #:constructor-name make-runtime)
(define (runtime name launch label [identity #f])
  (make-runtime name launch label identity))

;; A task's invocation: a runtime (by name) + the task-specific argv tail, plus
;; the CODE behind the command (st-top) — the named script file(s) it executes,
;; as resolved paths. Task code is an input to the task's output, so the cache
;; hashes each file's content into the input address: editing a script
;; invalidates its cache exactly like editing data would. Named files only —
;; transitive imports are deliberately not traced; a task known to lean on a
;; shared helper declares it in `code' explicitly.
;;   runtime : symbol
;;   args    : (listof string)
;;   code    : (listof code-entry) — each a FILE (hashed by its bytes), a
;;             DIRECTORY (st-0ql: expanded per-file, e.g. dbt's models/), or
;;             either of those wrapped in `optional-code' (st-e4y: absence is a
;;             value, not a failure to look); '() when the command carries no
;;             code on disk (an inline sh script)
(struct recipe (runtime args code) #:transparent
  #:omit-define-syntaxes #:constructor-name make-recipe)
(define (recipe runtime args [code '()]) (make-recipe runtime args code))

;; A code entry whose ABSENCE is a legitimate steady state (st-e4y). An ordinary
;; code path that isn't on disk is UNREADABLE — the cache can't address the task,
;; so it stays conservative and reruns forever ('inputs-unresolvable). That is
;; right when absence means "I cannot tell" (an unmounted store, an unbuilt mart)
;; and wrong when absence is a fact the build can observe and that can END.
;;
;; Vite's env files are the case: it loads `.env`, `.env.local`, `.env.production`
;; and `.env.production.local` in production mode and bakes VITE_* values into the
;; emitted chunks. Only `.env` exists. Declaring all four as ordinary code pins the
;; bundle task permanently un-skippable; declaring only the one that exists makes a
;; `.env.production` appearing later INVISIBLE to the cache — beeatlas ADR 0019's
;; expensive failure (rotate the token, the gate skips nightly, the live site keeps
;; serving the revoked one).
;;
;; Wrapping resolves the ambiguity in the only place that knows it: the DECLARATION.
;; `#f` keeps its single meaning, "not addressable"; an optional entry that is
;; absent addresses to a stable sentinel instead (cache.rkt's ABSENT-ADDRESS), so
;; appearing and disappearing are ordinary content changes and a task whose optional
;; inputs are all still absent can skip.
;;
;; Code entries only, deliberately: an absent ARTIFACT keeps the conservative
;; reading, because nothing yet asks for a legitimately-absent one and the two cases
;; differ — a missing artifact is usually an unbuilt upstream, which is exactly the
;; "I cannot tell" that should force a rerun.
(struct optional-code (path) #:transparent)

;; code-entry-path : code-entry -> path-string
;; The path inside a code entry, wrapped or not — for callers that want the path
;; and not the optionality.
(define (code-entry-path e)
  (if (optional-code? e) (optional-code-path e) e))

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
  ;; st-5e6: every name on an edge must be a DECLARED artifact. Without this a
  ;; typo does not error — the name just has no producer, which reads as an
  ;; external leaf (see check-graph-leaves), so the edge silently vanishes from
  ;; every plan AND the task stops being invalidated by that input. A typo'd
  ;; OUTPUT is worse still: it registers a producer for an artifact nobody
  ;; declared, while the real one keeps its old producer or none, and the
  ;; double-producer check below cannot fire because the two names differ.
  (define (check-edge-names! t direction names)
    (for ([n (in-list names)])
      (unless (hash-has-key? artifact-table n)
        (error 'build-graph
               "task ~a declares ~a ~a, which is not a declared artifact"
               (task-name t) direction n))))
  (for ([t (in-list tasks)])
    (check-edge-names! t 'input  (task-inputs t))
    (check-edge-names! t 'output (task-outputs t)))
  (define producer-index
    (for*/fold ([acc (hash)]) ([t (in-list tasks)]
                               [out (in-list (task-outputs t))])
      (when (hash-has-key? acc out)
        (error 'build-graph
               "artifact ~a is produced by both ~a and ~a"
               out (hash-ref acc out) (task-name t)))
      (hash-set acc out (task-name t))))
  (define g (graph task-table artifact-table producer-index))
  (check-graph-leaves g)
  g)

;; producer-of : graph symbol -> (or/c symbol #f)
;; The task that produces artifact `a', or #f if it is a leaf. #f alone does not
;; mean the leaf was INTENDED — check-graph-leaves is what establishes that.
(define (producer-of g a)
  (hash-ref (graph-producer-index g) a #f))

;; --- Leaf declarations (st-zb9) ----------------------------------------------
;;
;; required-tasks stops its backward walk at any artifact with no producer. That
;; is right for a genuine leaf and SILENT for an artifact whose producing task was
;; never written — both read as "nothing to run", so a forgotten producer prunes
;; the upstream out of every plan instead of failing. Audited 2026-08-06, the
;; beeatlas graph had 16 producerless artifacts of which exactly one said so.
;;
;; So leafness is DECLARED, and the declaration is checked against the topology
;; rather than trusted. The declaration is READ from what the artifact already
;; says — the rebuild-policy.rkt argument: a `#:leaf?' slot would be a second
;; source of truth able to contradict `provenance', and an artifact declaring
;; both 'derived and #:leaf? #t is a bug no type would catch.
;;
;;   MUST BE A LEAF — 'code (a shared helper, st-whi) and 'external (opaque,
;;                    resolves to #f) by kind; 'upstream by origin, since data
;;                    that is not ours is not ours to produce either.
;;   MUST BE PRODUCED — 'derived of a producible kind. This is the arm that
;;                    catches a forgotten producer, and the reason for the check.
;;   EITHER — 'authoritative. Forward-only state may be written by a task in this
;;                    graph or by a writer outside it, and provenance does not say
;;                    which. See leaf-expectation for why this is not a gap that
;;                    can be closed by naming it better.

;; leaf-expectation : artifact -> 'leaf | 'produced | 'either
;;
;; 'authoritative is deliberately 'either, and that asymmetry cost a design error
;; worth recording. Forward-only state can be written by a task INSIDE this graph
;; (cache.rkt has always supported this — "Authoritative outputs are excluded;
;; cutoff applies only to derived state", because a forward-only write is an effect
;; and "rebuilt to identical bytes" is not a claim we make about it) or by a writer
;; OUTSIDE it (notes-store.db, whose writer is the notes worker; the curated seeds,
;; whose writer is a person with git). Provenance answers "what may the engine do
;; to this", and both of those get the same answer — so provenance cannot also
;; answer "is the producer in this graph". For the other three values it can, and
;; does.
;;
;; The first cut of this asserted 'authoritative ⇒ leaf. beeatlas has no
;; authoritative OUTPUT today, so the real graph passed and the claim looked true;
;; it was cache-test's `out' that falsified it. Hence the residual hole below.
(define (leaf-expectation a)
  (cond
    [(memq (artifact-kind a) '(code external)) 'leaf]
    [(eq? (artifact-provenance a) 'upstream)   'leaf]
    [(eq? (artifact-provenance a) 'authoritative) 'either]
    [else 'produced]))

;; check-graph-leaves : graph -> void
;; Raises unless every artifact's leaf DECLARATION matches its topology, in both
;; directions — a declared leaf with a producer is as much a bug as a producible
;; artifact without one. Reports every disagreement at once, sorted, because the
;; first run over an un-annotated graph finds a batch and fixing them one error
;; per run would be tedious.
;;
;; Called at GRAPH-CONSTRUCTION time (beeatlas.rkt, immediately after build-graph)
;; rather than from main.rkt's build-mode validation, so it fires on every entry
;; point — `--why' and `--explain' included — and while someone is editing the
;; graph rather than on the later build where a missing producer finally matters.
(define (check-graph-leaves g)
  (define problems
    (sort
     (for*/list ([(name a) (in-hash (graph-artifacts g))]
                 [producer (in-value (producer-of g name))]
                 [expect (in-value (leaf-expectation a))]
                 #:unless (or (eq? expect 'either)
                              (eq? expect (if producer 'produced 'leaf))))
       (cons name
             (if producer
                 (format "~a is declared a leaf (kind ~a, provenance ~a) but task ~a produces it"
                         name (artifact-kind a) (artifact-provenance a) producer)
                 (format "~a has no producer and nothing declares it a leaf (kind ~a, provenance ~a)"
                         name (artifact-kind a) (artifact-provenance a)))))
     symbol<? #:key car))
  (unless (null? problems)
    (error 'check-graph-leaves
           "~a artifact(s) disagree with their leaf declaration:\n~a\n~a"
           (length problems)
           (apply string-append
                  (for/list ([p (in-list problems)]) (format "  - ~a\n" (cdr p))))
           (string-append
            "  A producible artifact needs a task that outputs it — if one exists, check\n"
            "  that its output name is spelled the same. An artifact that comes from\n"
            "  outside the graph must say so: #:provenance 'authoritative (forward-only\n"
            "  state we own) or 'upstream (somebody else's data, snapshotted in)."))))

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
