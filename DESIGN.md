# Stelis — Design

## What this is

Stelis is a build system whose rules are modeled in Datalog, built on Racket. Its
job is to know what must be rebuilt given any particular change. The near-term
goal is to wrap — and eventually replace — the patchwork of imperative build
steps (dlt, dbt, 11ty, vite, and custom scripts) that power the `beeatlas` and
`salishsea` pipelines. The longer arc is a single system that handles both batch
rebuilds and the near-real-time incorporation of incoming data into published
artifacts.

Stelis is the tool. `beeatlas` and `salishsea` are the case studies and test
beds — they exist to keep the work value-driven and honest, not to be revamped
for their own sake.

## Origin and intent

Greenfield project. Its purposes, in the order they matter:

1. **Solve real problems** in existing projects — starting with
   [`beeatlas`](https://github.com/rainhead/beeatlas) (`~/dev/beeatlas`) and
   [`salishsea-io`](https://github.com/salish-sea/salishsea-io)
   (`~/dev/salishsea-io`).
2. **Learn** Racket (and eventually Rhombus), and learn to model real problems in
   Datalog, by building something real rather than by study alone.
3. **Explore the substrate vision** — the longer-term declarative computing
   environment — grounded at every step in one of the concrete scenarios above.

**A deliberate, eyes-open choice.** The more sensible starting point would be to
model targeted projections of the datasets to power specific features. The chosen
starting point — modeling the *build process itself* — is less obviously sensible
but more satisfying and more general: the aim is to wrap (and perhaps eventually
replace) a patchwork of imperative build steps with something that knows what
needs rebuilding given any change, and to push that far enough that the same
system can incorporate incoming API data into artifacts in near real time. This
is recorded as a conscious trade of "sensible" for "satisfying and general," with
the value-first discipline below as the guardrail against it becoming
substrate-for-its-own-sake.

**Working mode.** Development is interactive and didactic — deliberate about what
functionality is taken on in what order, since the design space is large and open
and the project's known failure mode is getting lost in it.

**Philosophical alignment.** Closest in spirit to Nix (hermetic, content-addressed,
pure derivations) and to cloud/remote build systems (Buck2/Bazel-shaped incremental
graphs). See "The frame" for how those map onto the à la Carte axes.

## The frame

Three layers, built iteratively:

1. **Computational substrate** — anything that requires going beyond what the
   host language offers directly: derivation, content-addressing, incremental
   maintenance, provenance.
2. **Useful features for communities collaborating through data.**
3. **Tools, patterns, and libraries** for building those features on the
   substrate.

**Value-first ordering.** Real value derived by the community (including its
tool-builders) drives the sequence. The other two layers have their own internal
criteria, but when they conflict with delivering value, value wins. This is the
standing corrective to the project's known failure mode (getting absorbed in the
substrate before anything works for a real user — the inner-platform effect).

**Map.** The design is informed by *Build Systems à la Carte* (2018), which
factors build systems along two axes: **scheduling** (topological / restarting /
suspending) and **rebuilding** (dirty-bit / verifying-trace / constructive-trace).
Most design questions reduce to a choice on these two axes.

**The target corner.** Stelis aims at a combination no single existing system
occupies: a **Datalog logic layer** plus **log-structured, provenance-as-value
persistence**, sitting on top of a **demand-driven incremental core** (of the
kind Buck2's DICE engine demonstrates). Buck2/DICE shows the incremental core is
achievable; DBSP/Z-sets shows retraction-clean incremental maintenance is
achievable; neither supplies the logic layer or the history model. That gap is
what Stelis builds.

## Settled commitments (with reasons)

Each of these is decided. The reason is recorded so it isn't relitigated.

- **Hermetic.** Behavior must not depend on ambient machine state. Every
  reproducibility failure in the pipelines (which Python, which dbt, which stale
  copy) traces to a hermeticity gap. This is the north star the rest serve.
- **Content-addressed, not timestamped.** Change is measured by the hash of
  content, not mtime. Datasets are modeled functionally as transformations over
  other datasets, versioned by hash; this refines down toward records as
  functions of records and attributes as functions of attributes, landing at a
  conventional Datalog domain model.
- **Effects at the boundary.** The derivation core is pure. IO, external API
  ingestion, secrets, and rendering live at declared edges as first-class node
  types — not scattered through the core. Ingestion sits *outside* the hermetic
  boundary and emits content-addressed immutable snapshot leaves.
- **Delta-based change model** (not in-place mutation). Change is a first-class
  value that flows through the graph. This is the model coherent with
  log-structured persistence and provenance-as-value; it is expensive to
  retrofit, so it is chosen now even though early phases won't exploit it.
- **Bottom-up evaluation first**, with demand-direction (magic sets) added only
  when goal-directedness is actually needed. Keeps the Datalog rules native and
  provenance tractable.
- **Provenance is first-class.** Every derived fact should be explicable in terms
  of the base facts and rules that produced it. Not necessarily implemented
  early, but never designed out.
- **Datalog layer stays thin and compilable.** Lesson from DDlog's abandonment
  of its Datalog frontend: don't build a fat surface; keep the logic layer
  compilable onto whatever engine sits below (including, later, an external one).
- **Racket core; engine server-side.** Racket is chosen for its language-workbench
  strength (embedding Datalog via macros) and its mature C FFI (tree-sitter,
  SQLite, DuckDB, hashing all bindable). The engine runs server-side.
- **The browser is reached by emission, not execution.** Where a browser artifact
  is needed, Racket *compiles* a small targeted program (e.g. TS) as a derived,
  content-addressed node in the build graph — rather than running the engine
  itself in the browser. This is partial evaluation / the first Futamura
  projection, and it is what Racket is genuinely best at.
- **Derived vs. authoritative outputs are distinct node types.** Some outputs are
  pure functions of inputs (safe to destroy and rebuild); others are forward-only
  authoritative state that must never be rebuilt from scratch (migrations only).
  The caching model must express both.
- **State in memory now; a database later.** Persistence is deferred, but the
  trace/graph representation is designed so it can be persisted without rework.

## Deferred, with reasons

Deferral is a decision, and the reason protects the staging discipline.

- **Non-linear time (branching, grafting, distribution).** The hardest problem,
  and cleanly separable: everything Stelis needs early lives in linear, local,
  single-repo time (a total order on versions). Branch/merge is where the
  high-water-mark reasoning that suffices in linear time breaks down. Start with
  closed, immutable datasets and linear time.
- **Fine-grained (tuple/attribute-level) incrementality.** Coarse-grained
  over-rebuilding is acceptable to start. Buy back finer granularity (Z-sets /
  DBSP-shaped propagation) only when coarse over-rebuilding actually hurts.
- **Incremental parsing at the file/value boundary** (tree-sitter-shaped). The
  boundary crossing where granularity and effect-visibility change together;
  hard, and only relevant once fine-grained incrementality matters. FFI viability
  confirmed (a Racket tree-sitter binding exists).
- **Compile-to-Rust for performance.** At the scale that would justify it, calling
  Feldera/DBSP beats hand-emitting Rust. Hold loosely; reach for it only for a hot
  path that both matters and doesn't fit Feldera.
- **ASP (answer-set programming).** Datalog's unique-model semantics are the right
  fit for derivation and provenance. ASP's search-over-possible-worlds is only
  warranted for genuine search/repair problems (e.g. "minimal corrections to make
  a dataset valid"). Collect the friction points (disjunction in rule heads) that
  would motivate it; don't extend the system preemptively.
- **The review / staleness workflow layer** (human/LLM review nodes, "suspect"
  propagation, doc-depends-on-source edges). Assemblable from the effect-boundary
  discipline plus version-stamping, and tractable in linear time — but not phase 1.
- **WASM in-browser engine execution.** Desirable someday; the tripwire that would
  force reconsidering the platform choice. Not a concern now.
- **Rhombus surface syntax.** The core is implemented in Racket. Individual modules
  can migrate to Rhombus later if desired; the language core stays in Racket, where
  the macrology support is deepest.

## Phase 1 — sharply bounded

**Does:** A Racket build system that models the `beeatlas` batch pipeline as a
dependency graph, using Datalog as a *metadata* language about the build
(dependencies, versions, staleness). Transformations stay external (existing
dlt / dbt / exporters, invoked as tasks). Delivers the core build-system value the
current `run.py` lacks: name a target, run the minimal upstream, skip what's
already current.

Includes:
- Target selection + up-to-date skipping (the immediate need was *only*
  `occurrences.db`; today the only build is "run everything").
- Input-addressed task caching, with the derived-vs-authoritative escape hatch.
- Per-task hermetic runtime invocation (the dual-interpreter case: 3.14 for dlt
  loaders, 3.13 for dbt).
- Gates/assertions as first-class, cacheable, skippable graph nodes.
- Explicit output destinations (no hidden copies) and partial success (a failed
  target must not fail unrelated already-satisfied targets).
- Streaming, per-task observability by default.
- A determinism-testing harness: build the same snapshot twice, compare hashes.
  DuckDB parallelism, floating point, and spatial joins make this a day-one task,
  not a someday one.

**Does not:** incremental rebuild, streaming/CRUD ingestion, persistence beyond
memory, data-quality Datalog rules, compile-to-TS, `salishsea`'s streaming model,
or anything in the Deferred list.

**Done when:** naming `occurrences.db` builds the minimal upstream, skips current
work, and `run.py`'s hand-sequenced list is retired for that build — reproducibly,
verified by the determinism harness.
