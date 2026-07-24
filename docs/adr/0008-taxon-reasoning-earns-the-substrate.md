# ADR 0008 — Taxon reasoning earns the substrate's reasoning half; render-by-query stays deferred (st-650)

**Status:** accepted · **Horizon:** 2 (reasoning) / 3 (render-by-query) · **Date:** 2026-07-24

Resolves st-650: the exploration ADR 0007 leg (ii) required — a concrete value
prop that earns in the deferred sentential-Datalog substrate. **Editorial flags
do not earn it. Taxon reasoning — characterization by taxonomic inheritance and an
ecological at-risk closure, carrying learner-facing explanations — does, but only
the *reasoning* half.** Render-by-query (the 11ty replacement) stays deferred.

## Context

ADR 0007 deferred the substrate "until a concrete value prop earns it in,"
nominated editorial data-quality flags as the first candidate (st-650), and named
the failure mode building it without one would be: *substrate-for-its-own-sake*.
The gate this ADR settles st-650 against: **(a) does the work propagate recursively
over relational structure** — Datalog's differentiator over the DuckDB/dbt
external-transform stack — **and (b) does it need something that stack can't
cheaply give?**

- **Flags fail the gate.** ADR 0006's editorial examples — duplicate collector-day,
  out-of-state, bee-vs-flower — are per-record or per-cluster **leaf** predicates:
  a group-by-count, a spatial predicate, a classification. None propagate; none are
  more natural in Datalog than SQL. Confirmed with the author.

- **Taxon reasoning passes — but the analysis split it.** "All species within
  Nomadinae are cuckoos" is **inheritance down the taxonomic rank tree**:
  unbounded-depth transitive closure with most-specific-wins override — genuinely
  recursive and defeasible, awkward in a recursive CTE. The ecological chain
  (cuckoo → host bee → forage plant → "depends on that plant") is, by contrast, a
  **bounded 2-hop join** the dbt stack can already express. So Datalog's recursion
  earns on **characterization**; the at-risk chain *rides* it.

- **Data feasibility is already in beeatlas.** The edges exist as committed dbt
  data — `bee_specialist_hosts` (Fowler & Droege: the oligolege→plant-family forage
  edge, obligate-ness baked in) and `bee_parasite_hosts` (Bee-Gap: the
  cuckoo→host-bee parasitizes edge) — as do the characterizations (`species_traits`:
  diet_breadth, sociality, nesting) and the full rank tree (`species`
  subfamily/tribe/subgenus; `stg_inat__higher_rank_taxon_ids`). `species_traits`
  today does only a *one-level* genus backbone, not full inheritance.

- **The deciding factor is explanation, for learners.** The proof tree — *"a cuckoo,
  because it is in Nomadinae"; "imperilled if Clarkia declines, because its host
  Andrena is a Clarkia specialist"* — is published, end-user content. It is native
  to `provenance-datalog.rkt`'s why-projection and hand-rolled/fragile in dbt. The
  same machinery Stelis built for the *operator* `--why` is reused for *learners*;
  the audience flips, the engine does not.

## Decisions

1. **Flags are rejected as the value prop.** They remain external — an editorial
   flag set produced in dbt/DuckDB (ADR 0006), published as derived data. They earn
   no substrate. The dbt-vs-Stelis fork ADR 0006 left open is settled *toward dbt*
   for leaf predicates.

2. **Taxon reasoning is accepted as the value prop that earns the substrate's
   reasoning half.** Datalog rules over **mixed** authored + pipeline-derived facts,
   producing derived traits **and proof trees**, reusing `provenance-datalog.rkt`
   and the in-process `rule-check` node (`exec.rkt`). This is domain reasoning as a
   build node — the second consumer of the provenance engine after freshness/history.

3. **Hard boundary: reasoning earns now; render-by-query stays deferred.**
   Explanations are **computed at build time and baked** into the static site by
   the existing render (ADR 0007 Model Y). A precomputed proof surfaced on a page is
   *not* a request-time query, and needs none. Replacing 11ty with a query-backed
   renderer (ADR 0007 leg ii) is untouched by this prop and stays in Horizon 3.

4. **Characterization is the load-bearing base and lands first.** The at-risk
   closure is **typed over characterizations**: necessity propagates only through
   *obligate* edges, and "obligate" (oligolege vs polylege) *is* diet_breadth, a
   characterization. A naive untyped closure over-claims — it would make every
   generalist's cuckoo depend on every flower the generalist visits. Order:
   inheritance (st-ozp) → type the existing edges → at-risk closure.

5. **This deliberately crosses the "transformations stay external" line.**
   Computing derived traits by a Datalog *rule inside Stelis* is the Horizon 2
   substrate move, taken with eyes open. What earns Stelis-side is precisely
   **inheritance depth + defeasible override + native explanation**; anything that
   is a bounded join or a bulk aggregation stays external (ADR 0006 decision 4 —
   Datalog does relational logic, volume goes to DuckDB).

## Consequences

- st-650 is closed with this verdict. The beachhead st-ozp (taxon trait inheritance
  with provenance) is opened; typing the edges and the at-risk closure follow and
  depend on it.
- **A standing gate for any future substrate bid** falls out and should be applied
  to the next candidate too: *does it propagate recursively over relational
  structure, and does it need a native "why"?* Absent both, it stays external and
  the substrate stays deferred. This is the reusable output of the exploration,
  beyond the taxon feature itself.
- `provenance-datalog.rkt` gains a domain-reasoning consumer; its why-projection
  becomes learner-facing published content. No change to freshness or `cache.rkt`
  (ADR 0001/0003/0005): domain reasoning is a build-time derivation that *produces*
  published data — it does not read the observation history to decide staleness.
- **Render-by-query is not resurrected.** Horizon 3's substrate entry keeps its
  deferral; only its "first candidate" line is resolved (flags: no).
- Open forks, deferred to st-ozp's design pass: where the high-rank assertions live
  (curated checked-in config vs a forward-only authored store — start with config,
  no authoring UI); closed-world default vs explicit negative assertions (defeasible
  override is only needed if assertions conflict along a lineage — decide from the
  real cuckoo taxonomy); and how a proof tree renders to learner prose.
