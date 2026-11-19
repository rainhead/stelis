# CLAUDE.md

Operating instructions for an agent working in this repo. This file is for not making predictable mistakes. The what and why live in `DESIGN.md` and `ROADMAP.md`; the detail of each subsystem lives in `docs/agents/`, and the pointers below say when to read each one. `src/claude-md-size-test.rkt` holds this file under 16 KB: put new detail in `docs/agents/` behind a pointer, not here.

## Orient first

- Read `DESIGN.md` and `ROADMAP.md` before starting work.
- Treat `DESIGN.md`'s settled commitments as decided. Don't relitigate them; raise a flag if one seems wrong, and don't quietly work around it.
- Treat `ROADMAP.md`'s horizons as the scope guard. Horizon 1 is delivered (2026-07-16): provenance, the observation history (`.stelis/`, with per-key and per-column granularity), early cutoff, data-quality rules as nodes with the integrity gate, and full target coverage all shipped and verified. Horizon 2 is open.
- The pull is data modeling, not build features (2026-08-03). The build detour has paid out (`DESIGN.md`, "The detour has paid out"). Two things are active: `st-hdm`'s per-page provenance, which closes out the build work, and the taxon reasoning arc (type the host and parasite edges over the inherited traits, then the at-risk closure; ADR 0008), which is the data-modeling line. The rest of Horizon 2 (delta propagation, streaming and CRUD ingestion, compile-to-TS emission, demand-directed evaluation) is recorded, not queued: it waits for something in the data work to need it.
- But Stelis is also the production build tool for more than one project, and it must not do that badly (2026-10-21). So the first question about a proposed build feature is who is waiting on it (ROADMAP's slotting rule): a data question, or a project that builds with Stelis and is worse off without it, such as a deploy that breaks, a volume that can't be recovered, or a build too slow or too opaque to operate. Either is a pull. What still waits is capability that nobody needs yet ("delta propagation would be elegant"); say so rather than building it. If the user asks anyway, that is the pull; build it.

## What this is

Stelis is the build system. `~/dev/beeatlas` and `~/dev/salishsea-io` are case studies and test beds, not the thing being built. Don't revamp them.

## Environment facts that cause real mistakes

- Per-task hermetic runtimes are the point, not a workaround. The original proof was two conflicting Python interpreters in one pipeline: dlt loaders on 3.14 and dbt on 3.13, because dbt-core crashed on 3.14 (`mashumaro UnserializableField`, on every machine). Since beeatlas #129 (2026-10) dbt runs from the same `data/` environment as the loaders, on 3.14, through `data/dbt/run.sh`. The `dbt` runtime is still its own declaration with its own identity probe (st-kbi), so what moves it is still observed on its own.
- Execution shells into `~/dev/beeatlas` through the runtimes declared in [`src/beeatlas.rkt`](src/beeatlas.rkt): uv (Python 3.14, `data/`) for loaders and exporters, and dbt (`data/dbt/run.sh`). salishsea's tasks run at its `.nvmrc` node, in its checkout.
- Secrets inject hermetically and must never reach logs. salishsea's snapshot reads `SUPABASE_DB_URL` from the caller's environment and never prints it.
- Toolchain: Racket v9.3 CS (on `PATH` at `/Applications/Racket v9.3`). Core is `#lang racket/base` under [`src/`](src/). The Datalog planner needs the `datalog` package (`raco pkg install datalog`). The DASL CIDs need `sha`, which, unlike `datalog`, is not in the full distribution, so CI installs it from the commit [`racket-deps.txt`](racket-deps.txt) pins (an unpinned install is different code on different days, st-8u3). There is no build step; Racket compiles on demand.
- Every installer takes the Racket source and package pins from [`racket-deps.txt`](racket-deps.txt) and [`racket-downloads.tsv`](racket-downloads.tsv), through [`scripts/install-racket.sh`](scripts/install-racket.sh). Don't add a host that carries its own copy of the steps.
- The database a build is about is named in every banner. beeatlas's is strict: `--build`, `--run`, `--trace-reads`, `--verify` and `--verify-edges` refuse when `DB_PATH` is unset and the checkout copy exists, so a local build says `DB_PATH=~/dev/beeatlas/data/beeatlas.duckdb` out loud (its nightly once gated against the stale copy while the pipeline read the serving one, st-az9). Every project's executing modes also refuse a relative database path, because the engine resolves it from its cwd and the tasks from theirs, so it names two files (st-hs7).
- A state directory belongs to one engine process and one project: a build that must run beside another needs a state directory of its own, and so a graph of its own. A state directory holding another project's builds is refused rather than read across (st-z1c).

## Run and test

- Run: `racket src/main.rkt [--project <name-or-path>] <target>` prints the minimal-upstream plan. Add `--commands` for a dry run that prints the exact hermetic command per task, `--explain` for why each task would run or skip, `--build` to build, `--run <task>` to execute one task in its runtime, and `--history` to browse recorded builds. `--project` goes before the target; `beeatlas` is the default.
- Test: `raco test src/*-test.rkt`. Tests that need an environment a bare checkout lacks (beeatlas, DuckDB, a reference build, the linked collection) are gated through [`test-gate.rkt`](src/test-gate.rkt): they print `NOT CHECKED` and pass, unless `STELIS_REQUIRE_GATED=1`, which makes each one a failure (set by an unattended gate such as beeatlas's nightly; one skip is exempt, with the reason at its call site). `STELIS_REFERENCE_DIR` names the reference build the fan-out-key integration test reads (default: the scratch `stelis-out`). The edge-verify check is not in the suite: run `racket src/main.rkt --verify-edges --export-dir DIR` after a build (st-cip).

## When to read a doc in docs/agents/

Read the doc before you start that kind of work; each opens with the situation it is for.

- Before using a mode you haven't used, or writing a script that runs `--build` (a nightly, a deploy, a save-triggered build): [`docs/agents/cli-modes.md`](docs/agents/cli-modes.md). It holds every mode, the `yield` file and exit codes 1, 3 and 75, `--report-dir`, `--mark-publish` and `--downstream`.
- Before changing how Racket or its packages are installed, CI's setup, the Dockerfile, the image workflow, or a consumer's Dockerfile that copies Stelis from the image: [`docs/agents/toolchain-and-image.md`](docs/agents/toolchain-and-image.md).
- Before changing a project's graph, adding a project, or choosing a project, state directory or database for a build (beeatlas's `app-bundle` and `precompress` nodes, salishsea's two graphs in its own repo): [`docs/agents/projects.md`](docs/agents/projects.md).
- Before changing the graph model, the executor, the skip decisions and cache, boundary and incremental tasks, or the scanners that find a task's code inputs: [`docs/agents/engine-core.md`](docs/agents/engine-core.md).
- Before changing how an input or output is addressed (database relations, SQLite and DuckDB mirrors, per-key observations, directory trees and their extents, CIDs and CBOR, fan-out checks): [`docs/agents/relations-and-digests.md`](docs/agents/relations-and-digests.md).
- Before changing the build history in `.stelis/`, its retention, the per-key delta behind targeted rebuilds, or the `--why`, `--explain` and `--history <artifact>:<key>` answers: [`docs/agents/history-and-delta.md`](docs/agents/history-and-delta.md).
- Before changing the taxon reasoning arc (inheritance, edge typing, the at-risk closure, `species_reasoning.json`, `species_dependencies.json`): [`docs/agents/taxon-reasoning.md`](docs/agents/taxon-reasoning.md).
- Before changing `--verify-edges` or `--trace-reads`, or when a task reads or writes something it didn't declare: [`docs/agents/verification-probes.md`](docs/agents/verification-probes.md).
- Before changing the operator build log, `--render-log` or publish receipts: [`docs/agents/build-log.md`](docs/agents/build-log.md).
- Decisions are in [`docs/adr/`](docs/adr/); read the ADR for the area you are changing.

## Standing guardrails (most-violated commitments)

These are in `DESIGN.md`; repeated here because they're the ones easiest to break in code.

- **Transformations stay external (through Horizon 1).** Orchestrate dlt, dbt and exporters; do not reimplement their logic in Racket. (Delta propagation that touches this is Horizon 2.) One deliberate exception, ADR 0008 D5: a `derivation` node runs a transform inside the engine, and what earns that is narrow: unbounded-depth closure with defeasible override and a native "why" (taxon reasoning, st-ozp). A bounded join or a bulk aggregation still goes to dbt and DuckDB; adding a second derivation needs the same argument made afresh.
- **Provenance says where an artifact comes from. There are three values, and they are checked** (ADR 0013). `derived` is safe to destroy and rebuild, and must have a producer. `authoritative` is forward-only, never rebuilt from scratch (migrations only), and may or may not have a producer: a task may write forward-only state, and so may a writer outside the graph. `upstream` is somebody else's data snapshotted in, not ours to migrate either, and must not have a producer. `build-graph` rejects any disagreement with the topology, and `make-artifact` rejects a value outside the vocabulary.
- **Effects at the boundary.** The derivation core stays pure; IO, ingestion, secrets and rendering are declared boundary nodes.
- **Content-addressed, not timestamped.** Change is measured by content hash.
- **Determinism is a day-one property.** Build the same snapshot twice and compare hashes. Watch DuckDB parallelism, floating point and spatial joins.
- **Keep `compile-deps` in `src/main.rkt`.** It looks like dead code, but it is what makes `raco make src/main.rkt` compile the registered graphs.

## Working mode

- Interactive and didactic. Be deliberate about what functionality is taken on in what order; the design space is large and the known failure mode is getting lost in it.
- When a request would pull scope forward a horizon, flag it rather than silently building it.
- Prefer small, working, end-to-end increments over broad scaffolding.

## Stack

- Core in Racket (Rhombus later, per-module, optional). The engine runs server-side; the browser is reached by emission (compile a small targeted artifact), not by running the engine in the browser.
- State in memory for now; a database later (representation designed to allow it).


<!-- BEGIN BEADS INTEGRATION v:1 profile:minimal (trimmed to fit this repo's conventions) -->
## Work tracking — beads (`bd`)

Track work in **bd (beads)**, not TodoWrite/markdown TODO lists. The source of
truth is the embedded Dolt DB under `.beads/embeddeddolt/`, replicated to the
GitHub remote (see the push rule below). Run `bd prime` for the full command
reference.

Query it with `bd list` / `bd show` / `bd search` — there is no file to grep.

```bash
bd ready                # Find available work
bd show <id>            # View issue details
bd update <id> --claim  # Claim work
bd close <id>           # Complete work
```

- This tracks project *work items*. Persistent facts about the user/project still
  go in the file-based memory (see the memory section of the global CLAUDE.md), not
  `bd remember`: this repo is public, so everything in beads can be read by anyone.
- **Sync beads regularly, without asking** (2026-08-16). `bd sync` pulls, checks
  for conflicts and pushes the Dolt data plane to `refs/dolt/data` on this repo's
  GitHub remote; it never touches `refs/heads/main`. Sync after filing or closing
  issues and before ending a session (the SessionStart hook syncs too) — un-pushed beads live only in `.beads/embeddeddolt/` on one machine.
  This is the **one** exception to the global "push only when asked" rule, which
  still governs `git push` of code.
<!-- END BEADS INTEGRATION -->
