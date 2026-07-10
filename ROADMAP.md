# Stelis — Roadmap

Planning horizons, so any proposed feature has an obvious home. Horizons are
ordered by dependency and risk, **not** by date. Everything past Horizon 0 is
provisional and expected to be reshaped by what Horizon 0 teaches. The test for
"which horizon does this belong in?" is: what must be true and working before
this feature can be built well?

See `DESIGN.md` for the rationale behind the commitments and deferrals referenced
here.

---

## Horizon 0 — Now (Phase 1)

*The coarse batch build. One working thing, end to end, on the simplest real case.*

- Racket build system over the `beeatlas` batch pipeline.
- Datalog as a **metadata** language about the build (deps, versions, staleness);
  transformations stay external.
- Target selection + up-to-date skipping.
- Input-addressed task caching; derived-vs-authoritative node types.
- Per-task hermetic runtime invocation (dual-interpreter case).
- Gates as first-class nodes; partial success; explicit output destinations.
- Streaming per-task logs.
- Determinism-testing harness (build twice, compare hashes).

**Exit condition:** `run.py`'s linear sequence retired for the `occurrences.db`
build; minimal-upstream rebuild proven reproducible.

## Horizon 1 — Next

*Make it explain itself, remember, and rebuild incrementally. Still batch, still
one repo, still linear time.*

- **Provenance, first-class:** "why did this rebuild / why is this stale?" as a
  queryable property. The build reasoning becomes inspectable.
- **Trace/graph persistence:** move state from in-memory to a database / log,
  using the representation Horizon 0 was designed to allow.
- **Incremental rebuild via early cutoff:** content-addressed outputs; stop
  propagation when a rebuild produces identical content.
- **Data-quality Datalog** as rule-sets that run *as nodes within* the build
  (duplicate sample IDs per collector-day, out-of-state samples, bee-vs-flower
  misclassification). This is the second Datalog application, now that build
  orchestration works.
- Broaden target coverage beyond the single `occurrences.db` path.

## Horizon 2 — Later

*Fold in change-over-time and cross the file/value boundary. This is where the
batch→streaming arc completes and the browser gets fed.*

- **Streaming / CRUD ingestion** — `salishsea`'s model: small frequent
  content-addressed snapshots at the ingestion boundary; near-real-time
  incorporation of API data into artifacts.
- **Delta-based propagation** (Z-sets / DBSP-shaped) where coarse over-rebuilding
  hurts; retraction-clean incremental maintenance.
- **Demand-directed evaluation** via magic sets, if/when goal-directedness is
  needed.
- **Compile-to-TS emission:** specialized projections compiled to small
  self-contained frontend modules — each a derived, content-addressed node in the
  build graph.
- **Differential-testing harness for emitted artifacts:** run the general
  interpreter and the specialized emission on the same inputs; compare.

## Horizon 3 — Speculative / deferred

*Named so features have a home, not scheduled. Each entry has a "why deferred" in
`DESIGN.md`.*

- **Non-linear time:** git-like branching and grafting of database-programs;
  distribution. The hard problem; everything else assumes it away.
- **Review / staleness workflow layer:** human and LLM review nodes; three-valued
  staleness (clean / dirty-rebuildable / suspect); doc-depends-on-source and
  similar semantic edges; LLM verification with human reconstruction. The ambition
  to make GitHub/issue-tracker-shaped coordination *fall out of* the dependency
  graph — while owning the cross-tool edges that currently live nowhere, **not**
  reimplementing those tools.
- **External engine integration:** reach for Feldera/DBSP for fine-grained
  incremental maintenance at scale.
- **Compile-to-Rust** for a specific hot path that matters and doesn't fit
  Feldera.
- **ASP** for genuine search/repair problems (e.g. minimal dataset corrections).
- **WASM** in-browser engine execution (platform-choice tripwire).
- **Rhombus** migration of selected modules.
- **Layer 2 breadth** (community collaboration features) and **Layer 3**
  (tooling/patterns library) generalized across `beeatlas`, `salishsea`, and
  beyond.

---

## Slotting rule of thumb

- Does it require change-over-time or streaming? → Horizon 2 at the earliest.
- Does it require branching/merging or non-linear time? → Horizon 3.
- Does it require provenance or persistence? → Horizon 1 at the earliest.
- Is it needed to retire `run.py` for one target, reproducibly? → Horizon 0.
- Is it a general-substrate feature with no user waiting on it? → it is probably
  premature; find the user first, or move it to Horizon 3 with a reason.
