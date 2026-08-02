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
package (`raco pkg install datalog`) and the DASL CIDs need `sha`
(`raco pkg install sha` — unlike `datalog`, it is NOT in the full distribution, so
CI installs it explicitly). No build step — Racket compiles on demand.

- **Run:** `racket src/main.rkt <target>` (print the minimal-upstream plan) ·
  `--commands <target>` (dry-run: print the exact hermetic command per task) ·
  `--explain <target>` (why would each task run or skip?; `--last` for what the
  last `--build` actually did) ·
  `--why <task-or-artifact>` (the transitive why-stale chain, via Datalog — PROSPECTIVE) ·
  `--history` (browse recorded builds; `--history <artifact>` for its hash timeline;
  `--history <artifact>:<key>` for why that ONE key last moved — the RETROSPECTIVE
  family, st-nbu) ·
  `--block <cid>` (print a stored block as a readable datum — state is
  content-addressed and binary since ADR 0010, and this is the way back out) ·
  `--moved-keys <artifact>` (which keys moved in the LAST build, machine-readable —
  bare keys on stdout, everything else on stderr; exit 1 = no basis, rebuild in full) ·
  `--run <task>` (execute one task in its hermetic runtime) ·
  `--build --all --export-dir <dir>` (build EVERY target into `<dir>` — the run.py
  replacement: covers all of run.py's steps, but content-addressed-skips current
  work and is partial-success rather than fail-fast).
- **Test:** `raco test src/*-test.rkt`.

Layout: [`model.rkt`](src/model.rkt) bipartite graph model + plain-Racket planner,
plus the recipe/runtime TYPES (st-top: the cache hashes a recipe's named code
files into the task's input address; `optional-code` wraps one whose ABSENCE is a
legitimate steady state, st-e4y — it addresses to a stable sentinel instead of
`#f`, so absent-but-could-appear stops meaning "unresolvable, rerun forever", and
`#f` keeps its one meaning) and `'code` artifacts with `imports` edges +
`code-closure` (st-whi: shared helpers are producerless graph nodes, helper→helper
import edges are topology, and transitive code dependence is a walk, never a
stored flattened list) ·
[`plan-datalog.rkt`](src/plan-datalog.rkt) the same plan as a Datalog reachability
rule set · [`beeatlas.rkt`](src/beeatlas.rkt) the authored beeatlas graph, per-task
recipes, and the runtimes (incl. the per-species `notes/` dir — the TERMINAL notes
artifact since beeatlas-6x9 retired the `notes.json` roll-up; `_data/notes.js`
reads the dir — and `beeatlas-partial-tasks` (st-pd1)).
Data only until st-hdm: the 11ty render left the graph in Model Y (ADR 0007
Amendment, st-5em), and ADR 0007's per-page-provenance amendment is bringing it
back as TWO nodes. `app-bundle` is the first (step 2, delivered): `_site/assets`
as a plain 'dir at a FIXED path — the only output not steered by EXPORT_DIR,
because the site build has one home for it. No data inputs at all, so its only
reason to run is `code-changed`; its inputs ride as recipe `code` (src/ expands
per-file like dbt's models/), which is why `--why app-bundle` names the exact
edited file. The `node` runtime pins beeatlas's .nvmrc node by sourcing nvm, the
way nightly.sh does — nothing about `npm` carries that pin, and the default here
is 26, not 24.18. All four env files Vite loads in production mode are declared,
though only `.env` exists, via `optional-code` (st-e4y) — so a `.env.production`
appearing later reads as `code-changed` naming it instead of being invisible to
the cache (beeatlas ADR 0019: rotate the token, the gate skips nightly, the live
site keeps serving the revoked one). The step-3 cutover is still pending — the
site build's `build:app` rebuilds the bundle itself, so this node's run is
redundant — but it is NOT un-called: the nightly's `--all` covers every target,
which now includes it (st-hdm notes, 2026-08-02). `precompress` (st-ljy) is the
second non-data node, and the first whose output is a REPRESENTATION rather than a
dataset: `compressed/`, the `.br`/`.gz` siblings of the seven runtime artifacts.
beeatlas ADR 0024 established those and put them in the PUBLISH step, where they
cost ~2.9s on every note write for a 34 MB db that changes nightly; compression is
a pure function of a content-addressed input, so here early cutoff runs it when the
DATA moves and the publish copies (measured 2.75s → 0.15s). WHICH artifacts rides
on argv rather than being read from beeatlas's own list by the script — a script
compressing more than the graph declared would move this dir's digest with no
declared input change, which is a wrong skip. Both node tasks now hash `.nvmrc` as
code (`node-runtime-code`): the launch prefix sources nvm, so the PIN decides the
interpreter and nothing in the argv does — gzip -9 of the same db is 5,208,681
bytes under node 24.18 and 5,203,283 under 26 ·
[`exec.rkt`](src/exec.rkt) recipe/runtime types +
subprocess executor, plus the two IN-PROCESS invoke variants: `rule-check` — a
rule evaluated in Racket as a graph node, gating its downstream (st-0vz) — and
`derivation` (st-ozp), which likewise runs in Racket but PRODUCES an artifact, so
it goes through the full producing-node path (observed, receipted, cutoff-compared)
and its `code` is Stelis's own source, making a rule edit report `'code-changed`. `run-plan`'s
`#:rebuild-keys-of` does TARGETED execution (st-pd1): a partial-capable task
rebuilds only changed keys via `STELIS_REBUILD_KEYS`, `prune-keys!` retracts
removed ones, and partial mode needs the on-disk dir to MATCH the last clean
run's receipt (`prior-complete-build?`, st-243), not merely exist. A `'boundary`
task is handed a `STELIS_BOUNDARY_RECEIPT` path (st-8bj): a probing loader that
short-circuits an unchanged source writes `{unchanged, records, since}` there, and
run-plan reads it back as a `source-report` on the trace, so `--explain`/`--why`
name WHY the boundary didn't re-ingest (the loader-side probe is beeatlas-29j) ·
[`cache.rkt`](src/cache.rkt)
input-addressed skip decisions + early-cutoff output receipts; a gate TOKEN is
addressed by its gate's recorded input address (st-ysf), so dbt-build can skip ·
[`corrections-drift.rkt`](src/corrections-drift.rkt) the operator gate behind the
CORRECTION overlay (st-t4t): beeatlas holds local overrides of values an upstream
source gets wrong (a dbt seed + a precedence arm — a bounded join, so by ADR 0008's
gate it earns no substrate), and each records the `expected_upstream` it was written
against. This node fails the build when upstream stops matching, so a correction
cannot silently outlive the error it fixes — and catches the case dbt structurally
cannot, a correction whose upstream row is gone ·
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
idiom. The store's cache-decision input address is the CID of these per-key digests
as a keyed block, never its file bytes (WAL freezes the main file while committed rows
live in the -wal); the per-key pairs are also recorded across builds as a trace
`input-key-hashes` snapshot, so `--why notes-harvest` names the changed
species ·
[`duckdb.rkt`](src/duckdb.rkt) the shared read-only DuckDB CLI runner (relation
digests + parquet key extraction + the notes-store SQLite scan) ·
[`rkt-imports.rkt`](src/rkt-imports.rkt) the same idea for RACKET (st-egh): the
transitive closure of a module's local (string) requires, so a `derivation` node's
code covers what its modules actually depend on. Hand-listing missed duckdb.rkt —
an edit there changed every taxonomy read while the recorded code-hashes stayed
put, so the node cache-skipped on stale output. Collection requires are not
followed (pinned by the package install, not source here) ·
[`py-imports.rkt`](src/py-imports.rkt) scans a script's LOCAL imports at
graph-authoring time (st-6ga: a regex line scan; basename-set membership rejects
installed packages + docstring prose). Its DIRECT lookup authors the st-whi
edges — a `py` task consumes its entry's direct imports as `'code` inputs, each
helper artifact carries its own — so the shared-helper dependence is computed,
not hand-transcribed (fixes the places_maps→species_maps→config drift); the
cache partitions inputs by kind, so a helper edit still reports `'code-changed`
naming the file. `#:code` survives only as the escape hatch for imports a scan
can't see (dynamic/importlib, baked-in data files) ·
[`tree-digest.rkt`](src/tree-digest.rkt) content-addresses a `'dir` artifact by its
(relative-path → content-hash) tree, and exposes those per-file pairs
(`tree-hashes`) for per-key observations ·
[`keyed-block.rkt`](src/keyed-block.rkt) the roll-up itself (st-1e5): a keyed
artifact's per-key map as a DRISL block, whose CID **is** the artifact's digest — so
the roll-up and the parts are ONE object and cache.rkt's old assertion that "the two
granularities can never disagree" holds by construction. Retires `digest-of-pairs`,
whose `key=value` line join was genuinely ambiguous (`{"a=b"→"c"}` and `{"a"→"b=c"}`
collided) and whose order-independence lived in its callers' sorting rather than in
itself. Applies to `'dir` and the keyed notes store; a **db-relation is deliberately
NOT a caller** — its identity is the row-coherent digest, because per-column
multiset digests false-skip on a cross-row value swap (st-d5d) ·
[`dasl.rkt`](src/dasl.rkt) + [`drisl.rkt`](src/drisl.rkt) the CID and the
deterministic CBOR profile it addresses (ADR 0010, st-b7v): one value, exactly one
byte sequence, so a sha-256 over it is an IDENTITY rather than a fingerprint of
some printing. Parsers REJECT rather than soften — the conformance suite types
every deviation as `invalid_in`, because each would be a SECOND spelling of a value
that already has one. Conformance is a runner over the pinned
[`vendor/dasl-testing`](vendor/dasl-testing), not transcribed cases. Adoption is
incremental, and the split matters when reading a hash: **CIDs** address the graph
snapshot, a `'dir` artifact, and the keyed notes store; **sha1** still addresses a
plain `'file` artifact, recipe and code hashes, and gate tokens, and it is still the
per-key LEAF value inside a block. So a `'dir` digest and a `'file` digest are not
the same kind of string — st-1e5 changed the former, not the latter ·
[`fan-out-key.rkt`](src/fan-out-key.rkt) verifies a `'dir` output is the right SET —
its files ⊆ the keys (possibly composite) of a declared input relation (JSON or
parquet), or, when filenames are a transform of the key, against an exporter-emitted
manifest (soundness gated, completeness reported); a `store-keyed` dir (notes/,
st-243) gates IDENTITY vs. the store keyset — both strays and gaps fail ·
[`trace.rkt`](src/trace.rkt) the per-task build-record shape + its serialization ·
[`history.rkt`](src/history.rkt) append-only, content-addressed build history under
`.stelis/` — per-build observation records (artifact→hash, plus a per-PART
refinement: path→hash for `'dir`, column→digest:count for `'db-relation`) + a
once-per-topology graph snapshot. Both the snapshot AND each record's keyed maps
now live in [`blockstore.rkt`](src/blockstore.rkt) (`.stelis/blocks/<cid>`, st-1e5),
with the log line naming them by CID — so a build that re-produced an UNCHANGED
`notes/` map writes no new BLOCK, where before it rewrote a line naming every
species. (The log line itself still grows by one line per build; what stops growing
with the species count is the payload.)
The swap happens at SERIALIZATION, so `trace-record` still carries real maps and no
reader (delta, `--moved-keys`, explain) knows about blocks; reading is tolerant of
the old inline shape, so the accumulated timeline survived without a version bump.
A block's FILENAME is the CID of its own bytes and `block-ref` re-checks it, so
corruption is detected rather than decoded; freshness never reads its sequence
(ADR 0005) ·
[`explain.rkt`](src/explain.rkt) per-task why-run/why-skip ·
[`delta.rkt`](src/delta.rkt) the H2 delta substrate entry point (st-066): the pure
per-key delta core — folds a keyed artifact's key-observation timeline into a named
added/removed/changed key-set (`build-key-delta`, retrospective, at one recorded build;
`prospective-delta`, history-tail vs a live on-disk map). Per-key staleness first, no
Z-sets yet. `--moved-keys` is its first EXTERNAL consumer (beeatlas-4oa): the same fact
that steers a targeted rebuild inside the engine, handed to a targeted step outside it —
so beeatlas's scoped 11ty render and the notes harvest cannot disagree about which
species moved. Its three answers stay distinct on purpose — a delta, 'not-produced
(nothing moved, an ANSWER), and 'no-basis (refuse; the caller must rebuild in full) ·
[`dir-extent.rkt`](src/dir-extent.rkt) which files a `'dir` artifact actually OWNS
(st-hdm). A `'dir` meant "this whole tree", which stops being true the moment two
producers share one: beeatlas's `_site` holds Vite's `assets/`, the data step's
`data/`, and Eleventy's pages — and the page tree is not a subtree of anything, it
is `_site` minus two carve-outs plus four loose files at the root. So an artifact
rooted at P excludes the root of every OTHER `'dir` artifact strictly inside P,
DERIVED from the graph rather than declared: a `#:excluding` list would be a
hand-kept mirror of other producers' extents whose failure mode is silent (forget
it and the outer digest absorbs output it doesn't produce). A new producer carves
itself out automatically, and an EXACT root collision is refused by
`check-dir-extents` — a graph bug Stelis previously could not see. Cost accepted:
an artifact's digest is now a fact about the graph, not the directory alone.
Applied at ONE seam because `tree-digest` IS `keyed-block-digest` over
`tree-hashes` (st-1e5), so the roll-up and the parts cannot disagree. Path
comparison is element-wise (`explode-path` + `simplify-path`): `/a/b` and `/a/b/`
are not `equal?` in Racket, and `<root>/../elsewhere` is a SIBLING, not a child ·
[`rebuild-policy.rkt`](src/rebuild-policy.rkt) what a delta ARM means to the task
that consumes it (st-qxq). delta.rkt says which keys moved; this says what to do
about each, PER TASK, because the answer differs: notes-harvest's output keyspace
IS its input's, so a removal must delete the file — while the site render's keys
are page paths, so a removal must RE-RENDER the page without its notes section and
delete nothing (beeatlas ADR 0017). The policy is READ, not declared twice: `notes`
is already `(store-keyed 'notes-store.db "{}.json")`, which states the keyspace
correspondence AND the filename transform as data, so an output store-keyed on the
changed input takes the prune arm and everything else takes the rebuild arm. An
`#:on-removed` slot would have been a second source of truth able to contradict it.
Shapes with no safe answer are refused by `check-partial-tasks` at PRE-BUILD
validation — so a graph-authoring mistake fails while the graph is being edited,
not on the rare later build where a key finally disappears. Pruning stays reserved
to store-keyed identity: a `fan-out` output is a FILTERED subset, so a key can also
leave by dropping out of the filter, which pruning would not catch ·
[`delta-explain.rkt`](src/delta-explain.rkt) the impure adapter that refines a pure
`'input-changed` decision into that named delta for a PENDING build, so `--why` /
`--explain` name WHICH keys of a changed input are about to move (`explain.rkt`/
`decision->string` stay pure; this is the only IO seam) ·
[`key-blame.rkt`](src/key-blame.rkt) provenance that reaches a KEY (st-nbu, the
capability st-hdm's per-page-provenance case rests on): `--history <artifact>:<key>`
walks BACKWARD through the observation history — key K moved at build B, the trace-record
there carries the decision that build RECORDED (read, never re-derived), and each named
input with a per-key timeline contributes its own moved keys AT B, recursively. The
`at-or-before` bound is what keeps a branch pinned to the build that moved its consumer
instead of drifting to the newest thing that ever happened to it. Deliberately maps NO
key onto another artifact's keys (beeatlas ADR 0017: that would put a beeatlas naming
convention in the engine), so the chain fans out — exact in the one-note-one-page case,
honest otherwise; fan-out-key's manifest arm is the declared hook if narrowing is ever
earned. The chain ENDS at an authoritative input: a keyed store's per-key map is
recorded on its CONSUMER's record, whose decision names the store itself — so a naive
walk recursed notes-store.db into notes-store.db (caught by running it on a real notes
build, not by a test). Observed-as-consumed is a leaf, which is where provenance
genuinely stops: past the ingestion boundary is a CRUD write, not a build. Pure walk
over a `kobs-of` lookup, IO seam in main.rkt ·
[`taxon-inherit.rkt`](src/taxon-inherit.rkt) the H2 reasoning beachhead's PURE core
(st-ozp, ADR 0008): curated trait assertions at a high rank inherited down the
taxonomic rank tree by Datalog closure, each derived fact carrying the asserting
ancestor as its proof. The closure is phrased DOWNWARD (`covers(S,X)`, source bound
first) — 40× faster than the obvious upward form on the real taxonomy, and the
truer reading of what an assertion does. Theory answers structure; the curator's
learner-facing note stays beside it, as in provenance-datalog ·
[`taxon-derive.rkt`](src/taxon-derive.rkt) its IO seam (the delta/delta-explain
idiom): lineages off the species mart via DuckDB, assertions off the checked-in
[`data/taxon-traits.rktd`](data/taxon-traits.rktd) (an input ARTIFACT, so a curator
edit reads as `'input-changed`), out to `species_reasoning.json`; refuses to publish
a conflicted result and cross-checks coverage against Bee-Gap ·
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
  that touches this is Horizon 2.) **One deliberate exception, ADR 0008 D5:** a
  `derivation` node runs a transform inside the engine, and what earns that is
  narrow — unbounded-depth closure with defeasible override and a native "why"
  (taxon reasoning, st-ozp). A bounded join or a bulk aggregation still goes to
  dbt/DuckDB; adding a second derivation needs the same argument made afresh.
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
- **Push only when asked** (global rule). Beads' default "mandatory
  push" session protocol does **not** apply here; the user drives
  pushes. `bd`'s local DB works fully offline.
<!-- END BEADS INTEGRATION -->
