# Stelis

[![tests](https://github.com/rainhead/stelis/actions/workflows/tests.yml/badge.svg)](https://github.com/rainhead/stelis/actions/workflows/tests.yml)

A build system for data pipelines, written in Racket. The build is a bipartite
graph — tasks consume and produce artifacts — and change is measured by content
hash, not timestamp. Datalog serves as a metadata language *about* the build
(reachability, staleness, provenance); the transformations themselves stay in
their own tools (dlt, dbt, exporters), each invoked in its own hermetic runtime.

The *why* lives in [`DESIGN.md`](DESIGN.md); the plan of record in
[`ROADMAP.md`](ROADMAP.md). The current test bed is the
[beeatlas](https://github.com/rainhead/beeatlas) pipeline, whose graph is
authored in [`src/beeatlas.rkt`](src/beeatlas.rkt) — stelis orchestrates it, it
is not part of it. A second pipeline,
[salishsea-io](https://github.com/salish-sea/salishsea-io), is the Horizon 2
(streaming / CRUD) test bed. Both are sister projects and case studies, not part
of stelis.

## Status

This is a private project developed in the open, driven by my own particular
goals — the shape of the design is set by what my projects (the sister pipelines
above) actually need. The near-term aim is to prove out its value there. Once it
has earned its keep on my own work, I'll turn to making it useful for a general
audience; until then, expect rough edges and assumptions that suit my setup
(a local `~/dev/beeatlas` checkout, specific runtimes).

Feedback and pointers are very welcome all the same — please
[open an issue](https://github.com/rainhead/stelis/issues).

## Prerequisites

- **Racket v9.2 CS** on `PATH`, plus the Datalog package:
  `raco pkg install datalog`. No build step — Racket compiles on demand.
- A checkout of **[beeatlas](https://github.com/rainhead/beeatlas)** at
  `~/dev/beeatlas` (the graph shells into it).
- **uv**, which provides both hermetic Python runtimes declared in
  [`src/beeatlas.rkt`](src/beeatlas.rkt): uv/Python 3.14 for loaders and
  exporters, uvx/Python 3.13 for dbt. (Two interpreters on purpose — dbt
  cannot run on 3.14; per-task runtimes are the point.)

## Running

Everything goes through the CLI. A *target* is an artifact name
(e.g. `occurrences.db`); a *task* is a build step.

```sh
racket src/main.rkt occurrences.db              # the minimal-upstream plan, in build order
racket src/main.rkt --commands occurrences.db   # dry run: the exact command per task
racket src/main.rkt --explain occurrences.db    # why would each task run or be skipped?
racket src/main.rkt --why occurrences.db        # why is it stale? (a task or artifact; transitive chain)
racket src/main.rkt --build occurrences.db      # execute the plan (partial success)
racket src/main.rkt --build --all --export-dir DIR  # build EVERY target into DIR — the run.py replacement
racket src/main.rkt --explain --last            # what did the last build actually do?
racket src/main.rkt --run generate-sqlite       # execute a single task
racket src/main.rkt --verify occurrences.db     # determinism: build twice, compare hashes
```

`--from <task>` restricts `--build`, `--commands`, `--explain`, `--why`, and
`--verify` to the plan suffix starting at that task — useful for exercising the derived
tail without re-running ingestion:

```sh
racket src/main.rkt --build --from generate-sqlite occurrences.db
```

Reading the annotations: `▶` runs (the reason says why — a named changed
input, changed task code (the file named), a changed recipe, no cache entry,
a missing output, or a boundary/
non-content-addressable task) · `≡` skips (inputs unchanged, outputs present)
· `≈` conditional (a cache hit today, but an upstream will run first and may
change its inputs).

Whether a `≈` resolves to a skip is **early cutoff**: a task that reruns but
rebuilds its outputs to identical content leaves downstream inputs unchanged,
so downstream tasks cache-skip naturally. A real build records the comparison,
and `--explain --last` names the cutoff point ("reran; outputs identical").
See [ADR 0003](docs/adr/0003-early-cutoff.md).

Inputs are content-addressed by kind: a file by its bytes, a **db-relation** by
an order-independent DuckDB digest of its rows (dlt bookkeeping columns
excluded), so a loader that re-lands identical content lets its downstream
transforms cache-skip — cutoff reaches the pre-dbt graph, not just the file
edges around `dbt-build`. See [`relation-digest.rkt`](src/relation-digest.rkt).

A task's **code is an input too**: each recipe's named script file(s) are
hashed into its input address alongside the resolved command line, so editing
a loader/exporter (or a runtime pin) invalidates its cache and the decision
names the changed file. Named files only — Python imports are not traced; a
task known to lean on a shared helper declares it on its recipe explicitly.
Only inputs with no content to hash — gate tokens, externals — stay
non-addressable and force a conservative rerun.

Outputs land in an explicit export directory (a scratch dir under the system
temp dir, printed at build time). Build state — the input-addressed cache and
the last-build trace — lives in `.stelis/`, which is derived and disposable:
delete it and the only consequence is a full rebuild.

## Tests

```sh
raco test src/*-test.rkt
```

Pure-core units over synthetic graphs, integration checks against the authored
beeatlas graph, and cross-checks that the Datalog rule sets agree with the
plain-Racket implementations of the same questions.

## Layout and work tracking

The module map is in [`CLAUDE.md`](CLAUDE.md); decisions in
[`docs/adr/`](docs/adr/). Work items are tracked in beads (`bd ready`,
`bd show <id>`), stored under `.beads/`.
