# ADR 0007 — Serve from the build host; synchronous burned-in publish (st-nee)

**Status:** accepted · **Horizon:** 2 · **Date:** 2026-07-17

Resolves the open server pivot (`docs/server-pivot-discussion.md`) by splitting
it: the **serving substrate moves to the build host now** (beeatlas.net served by
Apache on maderas from a directory Stelis writes), while the **sentential-Datalog
render substrate is deferred** until a concrete value prop earns it in. A note
write publishes by *synchronously* rebuilding the site before the response
returns — reload-sees-it as a build property, not a read-path property.

## Context

The pivot doc's reload-sees-it analysis stands: an async/debounced publish
(ADR 0013's Layer 1 worker in beeatlas) is by construction eventual and cannot
deliver "when the POST returns, a reload shows the note." Delivering it needs
either live reads at request time (the `/api/notes` island — decided: a kludge to
be deleted) or a synchronous publish into the same box that serves the page. The
static S3/CloudFront model made the synchronous path impractical; it becomes
practical the moment serving is local to the build.

The grilling separated two things the pivot bundled: (i) local-origin serving +
synchronous rebuild — deliverable now, no new substrate; (ii) a server rendering
pages by querying a sentential Datalog database, replacing 11ty — the
inner-platform risk concentrated, and required by nothing in (i). Facts checked:
maderas (2-vCPU/4GB Linode) already terminates public TLS for `api.beeatlas.net`;
hashed-asset filenames are produced by the 11ty build and `artifacts.py`, not by
AWS, so they survive the move unchanged.

## Decisions

1. **beeatlas.net serves from maderas.** An Apache vhost serves a static site
   root that Stelis owns; S3/CloudFront retire from serving (they stay warm as
   rollback until post-soak teardown, st-vjd). Direct DNS flip, no staging
   subdomain — single-user stakes, downtime accepted. Cache semantics port to
   Apache headers: `immutable` on hashed paths, `max-age=0` on HTML, `no-cache`
   on `manifest.json`; the swap merges without deleting old hashed assets.

2. **The 11ty render is a Stelis task.** A `site` target whose inputs are the
   data artifacts plus the site source tree (`tree-digest`) and whose recipe is
   `npm run build` (st-ak1). Transformations stay external — Stelis invokes the
   renderer, it does not reimplement it. Early cutoff makes the write path cheap:
   an unchanged `notes.json` skips the multi-minute render.

3. **A note write publishes synchronously and commits first.** The API commits
   the note (authoritative, forward-only, never rolled back), then takes a shared
   flock and shells out to `stelis --build site` into the served root (st-nee).
   Build failure does not fail the write: the response distinguishes "live" from
   "saved; publish pending", and the nightly repairs. Slow POSTs are accepted
   (single author); the *measured* POST latency is the forcing function for any
   future targeted render. ADR 0013's debounced-worker shape is superseded — its
   constraint ("never couple write latency to the build") was revoked with eyes
   open.

4. **The sentential-Datalog server is deferred, not adopted.** Replacing 11ty
   with a query-backed renderer must re-enter through a concrete value prop that
   a Stelis one-or-two steps from today would serve. First candidate: editorial
   data-quality flags (st-650), the un-built half of ADR 0006. Until such a prop
   survives its own design pass, building the substrate is the named failure mode
   (substrate-for-its-own-sake).

5. **Blast radius is bounded during cutover.** Backups (authoritative notes,
   nightly DuckDB/taxa) stay on AWS through the transition; the nightly's S3
   publish + GitHub-dispatch legs go behind a kill switch rather than being
   deleted; teardown of `/api/notes`, the site bucket, CloudFront, and deploy
   IAM waits for verified burned-in reload-sees-it (st-vjd).

## Consequences

- st-nee is re-scoped: its S3 PUT / CloudFront invalidation / manifest leg is
  deleted; "publish" now means the synchronous local site build. Work chain:
  st-ak1 (`site` task) → st-bgy (vhost + nightly retarget + DNS flip) → st-nee
  (write path) → st-vjd (teardown). st-650 explores the flags value prop
  independently.
- beeatlas's ADR 0013 Layers 1–2 (debounced worker, S3 publish, scoped
  invalidation) are superseded by this design; Layer 0 (`/api/notes`) lives only
  until burned-in freshness is verified, then dies with st-vjd.
- The GH-Actions deploy leg retires (CI test legs remain); code deploys to
  production become `git push maderas main` + the next build.
- Stelis takes its first step onto the serving path — but as a *file publisher*,
  not a request-time engine. Shape B (engine on the read path) remains future
  work that must be priced by real latency numbers from this design.
- `docs/server-pivot-discussion.md` is resolved by this ADR and kept as the
  historical record of the fork.
