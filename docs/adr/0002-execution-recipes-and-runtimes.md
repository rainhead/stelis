# ADR 0002 — Execution recipes and hermetic runtimes (slice 2)

**Status:** accepted · **Horizon:** 0 · **Date:** 2026-07-11

Decides how Stelis invokes a task, and how the dual-interpreter reality is
represented. Extends [ADR 0001](0001-build-graph-model.md); populates the `invoke`
slot that ADR reserved.

## Context

beeatlas already solves the dual-interpreter problem, so Stelis must **delegate**
to it, not reimplement it:

- `data/` is a `uv` project pinned to **Python 3.14** (`.python-version`), where
  the dlt loaders and exporters run.
- dbt is shelled through `data/dbt/run.sh`, which runs
  `uvx --python 3.13 --from dbt-core==1.10.1 …` — an ephemeral **Python 3.13** tool
  env (dbt-duckdb crashes on 3.14).

So "per-task hermetic runtime invocation" reduces to: run the right command per
task, in the right runtime. Hermeticity is beeatlas's `uv`/`uvx` pins; Stelis
orchestrates.

## Decisions

1. **A task's `invoke` slot holds a structured `recipe`, not a command string.**
   `recipe = (runtime-tag, args)`. A command string would bury the 3.14-vs-3.13
   runtime in text nothing can reason about; a structured recipe keeps the
   runtime explicit metadata the caching/determinism/secrets layers can inspect.

2. **Runtimes are declared once, referenced by name.** Two cover the pipeline:
   `uv` (`uv run --directory <data> python …`, 3.14) and `dbt`
   (`bash <data>/dbt/run.sh …`, uvx 3.13). Factoring the launch prefix out of 32
   recipes makes the dual-interpreter split a single visible fact.

3. **Recipes are transcribed from `run.py`'s imports** (module + function), the
   same `from M import F; F()` calls run.py makes — so the recipe is faithful to
   how beeatlas actually runs each step. *Exception:* `dbt-build`'s recipe is
   `run.sh build` only; `run.py`'s `_run_dbt_build` also copies six parquets to
   `EXPORT_DIR`. That copy is a downstream artifact-*placement* concern, not part
   of the transform, and is not needed for `occurrences.db` (`generate-sqlite`
   reads `occurrences.parquet` from the dbt sandbox directly). Deferred to
   st-d44.4 (explicit output destinations).

4. **Slice 2a is dry-run only.** Resolve recipes to commands and print them
   (shell-quoted, copy-paste runnable); execute nothing. Actual subprocess
   execution — starting with the one cheap, network/secret-free task
   (`generate-sqlite`) — is 2b. Streaming logs, partial success, and secrets
   injection are separate issues (st-d44.5 / st-d44.4 / later).

## Consequences

- The reserved `invoke` slot is now populated for all 32 tasks; `model.rkt` stays
  runtime-agnostic (it never inspects `invoke`); `exec.rkt` owns recipe/runtime
  types and the dry-run printer; `beeatlas.rkt` owns the runtime definitions and
  the transcribed recipes.
- `racket src/main.rkt --commands occurrences.db` emits the exact 21-command
  hermetic plan, 20 under `uv/3.14` and 1 (`dbt-build`) under `uvx/3.13`.
- The beeatlas root path is currently hard-coded in `beeatlas.rkt`; a config seam
  is deferred until a second consumer needs it.
