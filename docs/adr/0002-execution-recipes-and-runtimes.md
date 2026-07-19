# ADR 0002 — Execution recipes and hermetic runtimes (slice 2)

**Status:** accepted · **Horizon:** 0 · **Date:** 2026-07-11

**Amended:** 2026-07-19 (st-top — see Amendment below; revises the first
Consequence's type allocation).

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

## Amendment — task code joins the input address; recipe types move to model.rkt (2026-07-19)

st-top (found in production): editing a recipe's script did **not** invalidate
its cache — the input address covered only declared data inputs, so a changed
`notes_harvest.py` shipped a stale `notes.json` under "cached — inputs
unchanged". A task's code (script content, command line, runtime pin) IS an
input to its output; it must be content-addressed like one.

Two revisions to this ADR's allocations:

1. **`recipe` gains a `code` slot** — the named script file(s) behind the
   command, as resolved paths. The cache hashes each file's content into the
   task's snapshot (`code-hashes`, CACHE-VERSION 4) alongside the **resolved
   argv** (launch prefix included, so a runtime pin change invalidates like an
   args change — `build-env` carries the runtimes map for this). The
   `py` helper derives `data/<module>.py` automatically; `#:code` declares
   known shared helpers (direct imports only — transitive imports are a
   deliberate punt, tracked with the dbt code hole in st-0ql).

2. **The consequence "`model.rkt` stays runtime-agnostic; `exec.rkt` owns
   recipe/runtime types" is revised: the `runtime`/`recipe` TYPES (and
   `recipe->argv`) now live in `model.rkt`.** Forced by layering: the cache
   must inspect `recipe-code`, and `exec.rkt` requires `cache.rkt`, so the
   types had to sit below both. The split is now types-in-model /
   behavior-in-exec: `exec.rkt` keeps subprocess execution, the dry-run
   printer, and `rule-check`, and re-provides the moved names so callers are
   unchanged. `model.rkt`'s *planner* still never inspects `invoke`.
