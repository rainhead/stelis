# ADR 0006 — Data quality: flags vs gates, and rules as nodes (st-0vz)

**Status:** accepted · **Horizon:** 1 · **Date:** 2026-07-16

Decides that two concerns loosely called "data quality" have **opposite**
semantics and must be kept apart: *editorial* issues **flag** records for end
users and never block; *integrity* anomalies **block** the build for operators.
Establishes the in-process rule-node modality both will run on, and records where
Datalog stops and DuckDB/Racket start. Surfaced while designing st-0vz.

## Context

The roadmap's H1 item was "data-quality Datalog rule-sets that run as nodes within
the build, with gate semantics." Its examples — duplicate collector-day records
(a **beeatlas** concern; pnwmoths/salishsea have no collectors), out-of-state
samples, bee-vs-flower misclassification — are all *editorial*: curatorial facts
about the data's content, for the people who **consume** the published data. But
"gate semantics" (block the build) fits a *different* concern entirely: pipeline
integrity — a source broke, a join exploded or collapsed — which the operator
must not publish past. One framing had conflated them.

The distinguishing test is **who the problem is for**:

|                | Editorial (content)        | Integrity (pipeline)          |
|----------------|----------------------------|-------------------------------|
| examples       | dup collector-day, bee-vs-flower | record count craters vs. last build |
| audience       | **end users** of the data  | **operators** of the build    |
| action         | **flag** the record, publish it | **block** the build      |
| defined over   | the *current* data         | *this build vs. the previous* |

Integrity is inherently **history-relative** ("a huge difference *vs. last time*"),
which makes it the second present-tense consumer of the st-sds observation history
(after st-066) — its inputs are the per-relation row counts that history records.

A count-delta is also **arithmetic**, and the `datalog` package is pure Datalog
with no arithmetic — so the integrity rule's logic is Racket, not a theory. The
reusable investment is the *rule-as-node* mechanism, not this particular rule.

## Decisions

1. **Two concerns, kept apart.** *Editorial* checks produce a **flag set**
   (record → violation) that travels with the data into published outputs and
   **never blocks**. *Integrity* checks **block** the build (gate semantics,
   st-d44.4) before the data is published. A node is one or the other, never both.

2. **Integrity gates are history-relative, and that's not a freshness verdict.**
   A gate compares this build's observed metric to the previous build's. It
   consults the build **sequence** — legitimately, because it's an operator
   *anomaly alarm*, exactly the browsing/operator use ADR 0005 carves out for the
   sequence. Freshness stays content-hash + graph, clockless; the two never mix.

3. **Rules run as first-class in-process nodes.** A rule's body is evaluated in
   Racket as a graph node (`exec.rkt`'s `rule-check`), gating its downstream via
   the ordinary partial-success flow — no subprocess. This is the reusable modality
   the whole data-quality line needs; the integrity gate is its first instance.

4. **Datalog does relational logic; volume goes to DuckDB, arithmetic to Racket.**
   The established idiom (provenance-datalog.rkt) holds: Racket computes primitive
   facts and asserts them, pure Datalog does the relational closure. Data-volume
   operations (scans, aggregations) push into DuckDB; small-set arithmetic stays in
   Racket. The integrity gate embodies it — `count(*)` in DuckDB, the threshold
   compare in Racket. Expressing a rule that is *both* SQL-aggregation-at-scale and
   relational-Datalog as one node is left open (see below).

5. **A no-baseline first build passes; degrade, don't halt.** With no prior
   observation there is nothing to compare, so the gate passes (an anomaly can't be
   detected against nothing, and a blocked first build would be un-bootstrappable).
   An unreadable *current* metric also passes, with a warning — consistent with the
   `#f`-on-absence contract (duckdb.rkt); a transient infra read should not halt a
   pipeline whose producing loader already succeeded.

## Consequences

- st-8v3 is rescoped to **editorial flags only** and deferred to a later horizon;
  the **integrity gate** split out as st-0vz and shipped (record-count swing vs.
  history blocks publish; wired as `inat-obs-integrity` before `dbt-build`).
- The in-process `rule-check` modality is now available for every future
  data-quality rule; editorial flags reuse it verbatim.
- Editorial flags are *published derived data*, which reopens the "transformations
  stay external through Horizon 1" guardrail — whether that logic lives in
  Stelis-Datalog or a dbt model is an **open fork**, deliberately not decided here;
  it wants its own design pass before any editorial code.
- Open, later-horizon: per-relation threshold policy (only a global default today),
  and the unified expression of a half-SQL-aggregation, half-Datalog rule as one
  node.
- No change to freshness or `cache.rkt` (ADR 0001/0003/0005): a gate reads history
  to decide *whether to block*, never to decide *staleness*.
