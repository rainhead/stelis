# ADR 0016 — A relation observed by a key: its per-key map is its per-part layer

**Status:** accepted · **Horizon:** 2 · **Date:** 2026-10-06 (epic st-6d2, step 2 st-6d2.2; the consumer is salishsea's `occurrence-days`, salish-9uu.8.2)

A project may declare a db-relation **keyed** by a SQL expression over its columns.
Such a relation is observed per key — each group's row-coherent digest and count,
`("<key>" -> "<digest>:<count>")`, the shape a keyed store already has — **in place of**
its per-column observation. Everything downstream of that shape then applies without
change: the per-key timeline, `--moved-keys`, key-blame, and the partial rebuild of
a fan-out `'dir` declared `store-keyed` on the relation, with removed keys pruned and
the dir's identity checked against the relation's keyset.

## Context

ADR 0015 made a save's derivation cost what one row costs. The file tasks after it
still cost what the world costs: `occurrence-days` writes every Pacific day's file
(4,408 of them) into a fresh directory and swaps it in, 2.4 s, and the engine then
hashes all 4,408 to learn that one changed, 0.5 s more. The id shards and the
calendar months are the same shape at smaller scale.

The engine already rebuilds a fan-out per key: beeatlas's notes harvest reads a keyed
STORE (the notes store, per species), the store's per-key map is recorded on the
consumer's record, delta.rkt names the keys that moved, rebuild-policy.rkt says what
each arm means (an output `store-keyed` on the input is rebuilt and pruned by key),
and `STELIS_REBUILD_KEYS` hands the task the keys. What it could not do is say which
keys of a **relation** moved before the task ran, because a db-relation is observed
per column (st-7vz), never per row group. The day files are a fan-out over a key
the relation carries — the Pacific day of `observed_at` — so the missing piece was
one observation.

## Decisions

1. **The project declares the key; the engine computes the map.** `relation-keys`
   (relation-digest.rkt) groups the rows by a SQL expression and digests each group
   the way the whole relation is digested (`hash()` of each row's JSON, summed:
   order-independent), with its count. The expression lives in the project
   (salishsea.rkt's `OCCURRENCE-DAY`), a hand copy of the consumer's own grouping
   (occurrence-days.ts's `DAY_ZONE` and `strftime`), and the `store-keyed` identity
   check on the dir is what catches the two drifting apart: a file with no key, or a
   key with no file, fails the gate. Verified before landing on the live snapshot:
   4,408 computed keys, identical to the 4,408 day files the build wrote.

2. **Keyed replaces per-column, for that relation.** `artifact-key-parts` asks the
   project's store-keys resolver first; a relation it answers for has its keys as
   parts, any other its columns. One or the other, never both: a map mixing the two
   keyspaces would read a changed column as a moved key. What is given up for a keyed
   relation is the attribute-level observation (which column moved, the row count the
   integrity gate reads); salishsea runs no gate over `build.occurrences`, and the
   question its operator asks of it is "which day".

3. **The existing seam, not a new one.** The resolver is `resolve-store-keys`, the
   st-2k9 slot, so `input-store-snapshot`, `verify-store-keyed`, `live-key-map` and
   `rebuild-keys-of` need no change and no new kind. A relation with a producer is
   recorded by its producer as an output (`derive-occurrences` records the per-day
   map); a producerless keyed relation would be recorded on its consumer like a store.

4. **Still an observation, not the skip signal.** The relation's identity stays the
   row-coherent `relation-digest` (st-d5d): per-key digests alone would false-skip on
   a swap of rows between two keys that happen to hash the same, and the per-key map
   is what the delta folds over, not what decides whether a consumer runs.

5. **One key per relation.** The id shards (keyed by a hash of the id the browser
   shares) and the calendar months (the day's prefix) are fan-outs over other keys of
   the same relation. A relation could carry one keyed observation per consumer only
   by recording several maps under one artifact, which the trace does not do; a
   month is a function of the day, so the calendar can rebuild the months its moved
   days fall in from the day delta without a second map, and the shards wait until
   0.6 s matters.

6. **The basis is what the consumer last consumed.** A fan-out's delta was taken
   against its input's *newest* recorded map. That is wrong whenever the producer
   ran and the consumer then failed: the consumer's receipt still names the older
   digest, and a delta from the newer map misses the keys that moved in between —
   rebuilding too few, green over stale files. `input-key-deltas` now reads the
   digest the task's cache entry names for the input and asks the history for the
   map at that digest (`history-key-observation-at`, matched by the producer's
   recorded output digest, or for a producerless store by the map's own address).
   No entry, or no recorded map at that digest, is no basis, and the task rebuilds
   whole. This was latent for the notes harvest too; the keyed relation made it
   worth finding.

7. **The identity check runs in the build.** `verify-store-keyed` existed since
   st-243 and ran only in tests. After every clean run of a task with a
   store-keyed `'dir`, run-plan checks the directory against the store's keyset:
   after a partial run a mismatch fails the task — the engine named and pruned
   keys by a rule the task does not group by, and the directory is now neither
   set — and after a full run it is reported and the run stands, the set being
   at least the task's own. This is the drift detector decision 1 leans on.

## Consequences

- `relation-keys` in relation-digest.rkt; `artifact-key-parts`'s db-relation arm
  prefers store keys; salishsea declares `build.occurrences` keyed by Pacific day,
  `days` as `(store-keyed 'build.occurrences "{}.json")`, and `occurrence-days` as
  a partial task. The map is held per write generation, like the observer's answers.
- The consumer honours `STELIS_REBUILD_KEYS` by writing only the named days into the
  existing directory, each file atomically, instead of swapping the directory; the
  engine prunes the days that emptied. A full run keeps the swap, and so does a
  partial run told more days than the swap would cost: a basis of the wrong shape
  (the first build after this lands diffs a per-day map against a per-column one)
  names every day, and the swap is the honest answer to "everything".
- beeatlas's `notes/` is now checked against the notes store's keyset after every
  harvest, as a warning on a full run; a mismatch there is a finding, not a fault
  of this change.
- `--history build.occurrences` now shows which days moved at each build, and
  `--history build.occurrences:<day>` why a day last moved.
- Measurement on the machine follows the consumer's deploy (salish-9uu.8.2); the
  per-day map of 4,408 keys is a chunked block tree (ADR 0014), so recording it costs
  one root and a bucket per changed day.
