# ADR 0001 — The build-graph model (slice 1)

**Status:** accepted · **Horizon:** 0 · **Date:** 2026-07-10

Decides how Stelis models the beeatlas batch build as an explicit dependency
graph — the representation the first working slice is built on. Arrived at by
grilling the design before writing any Racket; each decision records its reason so
it isn't relitigated (per `CLAUDE.md`).

## Context

beeatlas's build is `data/run.py`: a 33-step hand-ordered list of Python
callables (`STEPS`). The list encodes *order*, but the dependency *edges* live
only in prose comments ("runs AFTER collectors-export because…"). Nothing can
auto-derive the real graph — a human must read those comments and write the edges
down. That transcription is the value Stelis adds and `run.py` lacks.

Grounding facts (verified in beeatlas):
- `occurrences.db`'s only inputs are `dbt/target/sandbox/occurrences.parquet`
  (from `dbt-build`) and `raw/taxa.csv.gz` (from `taxa-download`). Its true
  upstream is a **strict subset** of the 33 steps; ~15 siblings
  (`species-maps`, `places-maps`, `collectors-export`, `feeds`, …) are not
  upstream of it at all.
- Steps are **not 1:1 with artifacts**: `dbt-build` produces six parquets;
  gates produce nothing.
- The dlt loaders write **into one shared, mutable, ~1.2 GB `beeatlas.duckdb`**
  (schemas like `ecdysis_data`), not files. dbt reads from it and writes
  parquets.

## Decisions

1. **Bipartite graph.** Two node kinds: **task** nodes (consume artifacts,
   produce artifacts; external and opaque — we orchestrate, never reimplement)
   and **artifact** nodes (logical datasets). *Why:* it's the only shape that
   houses transformations-as-functions-over-datasets *and* first-class
   effect/gate/ingestion nodes without contortion, and it preserves per-artifact
   granularity for Horizon 1's early-cutoff rebuild. Chosen even though slice 1
   only prints a plan, because the representation is expensive to retrofit.

2. **Artifact granularity = one dataset per producing task, split only when a
   downstream task consumes the piece rather than the whole.** So `dbt-build` →
   several parquet nodes (consumed separately); each dlt loader → one coarse
   duckdb-schema node. *Why:* makes the plan *true* — `generate-sqlite` depends
   on `occurrences.parquet` specifically, not "all of dbt" — with an objective
   splitting rule. Coarse ingestion is sanctioned by the H0 deferral of
   fine-grained incrementality.

3. **Gates are tasks that produce a pass/fail *token* artifact**; the guarded
   downstream task declares the token as an input. *Why:* keeps the model
   uniform (one graph walk, no special cases) and delivers "first-class,
   cacheable, skippable" gates for free. A correctness gate thus becomes a
   declared input of what it guards (e.g. `generate-sqlite` inputs include
   `dedup-verified`) — the honest encoding of "you may not build the db until
   dedup is checked."

4. **Ingestion = boundary task → opaque, coarse, un-addressed artifact.** Each
   loader is a first-class boundary node; its output is one coarse
   duckdb-schema artifact that Horizon 0 does **not** content-address. *Why:*
   the shared mutable duckdb can't be meaningfully hashed and snapshotting it
   would revamp beeatlas / pull Horizon 2 forward. See "Known deviation."

5. **Identity ≠ version.** A node's **identity** is a stable *authored name*
   (task = its `run.py` step name; artifact = logical dataset name), durable
   across runs and edits — this is what provenance points at. A node's
   **version fingerprint** (content hash for derived; boundary stamp for
   ingestion) is a *separate, computed* attribute. *Why:* provenance needs a
   durable subject; fusing identity with a content hash (Nix-style) would make
   every edit a different node. **Unpopulated in slice 1.**

6. **The graph lives in stelis, authored as Racket-native data** (structs /
   S-expressions, no parser). *Why:* the edges are hand-authored anyway; keeping
   it in stelis avoids revamping the case study; Racket-native suits the
   language-workbench goal and needs no parser. A macro/DSL earns its way in
   only when hand-written data gets painful. Migration to a beeatlas-owned
   manifest is a possible Horizon-1 move.

## Known deviation (recorded, not fixed)

beeatlas's shared mutable `beeatlas.duckdb` violates the settled commitment that
ingestion "emits content-addressed immutable snapshot leaves." Horizon 0 **wraps**
it: an ingestion artifact's version is a *boundary stamp* (ETag / snapshot-id /
pinned), never a hash of the shared file. **Accepted consequence:**
skip-if-current cannot detect a silent change in an ingestion source under the
same stamp — bounded to the ingestion edge. To be closed if/when Horizon 2's
snapshot ingestion lands.

## Slice 1 — what gets built

Two committed steps:
- **1a (plain Racket):** author the graph; compute + **print** `occurrences.db`'s
  minimal upstream in topological order. No execution, no hashing.
- **1b (Datalog):** re-express the reachable-set core as a Datalog reachability
  rule; keep both and cross-check they agree. Realizes the H0 "Datalog as a
  metadata language about the build" commitment; the two implementations become a
  consistency test.

**Scope authored:** the full 33-node set (so pruning is demonstrable), with
**precise** edges for the `occurrences.db` upstream and **coarse-but-honest**
edges for siblings (they exist and stay off the target's paths — no fabricated
upstream links).

**Validation:** for the `occurrences.db` subgraph the computed order must respect
`run.py`'s hand-order, and the plan must drop exactly the expected ~15 siblings.

**Reserved-but-empty slots** (so we don't retrofit): each task node will carry a
"how to invoke" field (slice 2, execution); each artifact its version fingerprint
(slice 4, skip-if-current). Present in the representation, unpopulated now.

## Consequences

- Slice 1 touches no beeatlas code and runs nothing — pure derivation, trivially
  deterministic.
- The model is forward-compatible with execution (slice 2), hermetic runtimes
  (slice 3), skip-if-current (slice 4), and the determinism harness (slice 5)
  without representational rework.
