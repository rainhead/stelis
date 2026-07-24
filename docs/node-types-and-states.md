# Node types & build states

A reference for the two kinds of node in the build graph, and the *states* a task
node can be reported in — the vocabulary behind `--explain`, `--why`,
`--explain --last`, and `--history`.

The code is the source of truth; this doc names the concepts and points at it.
Types live in [`model.rkt`](../src/model.rkt); decisions and receipts in
[`cache.rkt`](../src/cache.rkt); the prose renderings in
[`explain.rkt`](../src/explain.rkt).

## The graph is bipartite

Two node kinds alternate: **task** nodes (the work) and **artifact** nodes (the
data). Edges run task→artifact (a task *produces* an artifact) and artifact→task
(a task *consumes* an artifact). An artifact has at most one producer; a task can
consume and produce many. Planning walks these edges; freshness is judged per
task, from the content of its input artifacts.

## Task node kinds

`task-kind` is one of `'transform | 'gate | 'boundary` ([`model.rkt`](../src/model.rkt)),
plus one special case carried on the invoke slot rather than the kind.

| Kind | What it is | Content-skippable? |
|---|---|---|
| `'transform` | The normal case: derive outputs from inputs by running a recipe in a hermetic runtime (dlt loaders, dbt, exporters). | Yes — skips when its input address is unchanged and its outputs exist. |
| `'gate` | A check that produces a **token** vouching its downstream may proceed (e.g. the integrity gate, resolution gates). Passes/fails; the token is the edge. | Yes — an unchanged input relation cannot be anomalous vs. its own last observation, so the check itself caches ([`cache.rkt`](../src/cache.rkt), st-0vz/st-ysf). |
| `'boundary` | Ingestion: the real input is the **external world** (an API, a remote store), not a content-addressable artifact. | **No** — a boundary always runs. But a *probing* boundary can report its source unchanged (see [Source reports](#source-reports-boundary-probes)). |
| `rule-check` | Not a `task-kind` but an invoke value: a rule evaluated **in-process** as a graph node (no subprocess), gating its downstream ([`exec.rkt`](../src/exec.rkt), st-0vz). Data-quality rules run this way. | Same as the gate it acts as. |

## Artifact node kinds

`artifact-kind` is one of `'file | 'dir | 'db-relation | 'external | 'token | 'code`
([`model.rkt`](../src/model.rkt)). The kind determines *how change is measured* —
and, for `'code`, *how a change is named*.

| Kind | What it is | How it is content-addressed |
|---|---|---|
| `'file` | A single file on disk. Also the shape of an authoritative **keyed store** (the notes SQLite leaf). | Its bytes — except a keyed store, addressed by the roll-up of its per-key digests ([`notes-digest.rkt`](../src/notes-digest.rkt), st-2k9). |
| `'dir` | A directory **tree** — a data-dependent output *set* (e.g. per-species `notes/`, per-genus maps). | An order-independent digest over its sorted `(relpath → hash)` tree ([`tree-digest.rkt`](../src/tree-digest.rkt)); the per-file pairs give a per-key layer. |
| `'db-relation` | A table/relation inside DuckDB. | A DuckDB order-independent row digest, plus per-column digests + counts ([`relation-digest.rkt`](../src/relation-digest.rkt), st-d5d/st-7vz). |
| `'token` | A gate's proof-of-passing; has no bytes. | The recorded input address of its gate's last passing run ([`cache.rkt`](../src/cache.rkt), st-ysf). |
| `'code` | A source file consumed as an **input** (a shared Python helper, st-whi). Carries `imports` edges to the helpers it imports. | Its bytes, like a file — but a change is reported as `'code-changed`, not `'input-changed`. The kind *is* the reason partition. |
| `'external` | A raw input with no producer inside the graph. | Not content-addressable here → forces its consumer to run (`'inputs-unresolvable`). |

## Task states

A task's state answers one of two questions. **Prospectively** (`--explain`,
`--why`): *would* it run, and why? **Retrospectively** (`--explain --last`): what
*did* it do? These are different vocabularies — don't conflate them.

### Prospective — the decision (why run / why skip)

A `decision` is `(verdict reason details)` ([`cache.rkt`](../src/cache.rkt)); the
prose comes from `decision->string` ([`explain.rkt`](../src/explain.rkt)). Verdict
is `'run` or `'skip`. The reasons:

| Reason | Verdict | Meaning |
|---|---|---|
| `boundary` | run | Ingestion — never content-skipped. |
| `inputs-unresolvable` | run | An input isn't content-addressable here (an external, a relation/store with no resolver, a never-passed gate token, or a named code file missing on disk). `details` name them. |
| `no-cache-entry` | run | Never built here (or an unreadable/old cache entry). |
| `code-changed` | run | The task's **code** changed; `details` name the script file(s) (st-top). |
| `recipe-changed` | run | The command or runtime pin changed. |
| `input-changed` | run | A data input's content changed; `details` name the added/removed/changed inputs — refined per-key by [`delta-explain.rkt`](../src/delta-explain.rkt). |
| `output-missing` | run | Inputs unchanged, but an output is gone; `details` name the paths. |
| `output-stale` | run | A `db-relation` output no longer matches what this task built — DuckDB swapped/mutated under the cache (st-84u). |
| `cached` | **skip** | Inputs unchanged, outputs present — the only skip. |

Rendered with glyphs (`--explain`, `--commands`):

- **▶ runs** — verdict `'run`.
- **≡ skips** — verdict `'skip` and no upstream in the plan will run first.
- **≈ conditional** — verdict `'skip` *but* an upstream producer will run before it
  and may change its inputs, so the skip is only provisional
  (`explanation-glyph`, [`explain.rkt`](../src/explain.rkt)).

`--why` walks the transitive *stale-because* chain over these same decisions
([`provenance-datalog.rkt`](../src/provenance-datalog.rkt)).

### Retrospective — the outcome (what happened)

After a real `--build`, each task carries an outcome and (for reruns) up to two
**receipts**. Outcome glyphs (`outcome-glyph`, [`trace.rkt`](../src/trace.rkt)):

- **✓ ok** — ran and succeeded.
- **≡ cached** — skipped; inputs unchanged, outputs present.
- **✗ failed** — ran and exited non-zero.
- **⊘ skipped** — blocked; a producer it depends on failed or was skipped.

### Receipts on a rerun

Two facts can ride an `'ok` rerun, surfaced by `--explain --last`:

- **Output delta** (early cutoff, st-8ig) — `'identical` or `'changed`
  ([`cache.rkt`](../src/cache.rkt) `output-delta`). After a rerun, its rebuilt
  outputs are hashed against the previous build's. `'identical` is the cutoff: the
  task reran but its outputs didn't move, so downstream sees unchanged inputs and
  skips naturally.

- **Source report** (boundary probe, st-8bj) — see next section.

## Source reports (boundary probes)

A `'boundary` always runs, but a *probing* loader can check its external source and
**short-circuit without re-ingesting** when nothing changed (e.g. the Ecdysis
v2-API probe). That self-skip used to be invisible to Stelis — it saw exit 0 and,
at most, an `'identical` output delta, which can't say *why*.

The loader now reports for itself. On a boundary run Stelis passes a receipt path in
`STELIS_BOUNDARY_RECEIPT`; a loader that short-circuits writes JSON there:

```json
{ "unchanged": true, "records": 0, "since": "2026-07-20" }
```

`unchanged` is required and boolean; `records` (new records since `since`) and
`since` (the watermark) are optional. Stelis clears any stale receipt before the
run, reads it after a clean exit, and records a `source-report`
([`cache.rkt`](../src/cache.rkt)) on the trace. A missing or malformed receipt is
treated as *said nothing* (`#f`) — never an error, since a boundary runs regardless.

The loader-side probe lives in beeatlas (issue beeatlas-29j); this repo only
receives and surfaces the report. It appears:

- **Retrospectively** — `--explain --last` (the outcome glyph and decision prose,
  then the receipt):
  `✓ ecdysis  boundary — ingestion; never content-skipped → reran; source unchanged — ingestion skipped, 0 new records since 2026-07-20`.
  For an *unchanged* report it stands alone (outputs were untouched); for a
  *changed* (re-ingested) report the output delta is kept alongside it.
- **Prospectively, history-flavored** — the `--explain` / `--why` boundary line
  reads the task's last actual-run report
  (`history-last-source-report`, [`history.rkt`](../src/history.rkt)):
  `▶ ecdysis  boundary — ingestion; never content-skipped; last run: source unchanged …`.
- **Live** — a terse `↺ source unchanged — ingestion skipped` line during the build.

## Where each surfaces

| Command | Shows |
|---|---|
| `--explain [--from]` | Prospective decision + glyph per task; boundary lines history-flavored. |
| `--commands` | Same frontier, as the exact hermetic command per task (dry run). |
| `--why <task/artifact>` | The transitive stale-because chain over the decisions. |
| `--explain --last` | Retrospective: outcome glyph, decision prose, and receipts (output delta / source report). |
| `--history [<artifact>]` | Build list, or one artifact's content-hash timeline (per-key/column refined). |
