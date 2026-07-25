# ADR 0009 — Corrections outrank their sources; the pin is a citation, not a gate (st-t4t)

**Status:** accepted · **Horizon:** 1 (mechanism) / 2 (authoring) · **Date:** 2026-07-25

ADR 0006 split "data quality" in two by asking *who the problem is for*: editorial
**flags** annotate a record for end users and never block; integrity **gates**
block the build for operators. A **correction** is neither — it *changes a
published value*. This ADR admits it as the third modality and keeps the override
itself **external** (a dbt seed and a precedence arm) per ADR 0008's standing gate.

It also settles what a correction *is*: **an assertion that outranks a source, not
a patch applied to one.** If a taxonomist says *Bombus vosnesenskii* is social,
that is the claim; Bee-Gap disagreeing is a fact about Bee-Gap. The
`expected_upstream` column each correction carries is therefore a **citation** —
the claim being overruled, recorded — rather than a tripwire, and the Stelis node
that reads it is a **report** that blocks only in the narrow cases where a build
can still prevent something wrong.

## Context

The occasion was a real error, not a hypothetical. USGS Bee-Gap records *Bombus
vosnesenskii* as parasitic; it is a common eusocial, ground-nesting bumble bee,
and the record was confirmed wrong **at the source** (st-4z8) — beeatlas's
ingestion is faithful. The error was *found* for free: st-ozp's taxon inheritance
cross-checks derived cuckoo status against Bee-Gap and reports the disagreement on
every build. But detection without a remedy just reprints the same complaint
nightly. There was no way to override a value a source gets wrong.

**Neither existing modality fits.** A flag would leave the wrong value published
with a note beside it — unacceptable when we *know* the right answer, or at least
know the published one is false. A gate would block the build forever, since the
upstream error is not going to fix itself on our schedule. Extending ADR 0006's
table:

|                | Editorial (content)        | Integrity (pipeline)          | Correction (record)              |
|----------------|----------------------------|-------------------------------|----------------------------------|
| examples       | dup collector-day, bee-vs-flower | record count craters vs. last build | Bee-Gap calls a eusocial bee parasitic |
| audience       | **end users** of the data  | **operators** of the build    | **end users** of the data        |
| action         | **flag** the record, publish it | **block** the build      | **change** the published value   |
| defined over   | the *current* data         | *this build vs. the previous* | the current data **and the value the correction was written against** |

That last cell is the whole design. A correction shares a flag's audience and a
gate's blocking power, but it is the only one of the three that makes an
*editorial claim outranking a cited source* — so it owes an auditable `reason`, and
it owes an account of what it is correcting.

**Where the override lives** follows from ADR 0008's standing gate: *does it
propagate recursively over relational structure, and does it need a native "why"?*
A per-record override is a bounded join over leaf predicates. It does not
propagate. So it stays external, in dbt, and earns no substrate — and the
mechanism was mostly already there: `marts/species_traits.sql` is a `COALESCE`
precedence chain with a parallel `*_source` column, and a correction is one more
arm at the top of it. Because `COALESCE` takes the first non-null, a
correction-first arm *overrides* a wrong non-null value rather than merely filling
a gap.

**The generic failure mode of override tables** is the override's afterlife: "set
vosnesenskii nesting = Ground" masks upstream permanently, so if the source is
fixed, or changed to something else, the override keeps firing unexamined.

**But that argument assumes a live upstream, and ours is not.** Both correctable
sources — `bee_traits_beegap` and `bee_parasite_hosts` — are checked-in CSV seeds
cut from the same one-time USGS publication, Bee-Gap 2017 (ScienceBase
`5bd868b2e4b0b3fc5ce9dadd`). Their values cannot move unless someone deliberately
re-vintages a seed and commits it. A runtime gate that halts the nightly publish on
that is guarding a door which only opens from the inside — and the report is more
useful in the commit's diff, where a reviewer is already standing, than in a build
that stopped at 3am. This is what demoted most of the blocking below; the machinery
survives because a *live* correctable source would restore the argument intact.

## Decisions

1. **A correction is a third modality, not a variety of flag or gate.** It changes
   a published value at the highest precedence, records an auditable `reason`, and
   is reported to end users through the existing provenance surface — `*_source`
   reads `correction` and the site's tooltips pick it up unchanged. A node is
   exactly one of flag / gate / correction, as ADR 0006 already requires of the
   first two.

2. **The fix is external; the report is Stelis's.** beeatlas owns the
   `bee_traits_corrections` seed and the precedence arm (the FIX); Stelis owns
   `corrections-drift.rkt` and the `corrections-drift-gate` node, wired ahead of
   `dbt-build` (the REPORT). This is exactly ADR 0006 decision 3's in-process
   `rule-check` modality, reused verbatim for its third consumer.

   **It stays a Stelis node rather than moving to a dbt seed test**, even though a
   frozen seed only changes at commit time. The coverage half (decision 5) is about
   *this module's* arms, not about the data; and the live-source case the node is
   shaped for is a build-time concern. A dbt test would be the right home for the
   data half alone, and the wrong home for both together.

3. **`expected_upstream` is a citation, not a tripwire.** Every row records the
   value the source gave when the correction was written; the dbt model never reads
   it. Its primary job is documentary — a reader of the seed can see what claim was
   overruled, which is what makes an assertion outranking a cited source auditable.
   That it *also* supports a drift comparison is a secondary benefit, and not the
   thing that makes the correction legitimate. The taxonomist is.

4. **Drift is classified, and the class picks the modality (st-kfu).** "Upstream
   stopped matching" covers situations that deserve opposite responses:

   | class | what happened | response |
   |---|---|---|
   | **unchecked** | no upstream arm for the trait — nothing was compared | **block** |
   | **contested** | the source moved to a third value | **block** if the source is *live*; warn if *frozen* |
   | **resolved** | the source now says what we corrected it to, or withdrew the claim | warn |
   | **orphaned** | the source has no record of the key at all | warn |

   Blocking is reserved for what a build can still prevent. `resolved` and
   `orphaned` are dead weight — untidy, not dangerous — and blocking on `resolved`
   would halt publishing over the correction having *worked*. That matters beyond
   tidiness: an alarm with no proportionate response teaches an operator to re-pin
   `expected_upstream` until it goes quiet, which turns the citation into a rubber
   stamp.

   **Cadence keys the `contested` block** (`current-live-traits`). Against a live
   source the value moved unattended and a build is the first place anyone could
   notice. Against a frozen one it moved because someone committed it, so the
   report belongs in that diff. Nothing correctable is live today, which is a fact
   about the sources rather than an omission — the live branch is exercised in
   tests so the blocking path is not the path nothing has ever run.

5. **An unverified correction blocks regardless of cadence.** A correction naming
   a trait the gate has no arm for was never compared to anything, and the seed
   then *looks* guarded while one row is not. Note what this is **not**: unlike
   every other class, it is not news about a source — it is a defect in
   `corrections-drift.rkt` itself. That is why the frozen-source argument does not
   excuse it, and why it is the one thing here that still stops a build.

6. **Key presence, not the value, separates a withdrawal from a typo.** An empty
   upstream value is ambiguous: upstream may have dropped the claim we objected to
   (*resolved* — delete the row), or the correction may name a species that never
   existed (*orphaned* — and the species actually meant is **still publishing the
   error**, so deleting is exactly the wrong move). The two are told apart by
   whether upstream has *any* row for the key. Without that join the gate gives
   confidently wrong advice on a mistyped correction.

7. **`retract` is a first-class action beside `replace`.** "This is wrong" without
   "and here is the right answer" is a common and honest position; the first
   correction needed it twice. Bee-Gap's nesting vocabulary splits bumble bee
   nesting inconsistently, so supplying a replacement would fabricate precision we
   do not have. A retraction publishes nothing from the corrected source and falls
   through to the next arm of the precedence chain. The two actions also read an
   empty upstream value *differently* (decision 6), so the action is part of the
   correction's meaning, not just its effect.

8. **Degrade on an unreadable check.** Consistent with ADR 0006 decision 5, an
   unreadable seed passes with a warning rather than halting a pipeline over
   missing infrastructure. This is about the check not running at all; within a
   check that *did* run, decision 5 governs.

## Consequences

- st-4z8 is locally resolved: all three wrong assertions for *B. vosnesenskii* are
  overridden (sociality replaced, nesting and host_bees retracted), the other 62
  cuckoos are untouched, and only the report to USGS remains outstanding.
- **The gate catches a case dbt structurally cannot.** A correction naming a
  species with no upstream row simply drops out of the model — there is nothing to
  override, and no test on the mart can see the absence. The gate's `LEFT JOIN`
  yields an empty actual value, which drifts against any expectation, so the
  correction surfaces instead of evaporating.
- **The gate compares against the atlas name, deliberately not through
  `int_synonyms`.** A correction is authored against the name a curator sees; a
  synonym-only match would pass silently, and surfacing it as drift is the safer
  reading of an ambiguous key.
- **Adding a correctable trait is a deliberate four-part change**, not a data edit:
  an arm in `species_traits.sql`, an entry in `corrections-drift.rkt`'s trait list
  (which now generates the gate's SQL, so coverage and comparison cannot fall out
  of step), an entry in the seed's `accepted_values`, and — since `accepted_values`
  checks columns independently — a singular test for the supported `(trait,
  action)` combination. Learned by shipping `host_bees` with only the first two
  (st-ib2): the seed test failed the build, and an unimplemented `replace` would
  have no-opped in silence. The `unchecked` class is the backstop for the same
  mistake made on the Stelis side.
- **The advisory classes stay a build-log report, deliberately.** A durable
  maintenance queue for them — a fold over the drift observations, aged in builds,
  with an "acknowledged but unresolved" state to relieve the pressure to re-pin —
  was designed and **rejected as unearned**: three correction rows against a frozen
  source do not justify it, per ROADMAP's premature-feature test. Recorded because
  the design is right *if* the preconditions ever arrive (a live correctable source,
  or a curator who is not a committer), and because "we considered it and it was too
  much machinery" is more useful later than silence.
- **Corrections and taxonomic override are the same object, and this ADR keeps them
  apart anyway.** Both are curated claims with an author, a reason, and a place in a
  precedence order; a species is just the most specific rank, so "a correction beats
  Bee-Gap" and "a genus assertion beats an inherited one" are one defeasible
  most-specific-wins rule — the one ADR 0008 deferred. They stay separate not
  because the distinction is real (provenance precedence vs. rank specificity is a
  thinner line than ADR 0008 implied) but because unifying them buys **no
  capability**: `species_traits.sql` already implements one and
  `taxon-inherit.rkt` the other. Noted in st-ar4 as the shape to converge on if
  either side needs to grow.
- **Authoring stays in git.** The seed is forward-only authored data whose store is
  the repository. A correction-authoring store or UI is deferred (st-ar4) — it is
  the same fork ADR 0008 left open for high-rank taxon assertions (curated config
  vs. a forward-only authored store), and the two should be settled together rather
  than growing two different answers.
- **Nothing is generalized across test beds yet.** The gate's upstream relation is
  beeatlas-shaped SQL — one arm per source column. Generalizing the correction
  overlay waits for a second user, per ROADMAP's premature-feature test.
- **Source cadence is now a thing Stelis models, in one narrow place.** It is a
  trait-level list inside `corrections-drift.rkt`, not a property on the graph's
  artifacts. If a second consumer ever needs to ask "can this input change without
  us deciding it should?", that is the point at which it should move onto the
  artifact and stop being a local list.
- No change to freshness or `cache.rkt` (ADR 0001/0003/0005). The gate reads the
  seeds at gate time to decide *whether to block*; it never consults the
  observation history and never decides staleness.
