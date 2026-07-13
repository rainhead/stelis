# ADR 0004 — A deterministic build clock (SOURCE_DATE_EPOCH) (st-3mi)

**Status:** accepted · **Horizon:** 1 · **Date:** 2026-07-12

Decides what time a task embeds when its output legitimately carries a
"built at" / build-identity field, so those outputs stay content-addressable.
First forced by beeatlas-8td (topology's `_meta.built_at` wall-clock stamp);
expected to recur for every future target that stamps provenance into its bytes.

## Context

"Determinism is a day-one property" (DESIGN): build the same snapshot twice, get
identical bytes. A task that writes `time.time()` into its output breaks this —
every rebuild differs, so the cache never reaches early cutoff (ADR 0003) on that
target and `--verify` fails. topology-postprocess did exactly this; the other
single-file exports did not, which is the only reason slices 2/3 were byte-stable.

Stripping volatile fields before hashing was rejected: it leaves the on-disk
bytes non-deterministic (only the hash stabilizes, so `--verify`'s byte compare
still fails) and needs a per-format registry of "which fields are volatile."

The reproducible-builds ecosystem already solved this: `SOURCE_DATE_EPOCH`, a
single build-wide Unix epoch that any tool honors in place of wall-clock time,
chosen as a **function of the sources** so it's stable across rebuilds.

## Decisions

1. **Stelis injects `SOURCE_DATE_EPOCH` into every task's hermetic env.** It rides
   the same per-task env channel as `EXPORT_DIR` (exec.rkt `run-task #:env`),
   computed once per build so all tasks in one build share one clock. Any task
   that needs a build time reads it from the env instead of the wall clock;
   tools that already honor the convention become deterministic for free. A task
   that ignores it is unaffected.

2. **The epoch is the committer date of the source repo's HEAD commit** (`git -C
   <BEEATLAS> log -1 --format=%ct`), overridable by an already-set
   `SOURCE_DATE_EPOCH` in the environment (the convention's escape hatch). This
   is a deterministic function of the code snapshot: HEAD does not move between
   the two builds of a `--verify`, so outputs are byte-stable. It means "built
   from source as of commit X's date," **not** live data freshness.

3. **The clock is ambient, not part of the input fingerprint.** `SOURCE_DATE_EPOCH`
   is *not* folded into `recipe-hash` / `input-snapshot` (ADR 0001/0003). Folding
   it in would make every task stale on every beeatlas commit, even commits that
   touch nothing that task reads — global invalidation. Left ambient, a
   commit-only change does not force reruns; an embedded `built_at` therefore
   means "source date at the task's last actual rebuild," which is the honest
   claim for a content-addressed cache.

4. **Consumers own the semantics; live freshness is out of scope.** Stelis
   guarantees a deterministic clock, not a meaning. A field that must reflect
   when the *data* changed is inherently wall-clock/data-dependent and
   incompatible with a reproducible build — that belongs to the incremental /
   streaming work (Horizon 2; cf. beeatlas's own incrementalization epic), not
   to this clock. beeatlas's `built_at` is baked-in provenance, not displayed as
   freshness, so the source-date reading is correct for it.

## Consequences

- beeatlas-8td SITE 1 (topology `built_at`) is fixed by having the script read
  `SOURCE_DATE_EPOCH` and fall back to `time.time()` only when unset — so it
  stays runnable standalone (nightly) yet deterministic under Stelis. That is the
  contract recorded on beeatlas-8td; the fix lands there, using this policy.
- No cache/trace format change: the clock is ambient, so existing entries and
  receipts are untouched.
- New guardrail available: once a stamping target reads the clock, `--verify`
  becomes a real determinism gate for it (topology's geometry was already stable;
  only the stamp blocked it).
