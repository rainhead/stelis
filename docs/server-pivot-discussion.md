# Server pivot — pending design discussion (2026-07-16)

**Status:** OPEN. Captured mid-conversation to feed a Fable-led grilling of the
pivot and a roadmap re-baseline. Nothing here is decided except where marked
**[DECIDED]**. Do not enact — the north star must be interrogated first (it sits
squarely in DESIGN.md's named failure mode: substrate-for-its-own-sake / the
inner-platform effect).

## The reframe (Peter, 2026-07-16)

> "The more I think about this, the more I wish I had started here: **not a build
> system that morphs into a server, but a server backed by a Datalog-queried
> sentential database, replacing 11ty.**"

So the candidate north star is a **server** that renders pages by **querying a
sentential (fact-based) Datalog database**, replacing 11ty's static generation —
rather than a batch build system that incrementally grows server capabilities.
Under it: reload-sees-it falls out of the server reading live state; "static"
becomes (at most) a cache of query results; the build system's role narrows to the
heavy derived pipeline (dlt/dbt/ingestion), not the site render.

## What forced the reframe: the reload-sees-it consistency analysis

Target semantics: **when the author's POST returns, a page reload shows the note.**
This is a **read-path** property, not a publish-path one. An async/debounced
trigger (watcher or worker invoking a rebuild after the write) is *by construction*
eventual and cannot deliver it. It comes only from:
1. **Reading live state at request time** (today: beeatlas's `/api/notes` island,
   ADR 0013 Layer 0 — the page fetches live on load, no build, no Stelis); or
2. **Synchronously publishing before the response AND serving read-your-writes** —
   which the static S3/CloudFront model made impractical (ADR 0013 rejected
   coupling the S3 PUT + invalidation to the request path).

So the **targeted static rebuild already shipped delivers only *eventual* freshness
of the baked/no-JS/CDN layer — not reload-sees-it.**

### Three shapes considered
- **(A)** Live-read owns reload-sees-it; Stelis owns only the eventual static
  layer. (Fable's initial recommendation; Peter rejected its premise — see below.)
- **(B)** Stelis is ON the read path: a fast incrementally-maintained live
  projection the read path queries — the engine IS the read-your-writes source.
  Literalizes "incorporate incoming data in near real time"; needs Stelis resident.
- **(C)** Resident synchronous build + local origin: the API co-serves locally and
  calls a warm Stelis to build the page synchronously before returning.

## Peter's positions

- **[DECIDED]** `/api/notes` live-fetch at every load "was a kludge." The **target
  state DROPS that endpoint.** Notes are **burned into the static page**, not
  fetched live. (So he rejects shape A as the long-term answer.)
- **[DECIDED]** Willing to **drop S3 and even CloudFront** to make this easier and
  faster. The static/CDN model is not sacred.
- **[DECIDED]** The **API server can shell out to Stelis and BLOCK on its return**
  (synchronous — shape C). `/api/notes` stays only until the synchronous burned-in
  path is verified to deliver reload-sees-it, then the kludge is deleted.
- **[DECIDED]** **POSTs may be very slow.** "No one but me will be doing them any
  time soon" — single-user, so latency is not a constraint now. (Dissolves the
  resident-Stelis urgency; sync shell-out is fine.)
- **Long-range goal:** the **API server and Stelis become ONE thing** (converges
  C → B / unified). Many steps between here and there; wants them mapped into the
  roadmap soon.
- **Immediate plan (this session):** finish replacing `run.py` pragmatically, then
  have Fable grill the pivot.

### Measured (Fable, on Peter's laptop — maderas may differ)
- `racket src/main.rkt --commands notes.json` ≈ **3.4s** wall (plan only).
- A full blocking POST (plan + hashing + two `uv run` subprocess starts +
  tree-digest + history write) realistically **5–8s, serialized** behind a build
  lock. Acceptable given single-user; it's the forcing function that will price
  resident Stelis onto the roadmap — but don't pre-build residency.

## Verdict on recent work (Fable, plausible)
- Trigger / targeted rebuild / `--export-dir`: **carry over** to shape C.
- The **S3 PUT / CloudFront invalidation / manifest publish leg: throwaway** under
  the stated target — do not build it.

## THE open question to grill next
Is "a server backed by a sentential Datalog DB, replacing 11ty" **value-first**, or
the inner-platform move dressed up? What is the **smallest real thing** it makes
better for Peter-the-user that the current stack can't — and what is the honest
step-by-step road from today (a batch build system + a bespoke notes API + 11ty)
to there? Then re-baseline ROADMAP.md and (probably) amend DESIGN.md / write an ADR.
