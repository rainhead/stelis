# ADR 0015 — A task is told which of its inputs changed, so it can recompute by partition

**Status:** accepted · **Horizon:** 2 · **Date:** 2026-10-06 (epic st-6d2, step 1 st-6d2.1; salishsea's save build, salish-9uu.6, and its consumer epic salish-9uu.8)

The engine tells a task that runs for changed inputs **which** inputs changed, as
`STELIS_CHANGED_INPUTS`, when and only when every other input still has the content
address the task's last recorded run read it at and its outputs are as that run
left them. The
task may then recompute only the partition of its work that reads a named input and
replace that partition in place. Nothing about how the task computes moves into the
engine, and no retraction algebra is introduced: this is the first delta-shaped
step on the roadmap's path, taken at the cheapest point, where the engine already
holds the fact and only has to say it.

## Context

salishsea's write API wakes a build after every native sighting is saved, and that
build re-derives the world to publish one row. Measured on the Fly machine
(2026-10-06): the occurrences derivation recomputes all ~64,000 occurrences across
five sources (5.6 s), the identifier candidates and profile links recompute over
all of them again (2.5 s, 1.6 s), and the file tasks rewrite every day file, id
shard and month (4 s). About 15 of the 20 seconds a save costs is work a single new
row does not require. The visitor who saved it is waiting to share the link, and
the API's by-id read (salish-9uu.5) only bridges that minute.

The roadmap keeps **delta-based propagation** (Z-sets / DBSP-shaped) recorded, not
queued, "where coarse over-rebuilding hurts" and until a data question pulls it.
This is that question: *when one native sighting is saved, which published facts
can change?* One occurrence row; one day file; one id shard; one calendar month;
the profile links of the animals it names; the manifest. The derivations are
already partitioned by the inputs they read — each occurrences arm is one source,
written one `INSERT` per source with a `source` column — so the partition a change
touches is a function of which inputs changed, and the engine computes exactly
that to decide whether to run.

Two things the engine must not do here. It must not take the recompute inside
(DESIGN: transformations stay external; ADR 0008 D5's exception is for recursive
closure with a native "why", and a partitioned SQL recompute is neither). And it
must not tell the task something that is not true: a task told "only `b` changed"
that is also missing an output, or whose table was rewritten underneath it, would
replace one partition beside a rest that is not the last run's answer.

## Decisions

1. **The engine states a fact it already derives; the task owns the recompute.**
   `decide`'s `'input-changed` decision names the inputs whose address moved. For a
   task the project lists as incremental, run-plan hands those names to the task as
   `STELIS_CHANGED_INPUTS` (newline-separated artifact names, the `STELIS_REBUILD_KEYS`
   idiom). What to recompute for a named input is the task's knowledge, kept beside
   the transformation (salishsea's `derive-occurrences.ts` maps each source arm to the
   inputs it reads). The engine never learns the partition.

2. **The hint is given only when its contract holds.** Three conditions, checked
   before the run: the task's decision was `'input-changed` (a code, recipe or
   receipt reason means everything may differ, and the task is told nothing); the
   project named the task (`#:incremental-tasks`, opt-in like `#:partial-tasks`,
   because the check costs the outputs' digests before the run); and the recorded
   outputs are intact — present, and digesting to what the last clean run recorded
   (`recorded-outputs-intact?`, the three questions `decide` asks in precedence
   order, answered together). A listed task that ran for changed inputs but
   failed the third check runs whole, and the build says `full recompute: an
   output is missing or ≠ its last receipt`; a task running for any other reason
   runs whole as it always did, and nothing is said, because nothing was withheld.

3. **A hint, never a correctness dependency.** A task that ignores the variable
   recomputes everything and is exactly as correct. Early cutoff still compares the
   whole output afterwards, so a partitioned recompute that produced the same bytes
   as a full one is indistinguishable downstream, and one that did not is a bug in
   the task's partition map, caught by the same observation that catches any other
   wrong output — not something the engine can vouch for.

4. **Per-key file rebuilds over a relation are the next step, not this one.** The
   day files, shards and months are fan-outs over a key the relation carries, but a
   db-relation is observed per column, never per key, so the engine cannot yet say
   which days moved before the task runs. A relation observed *by a key column*
   (per-key digests, as the notes store is digested per species) would give that
   delta and let the existing `STELIS_REBUILD_KEYS` machinery apply; it is a
   separate decision, with its own measurement, and the salishsea epic carries it
   as step 2.

5. **Z-sets stay deferred.** After steps 1 and 2 a one-row save should cost what
   one row costs. Change sets flowing through the derivation would matter for the
   five-minute ingests, where Maplify's window and iNaturalist's updates are also
   small deltas into the same derivation; that is the case to measure before
   taking it on.

## Consequences

- `run-plan` gains `#:incremental?`; `run-task` gains `#:changed-inputs`;
  `cache.rkt` gains `recorded-outputs-intact?`; a project gains
  `#:incremental-tasks`. salishsea names its occurrences derivation. The identifier
  candidates and the profile links read `build.occurrences` as one input, so the
  hint cannot tell them which source moved; for them the fact has to arrive per
  key, which is step 2's keyed observation (by the `source` column, the same
  mechanism as by day). The build prints `⇒ incremental: N input(s) changed: …`
  when the hint is given.
- The trace record does not yet say whether a run was incremental; `--explain
  --last` shows the decision, which names the inputs, and the output delta. If a
  partition bug ever needs the fact recorded, it is one field, additive.
- The roadmap's delta entry is pulled: step 1 by this ADR, step 2 queued behind its
  measurement, Z-sets still recorded.
