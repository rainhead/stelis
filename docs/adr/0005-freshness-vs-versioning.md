# ADR 0005 — Freshness vs versioning: two stories, one clock stays out (st-sds)

**Status:** accepted · **Horizon:** 1 · **Date:** 2026-07-14

Decides that "is this output current?" (freshness) and "what state is the world
in, and how do I name and traverse states?" (versioning) are distinct concerns
with distinct mechanisms — and that a monotonic event clock belongs only to the
second. Surfaced while designing st-sds's persistence; keeps a logical clock out
of the freshness path.

## Context

st-sds persists build history beyond the single last-build trace (Horizon 1). The
tempting design was a global monotonic **event-id** — a logical clock stamping
every distinct observation — with output freshness reasoned as "is my as-of id
behind the world's?", LSN/watermark style. It reads as the natural substrate for
the near-term targeted-rebuild goal (st-066).

Three things argued it out of the freshness path:

- **We already answer freshness exactly.** `cache.rkt` compares per-input
  *content-hashes* over the dependency graph (ADR 0001/0003); `changed-names` /
  `--why` attribute *which* input moved. Content + graph **is** the freshness
  mechanism. A monotonic id adds no precision over it.

- **An id can't see a content revert (ABA).** Ids advance on every distinct
  observation, including `A → B → A`: an output built against the first `A` has a
  lower id than the input's latest, so the id says "stale" while the content is
  identical. A content compare must arbitrate anyway — so the id can only ever be
  a *cheap trigger* atop the content truth, which is exactly early cutoff
  (ADR 0003), never a decider.

- **The id's real value is a different question.** A total order over whole states
  — naming them, branching, tagging, traversing — is git's job. The roadmap
  already houses that: Horizon 3, "non-linear time: git-like branching and
  grafting of database-programs." The monotonic id is the seed of *that* story,
  not a freshness primitive H1 is missing.

## Decisions

1. **Freshness is content-hash + dependency graph, per-input — never a clock.**
   st-sds gives this existing mechanism *memory* (a history of observations), not
   a new rule for deciding staleness.

2. **History records order for browsing only; freshness never consults it.** The
   append sequence (or source-epoch) orders builds so "when did X last change?" is
   answerable, but staleness reads hashes and edges, never the ordinal. This is
   the line that keeps the two stories from bleeding into each other.

3. **The monotonic event-id / refs / branches / tags are the versioning story =
   Horizon 3, not built now.** If and when non-linear time arrives, it layers over
   the same observation log as its own concern — additive, not a retrofit of the
   freshness path.

4. **Content-hash stays the arbiter.** Any future cheap staleness *hint* (an id, an
   mtime) is an optimization over the content truth, never the truth — so it
   inherits early cutoff's exactness and never forces a false rebuild on a revert.

## Consequences

- st-sds shrinks to what H1 needs: persist and historize the content-hash
  observations and per-derivation bases `cache.rkt` already computes, projected
  into Datalog (provenance-datalog.rkt). No clock, no refs. See st-sds's design.
- st-066 (targeted rebuild) folds over the observation history using content +
  graph; it gains nothing from a freshness clock, so nothing here pre-shapes it
  wrongly or blocks it.
- Horizon 3's versioning model gets a clean seam: it is additive over the same
  observation log, not a rework of freshness.
- No change to `cache.rkt`'s role or the existing input fingerprint (ADR 0001/
  0003) — this ADR records what st-sds must **not** add.
