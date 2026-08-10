#lang racket/base

;; Input-addressed task caching (st-d44.3), with reasons (st-yg7.1): the cache
;; layer answers not just WHETHER a task must run but WHY, as a pure `decision'
;; record — the provenance seed that --explain (slice 2) prints and the Datalog
;; layer (slice 3) turns into facts.
;;
;; The cache is DERIVED, DISPOSABLE state — a content-addressed sidecar per task
;; in a dedicated state dir (.stelis/cache/, gitignored). It is format-VERSIONED:
;; an entry whose version doesn't match, or that fails to parse, is treated as a
;; cache MISS (rebuild + rewrite), never an error. So the format can churn freely
;; while we iterate — a change just invalidates the cache. Deleting the dir only
;; forces a full rebuild. (Uses sha1, built-in; proper content-addressing / sha256
;; can swap in later without changing the shape.)

(require file/sha1
         racket/file
         racket/list
         racket/set
         racket/format
         racket/string
         "model.rkt"
         "tree-digest.rkt"
         "keyed-block.rkt")

(provide (struct-out decision)
         snapshot snapshot? snapshot-recipe-hash snapshot-input-hashes
         snapshot-code-hashes
         (struct-out output-delta)
         (struct-out source-report)
         (struct-out build-env)
         make-build-env
         env-resolve
         env-output-paths
         check-output-paths-resolvable
         ABSENT-ADDRESS
         input-snapshot
         input-store-snapshot
         artifact-key-parts
         env-dir-exclusions
         build-env-resolve-dir-exclusions
         output-snapshot
         output-snapshot+keys
         compare-outputs
         read-versioned
         read-cache-entry
         decide
         stale-relation-outputs
         stale-disk-outputs
         decision+snapshot
         task-decision
         cache-hit?
         cache-store!)

;; v3: output hashes recorded per artifact (st-8ig, early cutoff), so a rerun
;; can say whether it rebuilt to identical content. v2 entries read as misses.
;; v4: task CODE joins the input address (st-top) — per-file content hashes of
;; the recipe's named script(s), so editing a script invalidates the cache. v3
;; entries read as misses (one full rebuild on upgrade, by design).
(define CACHE-VERSION 4)

(define (file-sha1 path) (call-with-input-file path sha1))
(define (string-sha1 s) (sha1 (open-input-bytes (string->bytes/utf-8 s))))

;; --- Decisions ----------------------------------------------------------------

;; Why a task will run or may be skipped. Pure data, so it can be printed or
;; emitted as Datalog facts without re-deriving anything.
;;   verdict : 'run | 'skip
;;   reason  : 'boundary             ingestion — its real input is the external
;;                                   world, never content-skipped
;;           | 'inputs-unresolvable  not content-addressable; details name the
;;                                   artifacts (externals; relations/stores with
;;                                   no resolver; a token whose gate has never
;;                                   passed here, st-ysf) — or, as path strings,
;;                                   code files the recipe names that don't
;;                                   exist on disk (st-top)
;;           | 'no-cache-entry       never built here (or unreadable/old entry)
;;           | 'code-changed         the task's CODE changed (st-top) — details
;;                                   name the changed script file(s)
;;           | 'recipe-changed       the command/runtime changed
;;           | 'input-changed        details name the changed/added/removed inputs
;;           | 'output-missing       details name the missing output paths
;;           | 'output-stale         details name outputs that still EXIST but no
;;                                   longer match what this task built — a db-relation
;;                                   whose table was swapped/mutated under the cache
;;                                   (st-84u), or a file/dir rewritten on disk by
;;                                   something outside the graph (st-zh2)
;;           | 'cached               (verdict 'skip) inputs unchanged, outputs exist
;;                                   AND still match what this task produced
;;   details : reason-specific list; '() when there is nothing to name
(struct decision (verdict reason details) #:transparent)

;; What the cache compares: the task's recipe plus each input's content hash.
;;   recipe-hash  : string — the COMMAND identity: the resolved argv (launch
;;                  prefix included, so a runtime pin change invalidates too)
;;                  when a runtimes map is at hand, else the raw invoke value
;;   input-hashes : immutable hash, artifact name -> content hash
;;   code-hashes  : immutable hash, code path (string) -> content hash — the
;;                  recipe's named script file(s) (st-top). Task code is an
;;                  input; it just lives on the recipe, not in the graph.
(struct snapshot (recipe-hash input-hashes code-hashes) #:transparent
  #:omit-define-syntaxes #:constructor-name make-snapshot)
(define (snapshot recipe-hash input-hashes [code-hashes (hash)])
  (make-snapshot recipe-hash input-hashes code-hashes))

;; What early cutoff observed (st-8ig): after a task reran, how its rebuilt
;; outputs compare to the previous build's recorded hashes. 'identical is the
;; cutoff point — downstream tasks see unchanged inputs and cache-skip
;; naturally; nothing has to suppress them.
;;   status  : 'identical | 'changed
;;   details : artifact names — everything verified identical, or what changed
(struct output-delta (status details) #:transparent)

;; A 'boundary loader's SOURCE report (st-8bj): what a boundary task's own probe
;; concluded about its external source this run. DISTINCT from output-delta, which
;; compares OUTPUT bytes after the fact: a loader that probes its source and
;; short-circuits WITHOUT re-ingesting (e.g. ecdysis_pipeline's v2-API probe,
;; beeatlas-29j) never touches its outputs, so output-delta can only ever say
;; 'identical — it cannot say WHY. This is the loader speaking for itself: it writes
;; the report to the STELIS_BOUNDARY_RECEIPT path (exec.rkt), and Stelis reads it
;; post-run and records it, so --explain/--why can surface "source unchanged, 0
;; records since <date>" as a first-class build fact rather than the loader silently
;; reusing a cache behind Stelis's back. #f (no receipt) = the loader said nothing
;; (it re-ingested, or predates the probe) — indistinguishable from a plain run.
;;   unchanged? : boolean — the source was unchanged; the loader skipped ingestion
;;   records    : (or/c exact-nonnegative-integer #f) — records new since `since'
;;                (0 when unchanged), or #f when the loader didn't quantify it
;;   since      : (or/c string #f) — the watermark the probe compared against
;;                (a date or cursor, for display only), or #f
(struct source-report (unchanged? records since) #:transparent)

;; --- The build environment ------------------------------------------------------

;; How artifacts resolve to content and where build state lives — the trio every
;; cache-aware entry point needs, bundled so it travels as one value.
;;   resolve          : (symbol export-dir -> (or/c path-string #f))
;;                      where a FILE artifact lives (also used to place/verify
;;                      outputs). db-relations/tokens/externals have no path -> #f.
;;   export-dir       : path-string — the explicit output destination
;;   cache-dir        : path-string — the derived, disposable sidecar dir
;;   resolve-relation : (symbol -> (or/c string #f)) — a db-relation's content
;;                      hash, or #f when it can't be read (st-d5d). #f (the whole
;;                      slot) means "no relation resolver": relations then read as
;;                      inputs-unresolvable, exactly the pre-st-d5d behaviour.
;;   resolve-relation-columns : (symbol -> (or/c (listof (cons string string)) #f))
;;                      — a db-relation's PER-COLUMN observation (st-7vz): sorted
;;                      (part -> "digest:count") pairs, or #f. Output-side only
;;                      (the attribute-level refinement recorded on the trace); the
;;                      cache decision never consults it. #f slot = no per-column
;;                      layer (tests, callers that don't want it).
;;   resolve-store-keys : (symbol -> (or/c (listof (cons string string)) #f))
;;                      — a keyed 'file STORE's per-KEY read (st-2k9): sorted
;;                      (key -> "digest:count") pairs, or #f. The ingestion-boundary
;;                      analog of resolve-relation for an authoritative SQLite
;;                      store (the notes store, keyed by canonical_name); #f for a
;;                      plain file. UNLIKE the columns slot, the cache decision DOES
;;                      consult it: a keyed store's input address is the roll-up of
;;                      these pairs, NOT its raw file bytes — under SQLite WAL the
;;                      main db file's bytes freeze at the last checkpoint while
;;                      committed rows live in the -wal, so byte-hashing reads
;;                      "unchanged" forever and the decision layer would contradict
;;                      the per-key delta/observation layer this slot also feeds
;;                      (found live: the st-nee write path's first production note,
;;                      2026-07-17). Same coherence rule as 'dir (tree-digest is the
;;                      roll-up of tree-hashes) and db-relation (decision digest and
;;                      column observation read the same database).
;;   runtimes         : (or/c (hash symbol -> runtime) #f) — how recipes resolve
;;                      to commands (st-top): with it, a recipe's hash covers the
;;                      RESOLVED argv, so a runtime pin change invalidates like an
;;                      args change. #f (tests) falls back to the raw invoke value —
;;                      consistent within any env, so no thrash either way.
;;   resolve-runtime-identity : (or/c (symbol -> (or/c string #f)) #f) — the
;;                      observed identity of a runtime's RESOLVED interpreter
;;                      (st-jkl), for runtimes that declare an identity probe.
;;                      The pin file is a range and a request; the interpreter
;;                      that answers it is an input to the bytes, so observing it
;;                      is an input observation like resolve-relation's DuckDB
;;                      digest — IO injected here, never performed by this module.
(struct build-env
  (resolve export-dir cache-dir
   resolve-relation resolve-relation-columns resolve-store-keys runtimes
   resolve-dir-exclusions resolve-runtime-identity)
  #:transparent)

;; make-build-env : (symbol export-dir -> path?) path-string path-string
;;                  [#:resolve-relation (or/c (symbol -> (or/c string #f)) #f)]
;;                  [#:resolve-relation-columns
;;                     (or/c (symbol -> (or/c (listof (cons string string)) #f)) #f)]
;;                  [#:resolve-store-keys
;;                     (or/c (symbol -> (or/c (listof (cons string string)) #f)) #f)]
;;                  -> build-env?
;; Keyword constructor so callers that don't content-address relations/stores
;; (tests, the file-only paths) needn't mention the slots.
(define (make-build-env resolve export-dir cache-dir
                        #:resolve-relation [resolve-relation #f]
                        #:resolve-relation-columns [resolve-relation-columns #f]
                        #:resolve-store-keys [resolve-store-keys #f]
                        #:runtimes [runtimes #f]
                        ;; st-hdm: which nested artifacts a 'dir must NOT count as
                        ;; its own. Absent, a 'dir means its whole tree — the
                        ;; behaviour before any directory had two producers.
                        #:resolve-dir-exclusions [resolve-dir-exclusions #f]
                        #:resolve-runtime-identity [resolve-runtime-identity #f])
  (build-env resolve export-dir cache-dir
             resolve-relation resolve-relation-columns resolve-store-keys
             runtimes resolve-dir-exclusions resolve-runtime-identity))

;; env-dir-exclusions : build-env? symbol -> (listof path)
;; The roots inside `a` that belong to another artifact. '() when no resolver is
;; installed, which is every graph where no directory has two producers.
(define (env-dir-exclusions env a)
  (define f (build-env-resolve-dir-exclusions env))
  (if f (f a) '()))

;; env-resolve : build-env? symbol -> (or/c path-string #f)
(define (env-resolve env a)
  ((build-env-resolve env) a (build-env-export-dir env)))

;; env-output-paths : build-env? task? -> (listof path-string)
;; The task's resolvable output paths (unresolvable outputs drop out).
(define (env-output-paths env t)
  (filter values (map (lambda (o) (env-resolve env o)) (task-outputs t))))

;; check-output-paths-resolvable : graph (listof symbol) build-env? -> void
;; Guard (st-6qc): every 'file or 'dir output produced by a task in `tasks' must
;; resolve to a path under `env'. A #f path for such an output is a modeling gap —
;; it silently drops out of env-output-paths, so the artifact is never checked for
;; presence nor hashed for cutoff, and the task can "succeed"/cache without its
;; output verified. Tokens, db-relations, and externals have no single path and are
;; exempt. Raise (naming task → artifact) instead of letting the gap pass quietly.
(define (check-output-paths-resolvable g tasks env)
  (define offenders
    (for*/list ([name (in-list tasks)]
                [t (in-value (hash-ref (graph-tasks g) name))]
                [o (in-list (task-outputs t))]
                #:when (let ([a (hash-ref (graph-artifacts g) o #f)])
                         (and a (memq (artifact-kind a) '(file dir))
                              (not (env-resolve env o)))))
      (format "  ~a → ~a" name o)))
  (unless (null? offenders)
    (error 'stelis
           (string-append
            "unresolvable file/dir output(s) — the path resolver returns #f, so they "
            "would be built but never verified. Add them to the resolver:\n"
            (string-join offenders "\n")))))

;; input-snapshot : graph symbol (symbol -> (or/c path-string #f))
;;                  [(or/c (symbol -> (or/c string #f)) #f)]
;;                  [(or/c (symbol -> (or/c (listof (cons string string)) #f)) #f)]
;;                  [(or/c (hash symbol -> runtime) #f)]
;;                  [(or/c path-string #f)]
;;                  -> (or/c snapshot? decision?)
;; Hash the task's recipe and each input's content. Each input is hashed by its
;; artifact KIND: a keyed 'file store by the roll-up of its per-key digests
;; (`resolve-store-keys', st-2k9 — see the build-env slot for why bytes are wrong
;; under WAL); any other file by its bytes; a db-relation by `resolve-relation'
;; (its DuckDB digest, st-d5d); a gate token by its producer's recorded input
;; address (`token-address', st-ysf — needs `cache-dir'); externals have no
;; content hash. The recipe's CODE files (st-top) are hashed alongside, each by
;; its bytes; a runtime that declares an identity probe contributes its RESOLVED
;; interpreter version there too, keyed "runtime:<name>" (st-jkl — see
;; `runtime-identity-pair' below).
;; 'code-kind INPUTS (st-whi — shared helpers promoted to graph artifacts) are
;; the reason-layer partition: expanded to their full import closure
;; (code-closure over the artifacts' `imports' edges) and hashed onto the CODE
;; side of the snapshot, keyed by resolved path exactly like the recipe's named
;; scripts — so a helper edit still reports 'code-changed naming the file, as it
;; did when the closure was flattened into recipe-code, while data inputs keep
;; reporting 'input-changed.
;; Returns a 'run decision instead of a snapshot when the task can never be
;; content-skipped: 'boundary tasks (ingestion must re-run), and tasks with an
;; input that isn't content-addressable here ('inputs-unresolvable) — including a
;; named code file missing on disk (conservative: unreadable code forces a run;
;; a 'code artifact with no resolved path is named by its artifact symbol, one
;; whose file is absent by its path) and a declared runtime-identity probe that
;; answered #f — no resolver injected, or the interpreter would not launch
;; (named "runtime:<name>"; the task then fails at exec where it always did,
;; instead of silently skipping on a host that cannot run it). A code entry
;; declared `optional-code'
;; (st-e4y) is the exception: its absence addresses to ABSENT-ADDRESS rather than
;; #f, so it never reaches this list.
;; With resolve-relation #f, db-relations fall through to unresolvable (pre-st-d5d).
(define (input-snapshot g name resolve [resolve-relation #f] [resolve-store-keys #f]
                        [runtimes #f] [cache-dir #f] [resolve-dir-exclusions #f]
                        [resolve-runtime-identity #f])
  (define t (hash-ref (graph-tasks g) name))
  (cond
    [(eq? (task-kind t) 'boundary) (decision 'run 'boundary '())]
    [else
     (define inv (task-invoke t))
     (define-values (code-inputs data-inputs)
       (partition (lambda (in)
                    (let ([a (hash-ref (graph-artifacts g) in #f)])
                      (and a (eq? 'code (artifact-kind a)))))
                  (task-inputs t)))
     (define pairs
       (for/list ([in (in-list data-inputs)])
         (cons in (input-hash g in resolve resolve-relation resolve-store-keys
                              cache-dir resolve-dir-exclusions))))
     ;; each closure member -> (path . hash); a #f hash carries what to NAME —
     ;; the artifact symbol (no path) or the path string (file absent).
     (define code-input-pairs
       (for/list ([in (in-list (code-closure g code-inputs))])
         (define p (resolve in))
         (cond
           [(not p)          (cons in #f)]
           [(file-exists? p) (cons (~a p) (file-sha1 p))]
           [else             (cons (~a p) #f)])))
     ;; The runtime's RESOLVED interpreter, for a recipe whose runtime declares an
     ;; identity probe (st-jkl). The pin file (.nvmrc) is hashed as ordinary code
     ;; and states INTENT; this pair states REALITY — the two diverge exactly when
     ;; the pin lies (a patch release inside the range, a host whose launch falls
     ;; back with a warning). Rides the CODE side so drift reports 'code-changed
     ;; naming "runtime:<name>", and the value is the probe's own output rather
     ;; than a hash of it (the ABSENT-ADDRESS argument: a version string cannot
     ;; collide with 40-hex sha1s, and history showing `v24.18.1' directly is the
     ;; legibility the probe exists for). A #f — probe failed, or no resolver
     ;; injected — lands in missing-code below: conservative, the task runs.
     (define runtime-identity-pair
       (let ([rt (and (recipe? inv) runtimes
                      (hash-ref runtimes (recipe-runtime inv) #f))])
         (and rt (runtime-identity rt)
              (cons (format "runtime:~a" (recipe-runtime inv))
                    (and resolve-runtime-identity
                         (resolve-runtime-identity (recipe-runtime inv)))))))
     (define code-pairs
       (append (if runtime-identity-pair (list runtime-identity-pair) '())
               (append* (for/list ([p (in-list (invoke-code inv))])
                          (code-path-hashes p)))
               (filter cdr code-input-pairs)))
     (define unresolvable
       (sort (append (for/list ([kv (in-list pairs)] #:unless (cdr kv)) (car kv))
                     (for/list ([kv (in-list code-input-pairs)]
                                #:when (and (not (cdr kv)) (symbol? (car kv))))
                       (car kv)))
             symbol<?))
     (define missing-code
       (sort (append (for/list ([kv (in-list code-pairs)] #:unless (cdr kv)) (car kv))
                     (for/list ([kv (in-list code-input-pairs)]
                                #:when (and (not (cdr kv)) (string? (car kv))))
                       (car kv)))
             string<?))
     (if (or (pair? unresolvable) (pair? missing-code))
         (decision 'run 'inputs-unresolvable (append unresolvable missing-code))
         (snapshot (string-sha1 (invoke-basis inv runtimes))
                   (make-immutable-hash pairs)
                   (make-immutable-hash code-pairs)))]))

;; The content address of a declared-OPTIONAL code entry that isn't there
;; (st-e4y). Deliberately not a hash of anything: it can't collide with a real
;; sha1 (40 hex chars), and it must not read as "an empty file" either — absent
;; and zero-byte are different observations. Stable across builds and machines,
;; which is the whole point: absence is a value the cache can compare, so a task
;; whose optional inputs stay absent skips, and one appearing or disappearing is
;; an ordinary 'code-changed naming the path.
(define ABSENT-ADDRESS "absent")

;; code-path-hashes : code-entry -> (listof (cons string (or/c string #f)))
;; One recipe-code entry's (path -> content-hash) pairs. A FILE hashes by its
;; bytes. A DIRECTORY (st-0ql: dbt's models/, seeds/, …) expands to one pair per
;; file inside — "<dir>/<rel>" -> hash, the same per-file grain tree-hashes gives
;; 'dir artifacts — so 'code-changed names the exact model file, and an added or
;; removed file surfaces as a key change rather than an opaque digest flip. A
;; missing path yields a single #f pair (-> 'inputs-unresolvable, conservative)
;; — UNLESS it was declared `optional-code', in which case its absence is the
;; observation and it addresses to ABSENT-ADDRESS.
(define (code-path-hashes entry)
  (define p (code-entry-path entry))
  (cond
    [(directory-exists? p)
     (for/list ([kv (in-list (tree-hashes p))])
       (cons (string-append (~a p) "/" (car kv)) (cdr kv)))]
    [(file-exists? p) (list (cons (~a p) (file-sha1 p)))]
    [(optional-code? entry) (list (cons (~a p) ABSENT-ADDRESS))]
    [else (list (cons (~a p) #f))]))

;; invoke-basis : any (or/c hash #f) -> string
;; What recipe-hash fingerprints. With a runtimes map that knows the recipe's
;; runtime: the RESOLVED argv — launch prefix included, so a runtime pin change
;; (say, a Python bump in beeatlas-runtimes) invalidates like an args change
;; (st-top's "runtime identity"). Otherwise the raw invoke value, as before.
;; Code file CONTENTS ride separately in snapshot-code-hashes; the code path
;; LIST is visible there too (as keys), so membership changes are always caught.
;;
;; A `derivation' (st-ozp) is fingerprinted by its LABEL and code paths, never by
;; the raw struct: its `run' slot holds a PROCEDURE, and a procedure's printed
;; form is an implementation detail — anything address- or gensym-flavoured in it
;; would read as "recipe-changed" on every build and defeat caching entirely.
;; What the procedure DOES is covered properly, by hashing its source (code-hashes).
(define (invoke-basis inv runtimes)
  (cond
    [(and (recipe? inv) runtimes (hash-ref runtimes (recipe-runtime inv) #f))
     (~s (recipe->argv inv runtimes))]
    [(derivation? inv)
     (~s (list 'derivation (derivation-label inv)
               (for/list ([e (in-list (derivation-code inv))]) (~a (code-entry-path e)))))]
    [else (~s inv)]))

;; input-hash : graph symbol (symbol -> path?) (or/c (symbol -> string?) #f)
;;              (or/c (symbol -> (or/c (listof (cons string string)) #f)) #f)
;;              (or/c path-string #f)
;;              -> (or/c string #f)
;; One input's content hash, by artifact kind, or #f if not content-addressable:
;; a keyed 'file store by the CID of its per-key digests as a block (the same
;; boundary read the observation layer records — decision and delta can never
;; disagree); any other file by its bytes; a dir by its order-independent tree
;; digest (st-cly); a db-relation by `resolve-relation'; a gate token by
;; `token-address' (st-ysf). #f (absent/unresolvable) forces a rerun — a keyed
;; store whose scan fails falls back to file bytes, and an absent file to #f, so
;; unreadable stays conservative.
(define (input-hash g in resolve resolve-relation resolve-store-keys cache-dir
                    [resolve-dir-exclusions #f])
  (define a (hash-ref (graph-artifacts g) in #f))
  (cond
    [(and a (eq? (artifact-kind a) 'db-relation))
     (and resolve-relation (resolve-relation in))]
    [(and a (eq? (artifact-kind a) 'dir))
     (define p (resolve in))
     (and p (tree-digest p #:exclude (if resolve-dir-exclusions
                                         (resolve-dir-exclusions in)
                                         '())))]
    [(and a (eq? (artifact-kind a) 'token))
     (and cache-dir (token-address g in cache-dir))]
    [else
     (define keys (and resolve-store-keys (resolve-store-keys in)))
     (cond
       [keys (keyed-block-digest keys)]
       [else
        (define p (resolve in))
        (and p (file-exists? p) (file-sha1 p))])]))

;; token-address : graph symbol path-string -> (or/c string #f)
;; A gate TOKEN's content address (st-ysf): the digest of what its producer's
;; last PASSING run was a verdict ABOUT — the recipe identity, input hashes, and
;; code hashes recorded in the producer's cache entry. A passing gate whose own
;; input address is unchanged vouches exactly what it vouched before (the same
;; argument that lets a gate cache-skip its evaluation, st-0vz), so its token
;; reads unchanged and a consumer (dbt-build) may skip; anything that moves the
;; gate — upstream data, its rule/code, its runtime pin — moves the token.
;; Entries are written only on a PASS, and run-plan blocks a failing gate's
;; consumers before their decision matters, so "the entry" is always "the last
;; pass". #f — no producer, no entry, or an entry without a snapshot (the gate's
;; own inputs weren't addressable) — keeps the consumer conservative
;; ('inputs-unresolvable): an unaddressed verdict propagates, never launders.
(define (token-address g in cache-dir)
  (define p (producer-of g in))
  (define e (and p (read-cache-entry cache-dir p)))
  (and e (hash-ref e 'recipe-hash #f)
       (string-sha1 (~s (list (hash-ref e 'recipe-hash)
                              (hash-ref e 'input-hashes '())
                              (hash-ref e 'code-hashes '()))))))

;; output-snapshot+keys : graph symbol build-env?
;;   -> (values (listof (cons symbol string))                        ; digests
;;              (listof (cons symbol (listof (cons string string))))) ; per-'dir keys
;; The task's cutoff-eligible outputs, hashed after a run, at two granularities in
;; ONE walk. First value: each DERIVED artifact that resolves to existing content,
;; as a sorted (artifact -> digest) alist — the cutoff/observation basis. Second
;; value: for each 'dir output, its sorted (relative-path -> hash) pairs — the
;; per-KEY observations (st-6dv). A 'dir's digest is the roll-up of exactly those
;; pairs — the digest IS their block's CID (st-1e5), so the two granularities
;; cannot disagree by construction rather than by assertion; a 'file
;; has a digest but no keys, and tokens/relations have no path and drop out.
;; Cutoff applies to 'derived state ONLY — the filter is an allow-list, so every
;; other provenance is excluded (forward-only writes are effects; "rebuilt to
;; identical bytes" isn't a claim we make about them). In practice 'derived is the
;; only provenance that can reach here at all: check-graph-leaves refuses to let an
;; 'authoritative or 'upstream artifact have a producer, so neither ever appears in
;; task-outputs. The allow-list is the belt to that suspenders.
(define (output-snapshot+keys g name env)
  (define t (hash-ref (graph-tasks g) name))
  (define observed
    (for*/list ([out (in-list (task-outputs t))]
                [a (in-value (hash-ref (graph-artifacts g) out #f))]
                #:when (and a (eq? 'derived (artifact-provenance a)))
                [obs (in-value (observe-output a out env))]
                #:when obs)
      (list out (car obs) (cdr obs))))
  (values
   (sort (for/list ([o (in-list observed)]) (cons (car o) (cadr o)))
         symbol<? #:key car)
   (sort (for/list ([o (in-list observed)] #:when (caddr o)) (cons (car o) (caddr o)))
         symbol<? #:key car)))

;; artifact-key-parts : symbol symbol build-env? -> (or/c (listof (cons string string)) #f)
;; The ONE kind -> per-key-layer dispatch (st-lg0): an artifact's live per-key
;; (part -> value) map, or #f when it has none / can't be read. Every reader — the
;; live delta side (delta-explain live-key-map), the recorded output observation
;; (observe-output), the boundary input snapshot (input-store-snapshot) — goes
;; through here, so a new keyed kind is added in exactly one place.
;;   'dir         (path -> content-hash)     via tree-hashes
;;   'db-relation (column -> "digest:count") via resolve-relation-columns
;;   'file        (key -> "digest:count")    via resolve-store-keys — a keyed store;
;;                #f for a plain file (no per-key layer)
;;   else (token/external) -> #f
(define (artifact-key-parts a kind env)
  (case kind
    [(dir) (let ([p (env-resolve env a)])
             (and p (tree-hashes p #:exclude (env-dir-exclusions env a))))]
    [(db-relation) (let ([rrc (build-env-resolve-relation-columns env)]) (and rrc (rrc a)))]
    [(file) (let ([rsk (build-env-resolve-store-keys env)]) (and rsk (rsk a)))]
    [else #f]))

;; observe-output : artifact symbol build-env?
;;   -> (or/c (cons string (or/c (listof (cons string string)) #f)) #f)
;; One derived output's observation: (digest . parts), or #f when there's nothing
;; to hash. The PARTS come from the shared artifact-key-parts; the DIGEST stays
;; kind-specific here because it is NOT always a roll-up of the parts:
;;   'dir         the CID of its parts as a keyed block — the parts' ADDRESS
;;   'db-relation the row-coherent resolve-relation digest — per-column parts alone
;;                CANNOT reconstruct it (a cross-row value swap, st-d5d); taken here
;;                AFTER the producer released the db lock
;;   'file        the bytes hash (a plain file has no parts)
;;   else (token/external) -> #f
(define (observe-output a out env)
  (define parts (artifact-key-parts out (artifact-kind a) env))
  (case (artifact-kind a)
    [(dir) (and parts (cons (keyed-block-digest parts) parts))]
    [(db-relation)
     (define rr (build-env-resolve-relation env))
     (define h (and rr (rr out)))
     (and h (cons h parts))]
    [else
     (define p (env-resolve env out))
     (and p (file-exists? p) (cons (file-sha1 p) parts))]))

;; input-store-snapshot : graph symbol build-env?
;;   -> (listof (cons symbol (listof (cons string string))))
;; The ingestion-boundary CRUD-snapshot (st-2k9): each PRODUCERLESS keyed leaf the
;; task consumes, as (artifact -> its per-key map), sorted. Such a leaf (the notes
;; store — an authoritative 'file keyed by canonical_name) is observed by nobody
;; else: a 'dir/db-relation input is recorded by its PRODUCER as an output, so we
;; skip anything with a producer to avoid double-observing. Parts come from the
;; shared artifact-key-parts (st-lg0), so this covers any future producerless keyed
;; kind, not just stores; '() when nothing qualifies.
(define (input-store-snapshot g name env)
  (define t (hash-ref (graph-tasks g) name))
  (sort (for*/list ([in (in-list (task-inputs t))]
                    #:unless (producer-of g in)
                    [a (in-value (hash-ref (graph-artifacts g) in #f))]
                    [parts (in-value (and a (artifact-key-parts in (artifact-kind a) env)))]
                    #:when parts)
          (cons in parts))
        symbol<? #:key car))

;; output-snapshot : graph symbol build-env? -> (listof (cons symbol string))
;; The artifact-level digests alone — the cutoff basis and cache entry (role
;; UNCHANGED by st-6dv). The per-key layer rides only on the trace/history.
(define (output-snapshot g name env)
  (define-values (digests _keys) (output-snapshot+keys g name env))
  digests)

;; compare-outputs : (or/c hash? #f) (listof (cons symbol string))
;;                   -> (or/c output-delta? #f)
;; The pure cutoff question: given the previous cache entry and a fresh
;; output-snapshot, did the rerun rebuild to identical content? #f when there
;; is no basis to compare — no prior entry, or nothing hashable this run.
(define (compare-outputs entry fresh)
  (and entry (pair? fresh)
       (let ([changed (changed-names
                       (make-immutable-hash (hash-ref entry 'output-hashes '()))
                       (make-immutable-hash fresh))])
         (if (null? changed)
             (output-delta 'identical (map car fresh))
             (output-delta 'changed changed)))))

;; --- The cache sidecar ----------------------------------------------------------

(define (cache-file cache-dir name)
  (build-path cache-dir (format "~a.rktd" name)))

;; read-versioned : path-string exact-integer -> (or/c hash? #f)
;; The shared shape for versioned state files (cache sidecars, the build
;; trace): #f for missing, unparseable, or other-version — never an error.
(define (read-versioned f version)
  (and (file-exists? f)
       (let ([e (with-handlers ([exn:fail? (lambda (_) #f)])
                  (call-with-input-file f read))])
         (and (hash? e) (equal? (hash-ref e 'version #f) version) e))))

;; read-cache-entry : path-string symbol -> (or/c hash? #f)
(define (read-cache-entry cache-dir name)
  (read-versioned (cache-file cache-dir name) CACHE-VERSION))

;; cache-store! : path-string symbol (or/c snapshot? #f) (listof path-string)
;;                (listof (cons symbol string)) -> void
;; With snap = #f (a boundary task, or inputs that aren't content-addressable,
;; e.g. dbt-build's relations) the entry still records the output hashes, so
;; the NEXT rerun has a cutoff basis; the absent recipe/input hashes can never
;; produce a skip — `decide' is only ever reached when a snapshot exists.
(define (cache-store! cache-dir name snap output-paths out-hashes)
  (make-directory* cache-dir)
  (call-with-output-file (cache-file cache-dir name) #:exists 'replace
    (lambda (o)
      (write (hash 'version CACHE-VERSION
                   'recipe-hash (and snap (snapshot-recipe-hash snap))
                   ;; sorted alist, not a hash: same state -> same file bytes
                   'input-hashes (if snap
                                     (sort (hash->list (snapshot-input-hashes snap))
                                           symbol<? #:key car)
                                     '())
                   'code-hashes (if snap
                                    (sort (hash->list (snapshot-code-hashes snap))
                                          string<? #:key car)
                                    '())
                   'outputs (map (lambda (p) (if (path? p) (path->string p) p))
                                 output-paths)
                   'output-hashes out-hashes) ; output-snapshot: already sorted
             o))))

;; --- The decision core ----------------------------------------------------------

;; decide : snapshot? (or/c hash? #f) (listof path-string) [(listof symbol)]
;;          -> decision?
;; The pure core: compare a fresh snapshot against the recorded entry (#f = no
;; usable entry), given which recorded outputs are missing on disk (`missing-outputs`)
;; and which recorded outputs still exist but no longer match what this task last
;; produced (`stale-outputs`: db-relations st-84u, files/dirs st-zh2). The
;; first applicable reason wins; the output reasons
;; are checked after the content reasons so a content change is always reported as
;; the content change.
(define (decide snap entry missing-outputs [stale-outputs '()])
  (cond
    [(not entry) (decision 'run 'no-cache-entry '())]
    [else
     ;; the task's CODE (st-top): named script files, compared per file so the
     ;; decision can say WHICH script changed. Checked before the recipe hash
     ;; AND the data inputs: when a script moved along with either, naming the
     ;; file is the sharper report (the incident class is a script edit).
     (define changed-code
       (changed-names (make-immutable-hash (hash-ref entry 'code-hashes '()))
                      (snapshot-code-hashes snap)
                      string<?))
     (define changed
       (changed-names (make-immutable-hash (hash-ref entry 'input-hashes '()))
                      (snapshot-input-hashes snap)))
     (cond
       [(pair? changed-code)     (decision 'run 'code-changed changed-code)]
       [(not (equal? (hash-ref entry 'recipe-hash #f) (snapshot-recipe-hash snap)))
        (decision 'run 'recipe-changed '())]
       [(pair? changed)          (decision 'run 'input-changed changed)]
       [(pair? missing-outputs)  (decision 'run 'output-missing missing-outputs)]
       ;; an output that still EXISTS but is no longer what this task produced: a
       ;; db-relation whose table was swapped out from under a content-addressed skip
       ;; (st-84u), or a file/dir something outside the graph rewrote (st-zh2). Rerun
       ;; to re-materialise it — otherwise a downstream read silently gets the wrong
       ;; content, having been told the input was unchanged.
       [(pair? stale-outputs)    (decision 'run 'output-stale stale-outputs)]
       [else                     (decision 'skip 'cached '())])]))

;; stale-relation-outputs : graph symbol build-env? (or/c hash? #f) -> (listof symbol)
;; A task's db-relation OUTPUTS whose CURRENT digest (the table now in the DuckDB at
;; DB_PATH) differs from the digest this task recorded last build — i.e. the table is
;; missing or was mutated since (a fresh S3 pull swaps the whole db each nightly).
;; The ordinary missing-output check can't see these: a db-relation has no path, so
;; it never appears in env-output-paths (st-84u). '() with no relation resolver, no
;; entry, or no db-relation outputs.
(define (stale-relation-outputs g name env entry)
  (define rr (build-env-resolve-relation env))
  (cond
    [(not (and rr entry)) '()]
    [else
     (define recorded (make-immutable-hash (hash-ref entry 'output-hashes '())))
     (for/list ([out (in-list (task-outputs (hash-ref (graph-tasks g) name)))]
                #:when (let ([a (hash-ref (graph-artifacts g) out #f)])
                         (and a (eq? 'db-relation (artifact-kind a))))
                #:unless (equal? (rr out) (hash-ref recorded out #f)))
       out)]))

;; stale-disk-outputs : graph symbol build-env? (or/c hash? #f) -> (listof symbol)
;; A task's 'file and 'dir OUTPUTS whose content on disk no longer matches the digest
;; this task recorded producing (st-zh2) — the on-disk twin of stale-relation-outputs.
;;
;; Until this existed the cache asked only whether a recorded output still EXISTED, so
;; an output that was still there but no longer ours read as a clean skip forever. That
;; is not hypothetical: beeatlas's topology_postprocess used to rewrite the region marts
;; place-marts had just produced, in place, and place-marts went on reporting 'cached
;; against a file it did not write (beeatlas-hyq). One-producer-per-artifact removed
;; that particular cause; nothing inside the graph can rule out the general one, because
;; the mutation comes from OUTSIDE the graph — a stray script, a restored backup, a
;; human with a text editor.
;;
;; Same conservative reading as st-84u on a missing recorded digest: no basis means
;; rerun, not "assume fine". Cheap in practice — 'file outputs are a sha1 of bytes we
;; already hash as INPUTS elsewhere in the same pass, and a 'dir is the tree-hash that
;; its own digest is made of. Measured across beeatlas's whole 40-task graph on the
;; serving host: ~1.6s, against ~6.5s that stale-relation-outputs was already spending
;; on DuckDB digests in the very same eager position.
(define (stale-disk-outputs g name env entry)
  (cond
    [(not entry) '()]
    [else
     (define recorded (make-immutable-hash (hash-ref entry 'output-hashes '())))
     (for/list ([out (in-list (task-outputs (hash-ref (graph-tasks g) name)))]
                #:do [(define a (hash-ref (graph-artifacts g) out #f))]
                #:when (and a (memq (artifact-kind a) '(file dir))
                            ;; DERIVED only, exactly as output-snapshot+keys filters
                            ;; (an allow-list, so any other provenance is excluded).
                            ;; A non-derived output is never recorded, so comparing it
                            ;; against a recorded digest would find #f every time and
                            ;; rerun forever — and "it changed since we wrote it" is
                            ;; not a defect for forward-only state, it is the point.
                            (eq? 'derived (artifact-provenance a)))
                ;; #f = absent or unresolvable; 'output-missing owns that report and is
                ;; checked first, so naming it here too would only muddy the reason.
                #:do [(define now (observe-output a out env))]
                #:when now
                #:unless (equal? (car now) (hash-ref recorded out #f)))
       out)]))

;; names whose hash differs between the two maps, or that exist in only one.
;; Keys are artifact symbols by default; code maps pass string<? (path keys).
(define (changed-names old new [<? symbol<?])
  (sort (for/list ([name (in-set (set-union (list->set (hash-keys old))
                                            (list->set (hash-keys new))))]
                   #:unless (equal? (hash-ref old name #f) (hash-ref new name #f)))
          name)
        <?))

;; decision+snapshot : graph symbol build-env?
;;                     -> (values decision? (or/c snapshot? #f))
;; The full question, IO included: would `name' run right now, and why? Also
;; returns the snapshot (when one exists) so an executor that goes on to run
;; the task can store it without re-hashing.
(define (decision+snapshot g name env)
  (define t (hash-ref (graph-tasks g) name))
  (define snap (input-snapshot g name (lambda (a) (env-resolve env a))
                               (build-env-resolve-relation env)
                               (build-env-resolve-store-keys env)
                               (build-env-runtimes env)
                               (build-env-cache-dir env)
                               (lambda (a) (env-dir-exclusions env a))
                               (build-env-resolve-runtime-identity env)))
  (if (decision? snap)
      (values snap #f)
      (let ([entry (read-cache-entry (build-env-cache-dir env) name)])
        (values (decide snap entry
                        (missing (env-output-paths env t))
                        ;; both kinds of "still there, but no longer what we made"
                        ;; feed the one 'output-stale arm (st-84u + st-zh2)
                        (sort (append (stale-relation-outputs g name env entry)
                                      (stale-disk-outputs g name env entry))
                              symbol<?))
                snap))))

;; task-decision : graph symbol build-env? -> decision?
(define (task-decision g name env)
  (define-values (d _snap) (decision+snapshot g name env))
  d)

;; cache-hit? : path-string symbol snapshot? (listof path-string) -> boolean
;; Thin wrapper over `decide' for callers that only need the verdict.
(define (cache-hit? cache-dir name snap output-paths)
  (eq? 'skip (decision-verdict
              (decide snap (read-cache-entry cache-dir name) (missing output-paths)))))

;; a recorded output is present if it exists as a file OR a directory ('dir
;; outputs, st-cly, resolve to a directory that file-exists? would miss).
(define (missing output-paths)
  (for/list ([p (in-list output-paths)]
             #:unless (or (file-exists? p) (directory-exists? p)))
    p))
