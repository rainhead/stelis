# ADR 0003 — Early cutoff: emergent skip, recorded receipt (st-8ig)

**Status:** accepted · **Horizon:** 1 · **Date:** 2026-07-11

Decides how "a rerun that rebuilds identical content stops propagation" works.
Extends the input-addressed cache (st-d44.3 / st-yg7.1) and the build trace
(st-yg7.4).

## Context

A task whose input changed must rerun — but if its rebuilt output is
byte-identical to before, everything downstream is already up to date. Build
systems usually implement this ("early cutoff") as a gate: compare the new
output to the old, and if equal, suppress the downstream walk.

Stelis's executor already re-decides every task *at its turn*, after its
upstreams ran, by hashing its real input files. So if an upstream rebuilt to
identical bytes, downstream snapshots are unchanged and downstream tasks
cache-skip with no new machinery. Cutoff is **emergent from input-addressing**,
not a feature to add — what's missing is only the evidence that it happened.

## Decisions

1. **No gate; downstream decisions stay the ground truth.** Nothing suppresses
   or forces downstream tasks based on an upstream's output comparison. Each
   task's own fresh input snapshot decides. This keeps one skip mechanism, and
   it degrades correctly when a task's outputs are only partially hashable.

2. **Output hashes are a *receipt*, recorded per cache entry (v3).** After a
   clean run, the task's outputs are content-hashed and stored. The next rerun
   compares fresh hashes against the stored ones, yielding an `output-delta`:
   `'identical` (the cutoff point) or `'changed` (propagation is real), with
   the artifact names. The delta rides on the trace record, so
   `--explain --last` can name where cutoff triggered — "reran, outputs
   identical, downstream saw unchanged inputs" — instead of a bare "cached".

3. **Only derived outputs are cutoff-eligible.** `output-snapshot` hashes
   outputs that are `'derived`, resolvable, and existing. Authoritative
   artifacts are excluded: their writes are forward-only effects, and "rebuilt
   to identical bytes" is not a claim Stelis makes about them. Tokens and
   db-relations have no file to hash and drop out — so a task like `dbt-build`
   is judged on the outputs that *can* be verified (the parquets), which are
   exactly the ones downstream decisions read.

4. **Tasks without an input snapshot still store an entry.** Boundary tasks
   and tasks with non-content-addressable inputs (dbt) never had cache entries
   (nothing could skip them). They now store an entry with `#f` recipe/input
   hashes purely to carry output hashes — the comparison basis for the next
   rerun's receipt. The absent input side can never produce a skip: `decide`
   is only reached when a snapshot exists.

## Consequences

- The real pipeline's hinge case works and is *visible*: dbt reruns (inputs
  unresolvable), rebuilds the parquets identically, and `generate-sqlite`
  skips — with the trace naming dbt-build as the cutoff point.
- `--explain` (hypothetical) still marks below-frontier hits `≈` conditional;
  only a real build can know whether cutoff fires, and `--explain --last`
  reports it after the fact.
- Cache and trace formats bumped to v3; old state reads as a miss / no trace,
  per the versioned-state contract (one full rebuild, never an error).
