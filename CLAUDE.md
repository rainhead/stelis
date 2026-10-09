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
  gate, and full target coverage all shipped and verified. Horizon 2 is open.
- **The pull is data modeling, not build features (2026-08-03).** The build detour
  has paid out — see `DESIGN.md`, "The detour has paid out". Two things are active:
  **`st-hdm`'s per-page provenance**, which closes out the build work, and the
  **taxon reasoning arc** (type the host/parasite edges over the inherited traits,
  then the at-risk closure — ADR 0008), which is the data-modeling line. The rest of
  Horizon 2 — delta propagation, streaming/CRUD ingestion, compile-to-TS emission,
  demand-directed evaluation — is **recorded, not queued**: it waits for something
  in the data work to need it.
- So the first question about any proposed build feature is **which data question
  does it answer** (ROADMAP's slotting rule). If a request would build one with no
  such question behind it, say so rather than building it — and if the user asks
  anyway, that IS the pull; build it.

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

Toolchain: **Racket v9.3 CS** (on `PATH` at `/Applications/Racket v9.3`). Core is
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
  `--render-log` (the history as ONE self-contained HTML page under the state
  dir — the operator build log, st-9rf; also refreshed after every `--build`) ·
  `--mark-publish <build> <epoch> <outcome> <stage> <path>` (a publish path
  reporting back whether that build's data went LIVE — appends a receipt joined
  by build number AND epoch, refuses a mismatch or double-mark, re-renders the
  log; `--last-build` prints `<number> <epoch>` so the caller can capture which
  build is ITS, st-8x1) ·
  `--moved-keys <artifact>` (which keys moved in the LAST build, machine-readable —
  bare keys on stdout, everything else on stderr; exit 1 = no basis, rebuild in full) ·
  `--run <task>` (execute one task in its hermetic runtime) ·
  `--downstream <task>` (with `--build`/`--commands`/`--explain`/`--why`: scope the
  plan to TASK and the tasks that transitively consume its outputs — what a change
  to its outputs can move. salishsea's save-triggered build is `--all --downstream
  snapshot`: the store re-read and everything derived from it, 13 tasks, leaving the
  three ingests to their five-minute schedule (salish-9uu.6). Unlike `--from`, which
  is the plan's positional SUFFIX from a task on — beeatlas's notes CRUD — and would
  have kept the two ingests ordered after the snapshot) ·
  `--build --all --export-dir <dir>` (build EVERY target into `<dir>` — the run.py
  replacement: covers all of run.py's steps, but content-addressed-skips current
  work and is partial-success rather than fail-fast). Every task's status is
  followed by a `⏱` line — how long the engine spent DECIDING (addressing its
  inputs), RUNNING it, and OBSERVING its outputs — and the build ends with the
  bookkeeping after the last task and the CPU it took, engine and tasks apart:
  on a shared CPU that, not wall time, is what a build costs. Status lines are
  flushed as written, so a log's timestamps are the engine's, not the next task's.
  `--verify-edges` (POST-BUILD: re-run each covered task in an EXPORT_DIR seeded
  with ONLY its declared inputs — are they sufficient, and are the declared outputs
  complete? And did it WRITE to any input it declares, seeded or fixed-path
  (hashed before and after — read-only, so the ambient ones are in reach too;
  st-8vm, the beeatlas-hyq rename-over-own-input)? The only check that asks whether the graph is TRUE rather than merely
  coherent, st-8an. Needs a reference build to seed from; exits non-zero on a bad
  edge OR an incomplete reference, and names the tasks it does not cover rather
  than presenting a curated subset as coverage) ·
  `--trace-reads <task>` (the OTHER half of that question, st-25h: run the task
  normally under a read probe and classify every file it actually opened against
  its declared edge. --verify-edges asks by WITHHOLDING, which structurally cannot
  reach the fixed-path inputs — the sandbox, the seeds, committed content —
  because withholding those would mean mutating real files; this asks by
  OBSERVATION, so nothing is withheld. Exits non-zero on an undeclared read).
- **Projects:** every mode takes `--project <name>` (`beeatlas`, the default, or
  `salishsea`), placed before the target. Only the chosen project's module is
  loaded (st-5jg: beeatlas's closure is ~40 MB of resident code salishsea never
  uses); main.rkt's `compile-deps` submodule is what keeps `raco make src/main.rkt`
  compiling both, so don't remove it as dead. Each project has its own state dir, and
  build records name their project: a state dir holding another project's builds
  is refused rather than read across (st-z1c). salishsea's state defaults into its
  own checkout; beeatlas's stays cwd-relative `.stelis` (st-7f4).
- **Which database:** every banner names the DuckDB the answers are about, and
  whether an env var chose it or it is the fallback. beeatlas's is STRICT
  (st-az9): `--build`/`--run`/`--trace-reads`/`--verify`/`--verify-edges` refuse
  when `DB_PATH` is unset and the checkout copy exists, so a local build says
  `DB_PATH=~/dev/beeatlas/data/beeatlas.duckdb` out loud. Its nightly once gated
  against that stale copy while the pipeline read the serving one. Every
  project's executing modes also refuse a RELATIVE database path (st-hs7): the
  engine resolves it from its cwd, the tasks from theirs, so it names two files.
- **Test:** `raco test src/*-test.rkt`.

Layout: [`model.rkt`](src/model.rkt) bipartite graph model + plain-Racket planner
(with the graph's own integrity checks: `build-graph` refuses an edge naming an
artifact nobody declared — st-5e6, a typo there otherwise reads as a leaf and the
edge silently vanishes — `make-artifact` refuses a kind or provenance outside the
closed vocabulary, and `check-graph-leaves` (st-zb9) refuses a graph whose leaf
declarations disagree with its topology. All three run inside `build-graph`, which
is the only way to construct a graph, so no graph can skip them by forgetting —
unlike main.rkt's `check-partial-tasks` / `check-dir-extents`, which stay there
because neither is pure over the graph alone),
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
declared input change, which is a wrong skip. A sibling is named for its source's
CONTENT hash, so a `compressed/` the publish path did not just rebuild is not found
and the publish falls back — without that, `publish-notes.sh` (which never runs this
node) would ship yesterday's db under today's immutable URL. Both node tasks also
hash `.nvmrc` as code (`node-runtime-code`) — the interpreter is an input to the
BYTES: gzip -9 of the same db is 5,208,681 under node 24.18 and 5,203,283 under 26.
`.nvmrc` states INTENT; the RESOLVED interpreter is observed too (st-jkl): the
`node` runtime declares an identity probe (`node --version` through its own launch
prefix, nvm sourcing and all), whose answer rides each node task's input address
as `"runtime:node"` — a patch bump inside the range, or a no-nvm host's PATH
fallback, reads as `code-changed` naming it. Observation only, never a version
gate; probe failure = conservative forced run. uv and dbt are probed too
(st-kbi): uv via a STANDALONE probe (`uv run --no-sync … python -VV` — the
launch prefix SYNCS the venv, which planning must never trigger, and the safety
flag goes mid-launch where an appended probe can't reach; `standalone-probe` in
model.rkt is the declared shape for exactly this), dbt via run.sh's `--identity`
branch (uvx `--offline`, cache-only — cold cache fails the probe, conservative
run; observes ONLY what run.sh's exact pins leave free, the CPython patch and
the floating transitive duckdb engine — never `dbt --version`, whose "latest:
X" moves on upstream releases). uv INTENT rides as `uv-runtime-code`
(pyproject/uv.lock/.python-version on every uv recipe): the venv only moves
when a launch syncs it, so an un-hashed pin edit would rerun nothing and sit
unapplied forever — intent triggers the change, reality addresses it ·
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
name WHY the boundary didn't re-ingest (the loader-side probe is beeatlas-29j).
A task the project lists as incremental (`#:incremental-tasks`, ADR 0015) is handed
`STELIS_CHANGED_INPUTS` — the inputs whose address moved, newline-separated — when
its decision was `'input-changed` AND its recorded outputs are intact
(`recorded-outputs-intact?`: present, and digesting to the last clean run's
receipt), so it may recompute only the partition that reads them and replace it in
place; any other reason to run, or a missing or stale output, is a full recompute
and the task is told nothing. A hint like `STELIS_REBUILD_KEYS`: a task that ignores
it recomputes whole and is as correct. salishsea's occurrences derivation takes it (a
save is the store's tables, so the native arm alone); the candidates and profile
links read `build.occurrences` as one input, so for them the fact has to arrive per
key (st-6d2.2).
A loader that could NOT reach its source and kept its last good copy writes
`{unreachable: true, error}` instead (st-ml9.9) — the third arm, so an outage
reads as "source unreachable" in the trace and the operator log rather than as
a quiet day; it is still a clean run, since the mirror is what the loader chose
to publish. A loader that reached its source and REFUSED what it offered by its
own rule writes `{refused: true, error}` (st-8wt) — the fourth arm, so a
curator's decision (salishsea's ingest-register refusing a register edition that
would un-name Maplify sightings) reads as a refusal, not as the outage its error
text contradicted ·
[`cache.rkt`](src/cache.rkt)
input-addressed skip decisions + early-cutoff output receipts; a gate TOKEN is
addressed by its gate's recorded input address (st-ysf), so dbt-build can skip; a
file a task declares as a DATA input is addressed as data only, even inside a code
directory its recipe expands (st-6w9: a seed another task writes would otherwise
read as a hand edit, `'code-changed`) ·
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
`relation-row-count`, st-7vz/st-0vz); `make-relation-observer` (st-ml9.6) answers
both for every relation of one database in two DuckDB launches instead of ~four per
relation, byte-identical (it falls back to per-relation launches SILENTLY when the
batch fails — an unquoted reserved-word column did that on every salishsea build from
2026-10-04 to 10-05, so column names are always quoted now; rows hash with DuckDB's
`hash()` since st-0gc), holding each answer until a task writes a relation that
shares a table with it — salishsea's resolvers use it (beeatlas's don't yet). A
batch leaves out relations the caller marks `#:pending?` — salishsea: produced by a
'boundary that has not yet written them this process (st-3jv) — because the first
relation question of a build came before the snapshot boundary ran and digested its
~25 relations only for the snapshot to rewrite them; a pending relation asked about
directly is observed, with its pending siblings. And cache.rkt's `decide` asks its
stale-output question LAZILY (a thunk): only a task every content reason has passed
pays for the relation digests and tree hashes it is.
A relation may live in a SQLite file (`sqlite-db`, st-ml9): the file is
ATTACHed read-only into a transient DuckDB and digested the same row-coherent
way, which is how salishsea's mirrors are inputs without a second digest. A
relation the project declares KEYED (`relation-keys`, ADR 0016) is observed per
key — rows grouped by a SQL expression, each group digested and counted, the shape
a keyed store has — IN PLACE of its per-column parts (cache.rkt's
`artifact-key-parts` asks the project's `resolve-store-keys` first), so a fan-out
'dir `store-keyed` on it rebuilds per key: salishsea's `build.occurrences` by
Pacific day, and `occurrence-days` a partial task writing only the moved days ·
[`written.rkt`](src/written.rkt) which artifacts a task has written in this
process: `run-task` (and a derivation) notes its declared outputs when it finishes,
so a cached observation is keyed by the artifact's write generation — the same
trust in declared outputs the skip decision already places ·
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
itself. CHUNKED (st-ml9.7): a map of more than 256 entries is a TREE of blocks — a
node maps the next byte of each key's sha256 to its bucket's CID — and the digest is
the root's CID, so one changed key rewrites a root and one bucket, not the whole map
(salishsea's 4,398-key days/ map: 45 MB of history over 178 changes became 2.4 MB). A
map of 256 or fewer is the flat block it always was, same CID. A node is the array
`["stelis/keyed-node/1", {bucket → CID}]` and a leaf always a map, so the two are
told apart by shape, not by what a leaf's values are. The layout is our own (IPFS
HAMT-style hash sharding, atproto-style DRISL + CID links, neither's spec;
ADR 0014). Applies to `'dir` and the keyed notes store; a **db-relation is deliberately
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
st-243; salishsea's days/, ADR 0016) gates IDENTITY vs. the store keyset — both
strays and gaps fail. run-plan runs that check after every clean run of the dir's
producer (ADR 0016 D7): after a PARTIAL run a mismatch fails the task, after a full
run it is reported. And a partial task's delta is taken against the map its cache
entry says it last consumed (`history-key-observation-at`, D6), never the input's
newest map — the two differ when the producer ran and the consumer failed ·
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
(ADR 0005). RETENTION (st-ml9.7): a project may keep only recent history
(`#:history-retention`; salishsea 30 days, beeatlas all). Each line records when it
was written — the file's one clock, housekeeping only — and `history-prune!` drops
the aged-out PREFIX, then deletes the blocks no remaining line names. It prunes in
BATCHES (once the oldest build is a thirtieth of the retention past it, so about
daily), because a prune rewrites and re-reads the whole log; the check for whether
one is due reads only the oldest dated line. NOTHING reads the whole log into
memory any more (st-6gv): Racket holds a string at four bytes a character and
salishsea's log at retention is ~200 MB on a 1 GB machine. Each line carries its
build NUMBER (assigned at append from the line before; a line from before that is
numbered from its neighbours), so a reader working back from the end knows a
build's number without counting, and every mode reads from the end to what it
needs — `history-last` / `history-find` / `history-tail` (the last k builds plus
each keyed artifact's latest earlier map, the build log's basis), the newest N
points of a per-key timeline (`#:last`, two for `--moved-keys`, one for a gate's
baseline) — or folds over it one build at a time (`history-fold`, `history-key-fold`;
`--history` and `--history <artifact>` print as they go). The one whole-timeline
reader left is key-blame's. salishsea also skips the build-log render after each
build (`#:build-log-after-build? #f`; nothing publishes it, `--render-log` draws it). The count dropped is a header line, so every survivor keeps its NUMBER
(`build-record-number`; publish receipts join on number + epoch), and answers that
reach the horizon say where the record starts ·
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
[`taxon-edges.rkt`](src/taxon-edges.rkt) edge TYPING, the arc's step 2 (st-an7,
pure core; the ratified design lives in that bead's design field): the
bee_parasite_hosts / bee_specialist_hosts seeds typed obligate WITH provenance +
grounding, so the at-risk closure (st-6x9) can propagate necessity through
obligate edges only (ADR 0008 D4). Parasite edges type via the bee's INHERITED
cleptoparasitic characterization (proof = the chain; a parasite no assertion
reaches keeps a distinct source-only proof), grouped per parasite as ONE
dependence on the host SET — ungrouped, the closure would claim imperilled-if-
one-of-five-declines. Forage: Fowler is specialists-only, so membership IS the
claim (no generalist edges exist — D4's over-claim dies structurally), and the
'disputed flag reads Bee-Gap's INDEPENDENT foraging seed, never the mart's
diet_breadth, which already merges Fowler in and can only ever agree.
Out-of-atlas hosts are KEPT, marked — dropping them would make silence look
like safety. NOT a second derivation: a post-pass inside taxon-reasoning
consuming its own closure (D5 needs no fresh argument), emitting the sibling
`species_dependencies.json` keyed by depending species ·
[`taxon-risk.rkt`](src/taxon-risk.rkt) the at-risk CLOSURE, the arc's payoff
(st-6x9, ADR 0008 step 3): strict "imperilled if X declines" facts over the
typed edges, proof trees and learner-facing sentences included. The one rule:
a typed dependence is ANY-OF, so necessity holds only where every any-of node
COLLAPSES — a singleton plant set (plant grain), a family-uniform set (family
grain; a family-less Fowler row blocks the claim — unknown is not uniform),
and through hosts only when EVERY host is grounded AND needs the same target
(the forall, materialized as one via per host). Anything looser is D4's
over-claim; the broader exposure surface is not derived because it is already
published — hosts are keys in the same artifact, so the site can walk the
chain without a fact vouching for more than the data says. The 'disputed flag
COMPOSES up the chain. Deliberately NOT the datalog library: necessity through
an any-of set is a FORALL, and positive reachability would derive exactly the
over-claim — a monotone fixpoint in plain Racket, unbounded depth intact
(host-of-a-host resolves next round). On today's data: 147 base facts, 0
derived — the one candidate chain (stelis montana → three Osmia) fails the
forall on a generalist host, the any-of semantics doing its job ·
[`taxon-derive.rkt`](src/taxon-derive.rkt) its IO seam (the delta/delta-explain
idiom): lineages off the species mart via DuckDB, assertions off the checked-in
[`data/taxon-traits.rktd`](data/taxon-traits.rktd) (an input ARTIFACT, so a curator
edit reads as `'input-changed`), the edge seeds + independent foraging read the
same way, out to `species_reasoning.json` + `species_dependencies.json`; refuses
to publish a conflicted result and cross-checks coverage against Bee-Gap ·
[`provenance-datalog.rkt`](src/provenance-datalog.rkt) staleness as Datalog rules,
plus the history projection (observed/ran/derived-from facts) ·
[`edge-verify.rkt`](src/edge-verify.rkt) checks a task's declared edge against
runtime reality (declared inputs sufficient? outputs complete? inputs left
unwritten?) ·
[`read-trace.rkt`](src/read-trace.rkt) + [`src/probe/`](src/probe/) the same
question asked by OBSERVATION rather than withholding (st-25h). The probe is a
`sitecustomize.py` prepended to PYTHONPATH, so `site` loads it before any task
code and it inherits into every Python subprocess — dbt included, dbt being
Python too. TWO mechanisms, because neither covers the other: `open` audit events
give DATA reads, and a `sys.modules` sweep at exit gives CODE reads. The audit
events cannot do the second — with a warm `__pycache__` the `.py` is NEVER
opened, only the `.pyc`, and the `import` event carries no path at all — so
recording what was opened would name the wrong file. Classification is against
the GRAPH: declared / own-output / code / undeclared (the finding) / foreign,
where the interesting-vs-foreign filter is DERIVED from the roots the graph
already names rather than hand-kept, so a new producer widens it automatically
(the dir-extent.rkt move). The two directions are NOT symmetric: an undeclared
read is a strong signal, an unread declaration is weak (a data-dependent branch
makes one run a lower bound), and the report keeps them apart. A WRITE is not a
read: the probe records the open mode, and an undeclared write is reported in its
own section and left OUT of the exit verdict — calling it a dependency would be
false. `--verify-edges` asks about outputs only under EXPORT_DIR, so a FIXED-path
write is visible nowhere but here (st-6w9: inactive-remap's dbt seed
auto_synonyms.csv, found this way). KNOWN BLIND SPOT,
stated in every report rather than left to be discovered: a read inside a C
extension is invisible — duckdb reading a parquet file emits nothing — so the
relation-grain half needs its own instrument (st-25h step 1b). Tracing is
invisible to what it observes: the log is written OUTSIDE EXPORT_DIR, whose
contents are content-addressed ·
[`build-log.rkt`](src/build-log.rkt) the operator build log (st-9rf, first probe
of visual output modes): the history rendered as ONE self-contained HTML page.
An ENGINE surface, not site content — Model Y untouched, beeatlas's 11ty never
learns of it — and NOT a graph node: written AFTER the build from the completed
records (the way the history log line is), so build N's page describes build N
and the apparent "page about the build, produced by the build" recursion never
arises. It loads `history-tail` (only the shown builds, plus the older build
holding each artifact's map just before them, a delta's basis): a full load decoded
every build's maps, 528 MB on salishsea's Fly machine at 370 builds. Pure function of the loaded build-records — same history, same bytes;
its own stamp is the last build's SOURCE epoch, never wall clock — with absolute
local paths relativized through caller-supplied rewrites before the page sits at
a public URL (beeatlas.net/build-log.html: nightly.sh's EXIT trap copies it even
when a gate aborts the publish — a failed build is what the page is FOR — and
merge-swap.sh excludes it from the pages rsync's --delete, one more entry in
that hand-kept extent list, st-s8i's lesson). Caps reported, never silent.
PUBLISH RECEIPTS (st-8x1): the page also says whether each build's data went
LIVE — the engine cannot know (the publish decision is downstream, in the
nightly / note-write scripts), so those paths report BACK via `--mark-publish`
into an append-only publish.log beside the history (history.rkt owns the
format). A receipt names its build POSITIVELY — number AND that build's source
epoch — because the number is a live index, not an identity (a HISTORY-VERSION
bump renumbers survivors); the caller proves the tail is ITS build by matching
the epoch it exported, `--mark-publish` refuses mismatches and double-marks,
and the render joins on both, dropping mismatches to absence. No receipt
renders NOTHING (dev builds, pre-feature builds — silence over accusation);
outcomes carry a STAGE so "site-root-absent, expected on a fresh host" never
reads like "integration-gate", the alarm. One self-reported bit — the first
deliberate step into st-s8i territory, no destination observation ·
[`project.rkt`](src/project.rkt) a PROJECT as one value (st-ml9.1): a graph plus
everything the CLI needs to build it — path resolver, runtimes, relation
resolvers, build clock, checkout, default state dir, the databases it reads
(`db-binding`: env var, fallback, and whether the fallback is refused). main.rkt is written against
it, so a second graph is a second value, not a second CLI ·
[`salishsea.rkt`](src/salishsea.rkt) the second project (st-ml9): salishsea.io's
logged-out reads as static files — and since salishsea's decision 061
(salish-xv35, 2026-10) the ingest and the derivation too. Three `'boundary`
tasks fetch the upstream sources themselves, each into a SQLite mirror on the
volume holding ONLY what the source said (Maplify over a 30-day window plus one
sampled older month; iNaturalist by `updated_since` plus a reconciled window;
Orcasound whole), each writing its boundary receipt — including the
`unreachable` arm, so an outage never reads as a quiet day. A fourth boundary
snapshots what Postgres still holds (native sightings, the register, the
catalogue, Happywhale frozen, and its own Maplify copy while that ingest runs)
into a local DuckDB file (rows serialized by Postgres's `to_jsonb`, PostgREST's
own serializer, so the files match what the frontend parses). `derive-occurrences`
and `derive-profile-links` are DuckDB twins of Postgres's views over the mirrors
and the snapshot, writing `build.*` relations into the snapshot file; every
published file reads those. Before the derivation sits the `maplify-names`
gate: a register edition that un-names a Maplify sighting would silently drop
it from the map, so the gate judges this build's resolution against the LAST
PASSING build's, kept in `maplify-names.json` beside the mirrors — a declared
`'authoritative` output, forward-only, the one state the build owns that
cannot be regenerated. `dwca` writes the Darwin Core archive from twins of the
`dwc` views. The reference tables — providers, organizations,
collections, Maplify's collection rules, the enum orders — are not read from Postgres:
they are checked-in files under salishsea's `data/reference/`, producerless
`'authoritative` inputs that a `reference` task loads into the snapshot file under the
same names (salishsea decision 064, the first move of its step 4). The register
too: an `ingest-register` boundary fetches its newest release each build (one
redirect probe; a download only when the tag moved), writes `register.*` into the
snapshot file, and refuses an edition that would un-name a Maplify pair the held
edition names — the build keeps what it holds and the run log says why. And the
catalogue's three views over the register (`group_parents`, `matriline_members`,
`animal_names`) are a `derive-catalogue` transform's, written under the snapshot's
names the pages read (salish-9uu.2.3); and the catalogue's own tables are
checked-in files under salishsea's `data/catalogue/`, loaded by a `catalogue` task
that computes what Postgres derived (folded codes; each individual's vitals from
`register.vitals` and `register.current_status`). Happywhale's frozen tables are a
producerless `'upstream` file on the volume (`mirrors/happywhale.duckdb`, kept off the
public repository), loaded by a `happywhale` task (salish-9uu.2.4). The snapshot now
reads only what users write. A transform writes one file per Pacific day. The snapshot reruns
every build; an unchanged database digests the same, and early cutoff skips
the rest. It also records when it was
taken (`snapshot-meta`, its own relation so the occurrences' digest holds still),
and a `manifest` task writes `manifest.json` from that AFTER the day files and the
calendar's month files (`calendar`, per-region day counts; its code includes
salishsea's `src/constants.ts` and `src/extents.ts`, the map's own region boxes)
and the id index (`ids`, id → day in 256 shards by a hash salishsea's browser code
shares, so a `?o=` link opens without a query) and the profile pages
(`individual-pages`, `matriline-pages`, `ecotype-pages`, `haulout-pages`, salishsea decision 057:
prerendered HTML, one task per kind reading only its own catalogue relations, with
the Vite-built shell and Vite's manifest hashed as code because the site build that
writes `dist/` is outside the graph) and `profile-index` (`redirects.json`, folded
designation → canonical page, which a redirect server on Fly answers legacy links
from, `sitemap.xml`, and `animal-names.json`, the register's names the report
form reads now that the map asks no database; no snapshot-meta input, so it
cuts off) —
every export an input for order only — so the frontend can tell a quiet day from one
no build has reached. Scripts live in salishsea's
`scripts/read-path/`; `SALISHSEA_DIR` relocates the checkout and
`SALISHSEA_SNAPSHOT_DB` the snapshot (on Fly, onto the volume) ·
[`main.rkt`](src/main.rkt) CLI · `src/*-test.rkt` tests ·
[`docs/adr/`](docs/adr/) decisions.

salishsea's tasks run at its `.nvmrc` node, in its checkout; the snapshot reads
`SUPABASE_DB_URL` from the caller's environment and never prints it.

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
- **Provenance says where an artifact comes from — three values, and it is
  checked** (ADR 0013). `derived` = safe to destroy and rebuild, and **must have a
  producer**; `authoritative` = forward-only, **never rebuild it from scratch**
  (migrations only), and it **may or may not** have a producer — a task may write
  forward-only state, and so may a writer outside the graph; `upstream` = somebody
  else's data snapshotted in, not ours to migrate either, and it **must not** have
  a producer. `build-graph` rejects any disagreement with the topology and
  `make-artifact` rejects a value outside the vocabulary.
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
  `bd remember` — the two don't overlap.
- **Push beads regularly, without asking** (2026-08-16). `bd dolt push` replicates
  the Dolt data plane to `refs/dolt/data` on this repo's GitHub remote; it never
  touches `refs/heads/main`. Push after filing or closing issues and before ending
  a session — un-pushed beads live only in `.beads/embeddeddolt/` on one machine.
  This is the **one** exception to the global "push only when asked" rule, which
  still governs `git push` of code.
<!-- END BEADS INTEGRATION -->
