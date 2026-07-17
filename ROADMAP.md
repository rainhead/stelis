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

## Horizon 1 — Delivered (2026-07-16)

*Make it explain itself, remember, and rebuild incrementally. Still batch, still
one repo, still linear time.*

- ✓ **Provenance, first-class:** `--why` / `--explain`; staleness and blame as
  Datalog (`provenance-datalog.rkt`). The build reasoning is inspectable.
- ✓ **Trace/graph persistence:** an append-only observation history under
  `.stelis/` (`history.rkt`) — per-build records with per-key (`'dir`) and
  per-column (`'db-relation`) granularity, once-per-topology graph snapshots, a
  `--history` browser, and a Datalog projection. Freshness stays content-hash +
  graph, never the sequence (ADR 0005).
- ✓ **Incremental rebuild via early cutoff:** content-addressed outputs; stop
  propagation when a rebuild produces identical content (ADR 0003).
- ✓ **Data-quality rules as build nodes:** in-process rule nodes (`exec.rkt`'s
  `rule-check`), with the record-count **integrity gate** as the first rule
  (`data-quality.rkt`, ADR 0006). The *editorial* half — flags for end users — is
  *published derived data*, so it moved to Horizon 2 (see below).
- ✓ **Broaden target coverage:** every terminal deliverable — not just
  `occurrences.db` — now plans, builds, and verifies byte-identical.

**Exit condition (met):** the build explains itself, remembers its observations
across builds, and cuts off propagation on unchanged content — proven across all
`beeatlas` targets. Horizon 2's substrate (the observation history) is built; the
engine is host-portable (`BEEATLAS_DIR` / `NOTES_DB_PATH`).

## Horizon 2 — Now

*Fold in change-over-time and cross the file/value boundary. This is where the
batch→streaming arc completes and the browser gets fed.*

- **Serve from the build host (ADR 0007)** — the active arc: the 11ty render
  becomes a Stelis `site` task (st-ak1); beeatlas.net moves to an Apache vhost
  on maderas serving a directory Stelis owns, retiring S3/CloudFront from
  serving (st-bgy); a note write commits, then synchronously rebuilds the site
  before responding — reload-sees-it as a build property (st-nee); post-soak
  teardown deletes the `/api/notes` kludge and the AWS serving stack (st-vjd).
  The measured write-path latency is the forcing function that prices any
  targeted-render work.
- **Streaming / CRUD ingestion** — `salishsea`'s model: small frequent
  content-addressed snapshots at the ingestion boundary; near-real-time
  incorporation of API data into artifacts.
- **Delta-based propagation** (Z-sets / DBSP-shaped) where coarse over-rebuilding
  hurts; retraction-clean incremental maintenance. The H1 observation history
  (content + basis per output, plus per-key/per-column granularity) is the
  substrate this folds over — the natural entry point into this horizon (st-066).
- **Editorial data-quality flags** (moved from H1): rules that flag records for
  end **users** (dup collector-day, out-of-state, bee-vs-flower) and travel with
  the data into published outputs — they annotate, never block (ADR 0006). Deferred
  here because end-user-facing flags are *published derived data*, which reopens
  the "transformations stay external" line — a dbt-vs-Stelis fork to settle first.
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

- **Sentential-Datalog render substrate** (the server pivot's deferred half,
  ADR 0007): pages rendered by querying a fact database, replacing 11ty. Why
  deferred: required by nothing shipped so far — it must re-enter through a
  concrete value prop a near-term Stelis would serve. First candidate under
  exploration: editorial data-quality flags (st-650).
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
