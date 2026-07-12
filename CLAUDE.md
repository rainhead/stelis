# CLAUDE.md

Operating instructions for an agent working in this repo. Keep this short. The
*what* and *why* live in `DESIGN.md` and `ROADMAP.md` — this file is for not
making predictable mistakes.

## Orient first

- Read `DESIGN.md` and `ROADMAP.md` before starting work.
- Treat `DESIGN.md`'s **settled commitments as decided** — don't relitigate them;
  raise a flag if one seems wrong, don't quietly work around it.
- Treat `ROADMAP.md`'s **horizons as the scope guard.** We are in **Horizon 0**.
  If a request would build a Horizon 1+ feature, say so before building it.

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
  `--run <task>` (execute one task in its hermetic runtime).
- **Test:** `raco test src/*-test.rkt`.

Layout: [`model.rkt`](src/model.rkt) bipartite graph model + plain-Racket planner ·
[`plan-datalog.rkt`](src/plan-datalog.rkt) the same plan as a Datalog reachability
rule set · [`beeatlas.rkt`](src/beeatlas.rkt) the authored beeatlas graph, per-task
recipes, and the two runtimes · [`exec.rkt`](src/exec.rkt) recipe/runtime types +
subprocess executor · [`cache.rkt`](src/cache.rkt) input-addressed skip decisions ·
[`explain.rkt`](src/explain.rkt) per-task why-run/why-skip ·
[`provenance-datalog.rkt`](src/provenance-datalog.rkt) staleness as Datalog rules ·
[`main.rkt`](src/main.rkt) CLI · `src/*-test.rkt` tests ·
[`docs/adr/`](docs/adr/) decisions.

Execution shells into `~/dev/beeatlas` via the runtimes declared in `beeatlas.rkt`:
**uv** (Python 3.14, `data/`) for loaders/exporters and **uvx** (Python 3.13,
`data/dbt/run.sh`) for dbt.

## Standing guardrails (most-violated commitments)

These are in `DESIGN.md`; repeated here because they're the ones easiest to break
in code:

- **Transformations stay external in Horizon 0.** Orchestrate dlt / dbt /
  exporters; do **not** reimplement their logic in Racket.
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
  push" session protocol does **not** apply here; there is no git remote yet, and
  the user drives commits. `bd`'s local DB works fully offline.
<!-- END BEADS INTEGRATION -->
