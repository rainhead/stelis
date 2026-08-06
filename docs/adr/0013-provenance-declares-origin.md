# ADR 0013 — Provenance declares an artifact's origin, and the graph is checked against it

**Status:** accepted · **Horizon:** 2 · **Date:** 2026-08-06

Resolves st-zb9 and st-5e6. **An artifact's `provenance` becomes the answer to
"where does this come from", with a third value `'upstream` beside `'derived` and
`'authoritative` — and the graph is now REFUSED when its declarations disagree
with its topology.** Leafness is read from provenance rather than declared beside
it, and the vocabularies are closed and checked at construction.

## Context

`required-tasks` stops its backward walk at any artifact with no producer. That is
correct for a genuine leaf and silent for an artifact whose producing task was
never written — both read as "nothing to run", so a forgotten producer prunes the
upstream out of every plan instead of failing.

An audit of the beeatlas graph (2026-08-06) found **16 of 79 artifacts
producerless, of which exactly one said so.** Six were `'code` (producerless by
design, st-whi), one was `'external`, and the remaining nine — four out-of-band
`geographies_*` relations, two Bee-Gap extracts, and three curated/CRUD files —
were ordinary artifacts indistinguishable from a mistake. The graph was correct;
it was correct *by authoring discipline*. Four of the nine already carried the
comment "PRODUCERLESS on purpose", which is the whole problem in one line: the
fact was known, written down, and in prose, where nothing could check it.

Separately, `build-graph` verified that no two tasks claim one output but never
that an edge named a *declared* artifact. A typo'd input did not error — the name
simply had no producer, so the edge vanished from every plan and the task stopped
being invalidated by it. A typo'd output was worse: it registered a producer for
an artifact nobody declared while the real one kept none, and the double-producer
check could not fire because the names differ.

This matters more than its size suggests. DESIGN.md's opening commitment is that
the engine holds a *complete* declarative account of how every artifact is
produced; the completeness was documentation.

## Decisions

**D1. `provenance` answers "where does this come from", with three values.**
`'derived` — a task here produces it; safe to destroy and rebuild; **must have a
producer.** `'authoritative` — forward-only state we own (a CRUD store, curated
overrides); migrations only; never produced here. `'upstream` — somebody else's
data, snapshotted in; also unproducible here, but for a different reason: it is
not ours to write forward, so there is no migration story either.

Six beeatlas artifacts are re-declared `'upstream`: `geographies_ecoregions`,
`geographies_us_counties`, `geographies_us_states`,
`geographies_padus_wilderness`, `bee_traits_beegap.csv`, `bee_parasite_hosts.csv`.

**D2. Leafness is READ from provenance, not declared beside it — for three of the
four values.** `'code` and `'external` must be leaves by KIND; `'upstream` must be
a leaf by ORIGIN; `'derived` must be produced. **`'authoritative` says nothing
either way**, and that is not a naming failure that a better word would fix:
forward-only state is legitimately written by a task *inside* the graph — which is
exactly what `cache.rkt`'s provenance filter exists for ("Authoritative outputs are
excluded — cutoff applies only to derived state", because a forward-only write is
an effect) — and equally by a writer *outside* it, like the notes worker or a
person with git. Provenance answers "what may the engine do to this"; those two
shapes get the same answer to that question and opposite answers to "is the
producer in this graph".

*This was got wrong first.* The original cut asserted `'authoritative ⇒ leaf`.
beeatlas has no authoritative output today, so the real graph passed and the claim
looked true — it was falsified by `cache-test`'s `out` only once the check moved
into `build-graph` (D6) and started seeing synthetic graphs. Had it stayed where it
was first placed, the false premise would have shipped and the first authoritative
output added to beeatlas would have been rejected as a graph bug.

Rejected: a `#:leaf?` flag. It would
be a second source of truth able to contradict provenance, and an artifact
declaring both `'derived` and `#:leaf? #t` is a bug no type would catch — the same
argument `rebuild-policy.rkt` already made against an `#:on-removed` slot.

Also rejected: expressing leafness by re-kinding the nine to `'external`. `kind`
is load-bearing for ADDRESSING (`relation-digest` dispatches on `'db-relation`,
`tree-digest` on `'dir`) and `'external` specifically means *unresolvable* — it
resolves to `#f` and can only ever report `'inputs-unresolvable`. Re-kinding would
have destroyed their digests to record a fact about their origin.

**D3. `check-graph-leaves` refuses disagreement in BOTH directions.** A declared
leaf that acquires a producer is as much a bug as a producible artifact without
one, and the second is the one that appears while editing. All disagreements are
reported at once, because the first run over an un-annotated graph finds a batch.

**D4. `build-graph` refuses an edge naming an undeclared artifact.** Scoped to
task inputs and outputs. An `imports` edge naming an artifact outside the graph
stays legal — `code-closure` keeps it without traversing it — and a test now
asserts that asymmetry so it is not removed later as an inconsistency.

**D5. The vocabularies are closed and checked in `make-artifact`.** Found by
review, and it is the sharpest of these: a typo'd provenance on a *produced*
artifact is invisible to everything above. It is not a leaf and it has a producer,
so D3 calls it consistent — and then every `cache.rkt` filter is
`(eq? 'derived …)`, so the output is never observed, never receipted, and **early
cutoff silently stops firing.** A green build that quietly stopped cutting off is
the exact failure class D1–D4 exist to remove, and adding a third provenance value
widened the way in.

**D6. `build-graph` runs the leaf check, so no graph can skip it.** Originally the
call sat in `beeatlas.rkt` at module level, which reached every entry point but
left it a convention the *next* graph would have to remember — st-zb9's own failure
shape one level up, raised by review as st-0kf. `build-graph` is the only way to
construct a graph, so putting it there removes the convention entirely. Cost: the
synthetic graphs in the test suite must declare their sources. Measured before
committing to it — 8 files, ~20 one-word annotations, and D2's error was found in
the doing. The `#:check?` opt-out (option 2 in st-0kf) was not needed.

## Consequences

- Provenance is serialized into the graph digest, so the first build after this
  writes one new topology snapshot. Correct: the graph says more than it did.
- `cache.rkt`'s two `'derived` filters are allow-lists, so they were already right
  for a third value; their comments said "authoritative is excluded" and now say
  what the code does. In practice no non-`'derived` artifact can reach them at
  all, since D3 forbids it a producer.
- **A residual hole, named rather than hidden:** an `'authoritative` artifact is
  unchecked in either direction, so three of the nine leaves that motivated this
  ADR (`notes-store.db`, `taxon-traits.rktd`, `bee_traits_corrections.csv`) are
  back to being trusted rather than checked. Closing it needs an axis provenance
  does not have — which is the `#:leaf?` flag D2 rejected, and rejecting it is
  still right at this size. The arm that catches the actual bug class, a
  `'derived` artifact with no producer, is unaffected: a new artifact defaults to
  `'derived`, so forgetting a producer still fails.
- The other two graph-authoring checks (`check-partial-tasks`, `check-dir-extents`)
  stay in main.rkt's build arm, and the asymmetry is principled rather than
  historical: neither is pure over the graph alone — one needs the partial-task
  list, the other a path resolver — so neither can move into `build-graph` without
  dragging that context along. Worth revisiting if either ever loses its extra
  argument.
- st-5e6's second question — whether a declared-but-unreferenced artifact should
  be reported — was dropped rather than decided, and is now **st-pgq**.
