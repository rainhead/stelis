# CLAUDE.md

Operating instructions for an agent working in this repo. Keep this short. The
*what* and *why* live in `DESIGN.md` and `ROADMAP.md` — this file is for not
making predictable mistakes.

## Orient first

- Read `DESIGN.md` and `ROADMAP.md` before starting work.
- Treat `DESIGN.md`'s **settled commitments as decided** — don't relitigate them;
  raise a flag if one seems wrong, don't quietly work around it.
- Treat `ROADMAP.md`'s **horizons as the scope guard.** **Horizon 1 is delivered**
  (2026-07-16): provenance, the observation history (`.stelis/`, with per-key and
  per-column granularity), early cutoff, data-quality rules-as-nodes + the integrity
  gate, and full target coverage all shipped and verified. **Horizon 2 is next** —
  its natural entry point is **delta propagation (st-066)**, which folds over the H1
  observation history. If a request would build an H2 feature (streaming/CRUD
  ingestion, delta propagation, editorial data-quality flags, compile-to-TS
  emission, anything needing change-over-time or non-linear time), it is now in
  scope — but flag when a task crosses that line so the horizon move is deliberate.

## What this is (one line)

Stelis is the build system. `~/dev/beeatlas` and `~/dev/salishsea-io` are
**case studies / test beds**, not the thing being built. Don't revamp them.

## Environment facts that cause real mistakes

- **Two conflicting Python interpreters in one pipeline.** dlt loaders need Python
  3.14; dbt needs 3.13 (dbt-core hard-crashes on 3.14 — `mashumaro
  UnserializableField`, on every machine). Per-task hermetic runtimes are the
  point, not a workaround.
- Secrets inject hermetically and must **never** reach logs.

## Build, run, test

Toolchain: **Racket v9.2 CS** (on `PATH` at `/Applications/Racket v9.2`). Core is
`#lang racket/base` under [`src/`](src/); the Datalog planner needs the `datalog`
package (`raco pkg install datalog`). No build step — Racket compiles on demand.

- **Run:** `racket src/main.rkt <target>` (print the minimal-upstream plan) ·
  `--commands <target>` (dry-run: print the exact hermetic command per task) ·
  `--explain <target>` (why would each task run or skip?; `--last` for what the
  last `--build` actually did) ·
  `--why <task-or-artifact>` (the transitive why-stale chain, via Datalog) ·
  `--history` (browse recorded builds; `--history <artifact>` for its hash timeline) ·
  `--run <task>` (execute one task in its hermetic runtime) ·
  `--build --all --export-dir <dir>` (build EVERY target into `<dir>` — the run.py
  replacement: covers all of run.py's steps, but content-addressed-skips current
  work and is partial-success rather than fail-fast).
- **Test:** `raco test src/*-test.rkt`.

Layout: [`model.rkt`](src/model.rkt) bipartite graph model + plain-Racket planner,
plus the recipe/runtime TYPES (st-top: the cache hashes a recipe's named code
files into the task's input address) ·
[`plan-datalog.rkt`](src/plan-datalog.rkt) the same plan as a Datalog reachability
rule set · [`beeatlas.rkt`](src/beeatlas.rkt) the authored beeatlas graph, per-task
recipes, and the runtimes (incl. the `notes-harvest` → per-species `notes/` dir →
`notes-assemble` → `notes.json` split, and `beeatlas-partial-tasks` (st-pd1)).
Data only — the 11ty render left the graph in Model Y (ADR 0007 Amendment,
st-5em): the site build is top-level in beeatlas and consumes the export via
`npm run fetch-data` ·
[`exec.rkt`](src/exec.rkt) recipe/runtime types +
subprocess executor, plus in-process `rule-check` nodes — a rule evaluated in
Racket as a graph node, gating its downstream (st-0vz). `run-plan`'s
`#:rebuild-keys-of` does TARGETED execution (st-pd1): a partial-capable task
rebuilds only changed keys via `STELIS_REBUILD_KEYS`, `prune-keys!` retracts
removed ones · [`cache.rkt`](src/cache.rkt)
input-addressed skip decisions + early-cutoff output receipts ·
[`data-quality.rkt`](src/data-quality.rkt) rules that run as `rule-check` nodes;
first rule = the integrity gate (record-count swing vs. the previous build's
observation blocks publish — an OPERATOR alarm, distinct from editorial flags) ·
[`relation-digest.rkt`](src/relation-digest.rkt)
content-addresses db-relation inputs via a DuckDB order-independent digest (row-
coherent = the skip signal), plus per-column digests + non-null counts and a
per-table row `count(*)` as the attribute-level observation (`relation-columns`,
`relation-row-count`, st-7vz/st-0vz) ·
[`notes-digest.rkt`](src/notes-digest.rkt) content-addresses the authoritative
notes STORE (a SQLite `'file` leaf) PER `canonical_name` over approved notes —
the ingestion-boundary read that turns a CRUD on one note into a keyed delta
(`notes-store-keys`, st-2k9); reuses duckdb.rkt's SQLite scanner + the count:sum
idiom. The store's cache-decision input address is the ROLL-UP of these per-key
digests, never its file bytes (WAL freezes the main file while committed rows
live in the -wal); the per-key pairs are also recorded across builds as a trace
`input-key-hashes` snapshot, so `--why notes-harvest` names the changed
species ·
[`duckdb.rkt`](src/duckdb.rkt) the shared read-only DuckDB CLI runner (relation
digests + parquet key extraction + the notes-store SQLite scan) ·
[`tree-digest.rkt`](src/tree-digest.rkt) content-addresses a `'dir` artifact via an
order-independent digest over its sorted (relative-path → content-hash) tree, and
exposes those per-file pairs (`tree-hashes`) for per-key observations ·
[`fan-out-key.rkt`](src/fan-out-key.rkt) verifies a `'dir` output is the right SET —
its files ⊆ the keys (possibly composite) of a declared input relation (JSON or
parquet), or, when filenames are a transform of the key, against an exporter-emitted
manifest (soundness gated, completeness reported) ·
[`trace.rkt`](src/trace.rkt) the per-task build-record shape + its serialization ·
[`history.rkt`](src/history.rkt) append-only, content-addressed build history under
`.stelis/` — per-build observation records (artifact→hash, plus a per-PART
refinement: path→hash for `'dir`, column→digest:count for `'db-relation`) + a
once-per-topology graph snapshot; freshness never reads its sequence (ADR 0005) ·
[`explain.rkt`](src/explain.rkt) per-task why-run/why-skip ·
[`delta.rkt`](src/delta.rkt) the H2 delta substrate entry point (st-066): the pure
per-key delta core — folds a keyed artifact's key-observation timeline into a named
added/removed/changed key-set (`observations->delta`, retrospective; `prospective-delta`,
history-tail vs a live on-disk map). Per-key staleness first, no Z-sets yet ·
[`delta-explain.rkt`](src/delta-explain.rkt) the impure adapter that refines a pure
`'input-changed` decision into that named delta for a PENDING build, so `--why` /
`--explain` name WHICH keys of a changed input are about to move (`explain.rkt`/
`decision->string` stay pure; this is the only IO seam) ·
[`provenance-datalog.rkt`](src/provenance-datalog.rkt) staleness as Datalog rules,
plus the history projection (observed/ran/derived-from facts) ·
[`edge-verify.rkt`](src/edge-verify.rkt) checks a task's declared edge against
runtime reality (declared inputs sufficient? outputs complete?) ·
[`main.rkt`](src/main.rkt) CLI · `src/*-test.rkt` tests ·
[`docs/adr/`](docs/adr/) decisions.

Execution shells into `~/dev/beeatlas` via the runtimes declared in `beeatlas.rkt`:
**uv** (Python 3.14, `data/`) for loaders/exporters and **uvx** (Python 3.13,
`data/dbt/run.sh`) for dbt.

## Standing guardrails (most-violated commitments)

These are in `DESIGN.md`; repeated here because they're the ones easiest to break
in code:

- **Transformations stay external (through Horizon 1).** Orchestrate dlt / dbt /
  exporters; do **not** reimplement their logic in Racket. (Delta propagation
  that touches this is Horizon 2.)
- **Derived vs. authoritative.** Derived outputs are safe to destroy and rebuild;
  authoritative state is forward-only — **never rebuild it from scratch**
  (migrations only).
- **Effects at the boundary.** The derivation core stays pure; IO, ingestion,
  secrets, and rendering are declared boundary nodes.
- **Content-addressed, not timestamped.** Change is measured by content hash.
- **Determinism is a day-one property.** Build the same snapshot twice, compare
  hashes. Watch DuckDB parallelism, floating point, and spatial joins.

## Working mode

- Interactive and didactic. Be deliberate about what functionality is taken on in
  what order; the design space is large and the known failure mode is getting lost
  in it.
- When a request would pull scope forward a horizon, flag it rather than silently
  building it.
- Prefer small, working, end-to-end increments over broad scaffolding.

## Stack

- Core in **Racket** (Rhombus later, per-module, optional). Engine runs
  server-side; the browser is reached by **emission** (compile a small targeted
  artifact), not by running the engine in the browser.
- State in memory for now; a database later (representation designed to allow it).


<!-- BEGIN BEADS INTEGRATION v:1 profile:minimal (trimmed to fit this repo's conventions) -->
## Work tracking — beads (`bd`)

Track work in **bd (beads)**, not TodoWrite/markdown TODO lists. Issues live in a
local Dolt DB under `.beads/`; `bd` auto-exports to `.beads/issues.jsonl` (the
git-tracked view). Run `bd prime` for the full command reference.

```bash
bd ready                # Find available work
bd show <id>            # View issue details
bd update <id> --claim  # Claim work
bd close <id>           # Complete work
```

- This tracks project *work items*. Persistent facts about the user/project still
  go in the file-based memory (see the memory section of the global CLAUDE.md), not
  `bd remember` — the two don't overlap.
- **Commit and push only when asked** (global rule). Beads' default "mandatory
  push" session protocol does **not** apply here; the user drives commits and
  pushes. `bd`'s local DB works fully offline.
<!-- END BEADS INTEGRATION -->
