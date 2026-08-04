# ADR 0011 — Git is the store for authored overrides; a store waits for a curator who cannot commit (st-ar4)

**Status:** accepted · **Horizon:** 2 (authoring) · **Date:** 2026-08-04

Stelis has two authored-claim overlays and both are checked-in files: beeatlas's
`bee_traits_corrections` seed ([ADR 0009](0009-corrections-outrank-their-sources.md),
st-t4t) and stelis's [`data/taxon-traits.rktd`](../../data/taxon-traits.rktd)
([ADR 0008](0008-taxon-reasoning-earns-the-substrate.md), st-ozp). ADR 0008 left the
fork open for taxon assertions — *"curated checked-in config vs a forward-only
authored store — start with config, no authoring UI"* — and ADR 0009 left the same
fork open for corrections, each deferring to the other so the two would not grow
different answers. **This settles it once, for both: the store is the repository.**
Not "for now": a decision, with named conditions that would reopen it.

## Context

The overlays are small and slow. The corrections seed holds **three rows**, added
in **two commits**; `taxon-traits.rktd` holds **seven assertions**, added in one.
Each row carries a prose reason or citation — `expected_upstream` plus a paragraph
of why upstream is wrong; a `hosts` clause and, where the lineage warrants one, a
`note`. Both files are input *artifacts* of the build graph, content-addressed like
any other, so a curator edit already reads as `'input-changed` and re-runs the node
that consumes it.

**The tempting reading is that git is the placeholder and a store is the
destination.** Stelis already runs a forward-only authored store: beeatlas's notes
store is written outside the build and read at the ingestion boundary per key
([`notes-digest.rkt`](../../src/notes-digest.rkt), st-2k9). Pointing the same
machinery at an overrides table is a small piece of work. That is precisely why it
needs deciding rather than drifting — the cheapest path is to build it because we
can.

**But the notes store has three properties these overlays lack, and each one is
what pays for a store:**

| | notes store | the two overlays |
|---|---|---|
| **who writes** | a curator at a web surface, no checkout | one author, who has the checkout |
| **cadence** | per species, continuously | at the rate upstream errors are found and confirmed at the source (twice) |
| **when** | a CRUD must land between builds | the point of the edit *is* what the next build publishes |

**And what git supplies, a store would have to reimplement.** Both overlays make an
editorial claim that outranks a cited source (ADR 0009 decision 3) — the change most
worth a second reader before it goes live. Git gives review, attribution, rollback,
and the reason *in the same object as the claim*, for free. ADR 0009 already leans on
this: the frozen-source drift classes are reported rather than blocking because the
report is "more useful in the commit's diff, where a reviewer is already standing,
than in a build that stopped at 3am." An authoring UI that skipped review would
weaken the thing that makes an overriding assertion auditable.

## Decisions

1. **Authored overrides are stored in git — both overlays, one answer.** A
   checked-in file, a reviewed commit, read as an ordinary input artifact. This
   covers the correction seed, the taxon assertions, and any authored overlay added
   before the conditions below are met.

2. **This is a commitment, not a deferral.** Neither ADR carries a "phase 2 (web
   store)" note any more, and a store is not on the roadmap. The distinction is the
   point of the ADR: a deferred decision invites the same proposal every quarter.

3. **Three conditions reopen it; any one is sufficient.** (a) a curator who is not a
   committer; (b) authored volume past what commit review absorbs; (c) authoring
   that must land *between* builds rather than as a build input. Absent all three, a
   store proposal is refused on ROADMAP's premature-feature test — the argument is
   already made here and does not need remaking.

4. **If it reopens, the two overlays move together, into one store.** ADR 0009's
   convergence note holds: "a correction beats Bee-Gap" and "a genus assertion beats
   an inherited one" are one defeasible most-specific-wins rule, kept apart today
   only because unifying them buys no capability. A store is exactly where it would
   buy one — a single editing surface and a single precedence order — so the
   migration and the unification are the same piece of work, done once. The shape is
   the notes store's, not a new mechanism: SQLite, forward-only, per-key digests at
   the ingestion boundary, keyed deltas (st-2k9).

5. **The drift gate is unaffected either way.**
   [`corrections-drift.rkt`](../../src/corrections-drift.rkt) compares
   `expected_upstream` against upstream, whatever holds the correction. Nothing in
   ADR 0009's classification depends on the storage answer.

## Consequences

- **st-ar4 closes decided.** The fork ADR 0008 and ADR 0009 each left open is shut;
  both now point here.
- **The accepted cost is stated plainly:** a wrong published value can be fixed only
  by someone with a checkout and commit rights, and a correction's latency is a
  commit plus the next build. With one curator who is also the committer that cost
  is currently zero — and the moment it isn't, that *is* condition (a), not a
  surprise.
- **This is not an argument against authored stores.** The notes store stays exactly
  what it is; it earns its keep on all three counts in the table. What is rejected is
  a store for *these two overlays*, on their facts.
- **Storage says nothing about format.** `taxon-traits.rktd`'s glossary/traits split
  and the seed's CSV columns are each shaped by their consumer and stay that way.
  They would both have to be migrated if the store ever arrives — one more reason to
  make that move once, per decision 4.
- **No code changes and no engine changes.** This ADR removes an option rather than
  adding a mechanism; the deliverable is that the next person to ask "shouldn't these
  live in a database?" gets an answer with conditions attached.
