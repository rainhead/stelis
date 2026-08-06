# ADR 0012 — pnwmoths is a requirements source, not an integration target

**Status:** accepted · **Horizon:** 2 · **Date:** 2026-08-06

`~/dev/pnwmoths` is the first project assessed as a Stelis host that is **not**
one of Peter's data pipelines. **It is declined for integration — its constraints
and Stelis's dependencies are incompatible in a way no amount of engineering
fixes — and adopted as a requirements source, because it exercises build-integrity
failure modes `beeatlas` and `salishsea` structurally cannot.**

## Context

PNW Moths (`moths.pnwinsects.org`) is a fully static rebuild of a Django/CMS
natural-history catalogue: ~700 species factsheets generated at build time from
CSV + Markdown, Eleventy + Vite, DuckDB and Parquet at build time only, images on
a Bunny CDN. Its own ADR 0001 commits it to static files with no server or
database at runtime, ever.

**Why it looked like a candidate.** Its `build:site` is nineteen npm scripts
joined by `&&`, with ordering constraints that exist only inside that string. Its
`docs/lessons-learned.md` (604 lines) is dominated by declaration failures —
undeclared edges, forgotten steps, gates that read a directory before the step
that fills it. That is the class of problem Stelis exists to make structurally
impossible, and several of its worst bugs would be:

- **Gates ordered before their producer (#275).** `check-withheld` and
  `check-unpublished` ran before `build:copy-parquet` filled `_site/species/`.
  Both passed for a year while occurrence records for 126 embargoed Geometridae
  and 45 provisional species were published. Their fix is a documented habit
  ("order gates last"); ours would be topology, plus `dir-extent.rkt` for the
  five producers writing into one `_site`.
- **A derived file nothing derived.** `src/_data/speciesSlugs.json` looked
  generated and was not, so newly added species silently fell out of the
  legacy-URL resolver while their pages published fine.
- **Reproducible but not current (#197).** `data/key-matrix.json` was
  byte-deterministic and months stale, because nothing linked it to its inputs.

**Why it is nevertheless declined.** Three constraints, none of them negotiable
and none of them about engineering quality:

1. **Static-hosting-forever**, and no build host at all — every expensive
   operation (tiling, uploads, district assignment) is already deliberately a
   maintainer-run local script.
2. **Simple, ubiquitous tools expected to still exist in a decade.** A Racket
   toolchain, a DASL blockstore, and a graph authored in a language its
   maintainers do not have is a bus-factor problem in a repo whose own PRODUCT.md
   chooses "legibility and low operational surface over cleverness."
3. **The repo is expected to change hands** and to sit unmaintained for stretches.

The incrementality argument does not rescue it either way: `build:data` runs in
about three seconds, so minimal-upstream rebuilding buys it nothing. But that is
not the reason for the verdict, and reaching for it first was a misreading — see
the amendment to DESIGN.md's opening line, made in the same session.

**What it exercises that our own test beds cannot.** `beeatlas` and `salishsea`
are both single-operator pipelines on a host we own, and since ADR 0007 the
beeatlas output tree *is* the published surface. pnwmoths differs on exactly the
axes our integrity story is untested on: no build server; an additive CDN that
never purges, so the output tree is **not** the published surface; derived
artifacts committed to git and occasionally hand-edited; and humans running long
mutating scripts concurrently on one laptop (their ADR 0025, a lost-update that
silently reverted twenty successful uploads).

## Decisions

**D1. No integration, and no Stelis dependency in that repo.** Revisit only if
its constraints change, or if Stelis acquires a capability it demonstrably cannot
build for itself — st-s8i is the live candidate.

**D2. No `pnwmoths.rkt` in this repo, not even read-only.** A hand-transcribed
mirror of another project's pipeline would look authoritative, drift within a
month, and be read by nobody. It is the exact failure their `speciesSlugs.json`
lesson documents. A one-shot audit producing a report is fine; a standing artifact
is not.

**D3. Adopt it as a requirements source.** Findings are filed as ordinary issues
against Stelis, with the originating pnwmoths bug cited. Two so far:

- **st-s8i — the destination as an observed node.** Our integrity story ends at
  the filesystem we write. pnwmoths shows three failure modes past that edge:
  objects missing (83 `images.csv` rows absent from the CDN, their #232), objects
  present but unreachable from anything declared (five *Macaria* tile sets keyed
  to the MPG genus while `species.csv` still says *Speranza*, their #279), and
  objects that outlive their producer (32 deny-listed slugs still serving 200,
  their #273). This is also the missing third arm of `rebuild-policy.rkt`, whose
  comment asserts that "every removal therefore ends up either pruned or
  rebuilt" — false against an additive destination.
- **The exception ratchet.** Their `referential-integrity-exceptions.csv` records
  each accepted violation *with the issue that would resolve it*, and the gate
  fails if someone fixes the underlying problem and leaves the line behind. We
  have this shape only in `corrections-drift.rkt`'s `expected_upstream` citation;
  `data-quality.rkt` has no exception concept at all, so a rule is either clean or
  blocking. Not yet filed — it needs the ADR 0006 flags-vs-gates line drawn
  through it first.

**D4. Reciprocity is design, not code.** Where a Stelis pattern would help them,
it travels as a described pattern they implement in their own stack — an
input-digest sidecar for committed artifacts (`cache.rkt`'s core in ~40 lines of
Node), or a topological-order assertion over `build:site` derived from the
input/output override pairs their ADR 0017 already mandates. Never as a
dependency.

## Consequences

- Stelis gains a source of integrity requirements that is **adversarial by
  construction** — derived independently of our design lineage, from a project
  whose operational shape we do not share. That is worth more than a third test
  bed of the same shape would be.
- The `salishsea` multi-project questions (st-7f4, st-z1c) are **unaffected**:
  this decision adds no second graph. Their trigger is still salishsea.
- We accept knowing about integrity gaps we will not fix for the project that
  found them. st-s8i is recorded and unqueued for exactly this reason — per
  ROADMAP's slotting rule the pull must come from a project Stelis actually
  serves, and pnwmoths is not one.
- If st-zb9, st-5e6, st-8an and st-s8i all land, D1's revisit condition is
  arguably met. That is a different conversation from the one declined here, and
  it should be had on its own evidence rather than by drift.
