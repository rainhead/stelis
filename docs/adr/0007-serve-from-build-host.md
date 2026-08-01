# ADR 0007 — Serve from the build host; synchronous burned-in publish (st-nee)

**Status:** accepted · **Horizon:** 2 · **Date:** 2026-07-17
**Amended:** 2026-07-17 (Model Y — see Amendment below; revises decision #2).
**Amended:** 2026-08-01 (multi-author — see Amendment below; records decision #3's
expired premise and corrects Model Y's cost line).
**Amended:** 2026-08-01 (per-page provenance — see Amendment below; revises Model Y
decision #1: the render returns to the graph as two nodes).

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

## Amendment — Model Y: Stelis is the data engine, the site build owns the render (2026-07-17)

Grilled the same day st-ak1 landed. Decision #2 ("the 11ty render is a Stelis
task") is **revised**: putting the render in the graph, on reflection, cut
against this project's own stated line (`DESIGN.md` / the pivot doc: "the build
system's role narrows to the heavy derived pipeline… **not the site render**").
Now that AWS is out of the serving path, the CDN-era coupling that the `site`
task papered over (a build export dir of unhashed artifacts vs. a served root of
hashed artifacts + `manifest.json`) can be dissolved instead of bridged.

**Model Y (adopted):**

1. **Stelis narrows to the data engine.** `site` LEAVES the graph (reverting
   st-ak1's node; the `EXPORT_DIR`-honoring reader seam `lib/build-data-dir.js`
   is kept). Stelis produces the raw (unhashed) data artifacts; the 11ty/Vite
   site build is top-level and consumes them via `npm run fetch-data`
   (= `stelis --build <data> --export-dir DIR`). Provisional — Stelis may
   reclaim the render later if a reason appears.

2. **The site build owns asset tagging.** Build-time-baked artifacts
   (`species.json`, `notes.json`, …) stop being hashed/manifested — 11ty inlines
   them. The ~5 runtime-fetched binaries (`occurrences.db`/`.parquet`, the
   geojsons, `places_meta`) stay content-hashed/immutable, tagged by a
   **site-repo postbuild step** that writes a **slim manifest** =
   `{runtime-binary → hashed-name, generated_at}`. The client's `resolveDataUrl`
   / PWA offline model is unchanged, just a shorter manifest.

3. **Publish flow:** `fetch-data → build (11ty inline + Vite hash) → postbuild
   (hash runtime binaries + slim manifest) → merge-swap into the served root`
   (rsync: hashed assets/data first no-`--delete`, pages with `--delete`,
   `manifest.json` `mv`'d atomically last, age-prune). `nightly.sh` collapses to
   sync + fetch-data + build + place; the S3 push, CloudFront invalidation,
   GH-dispatch, and bash `artifacts.py manifest` block all delete.

4. **DuckDB persistence.** The working duckdb moves from an S3-pull-to-`/tmp` to
   a **persistent maderas path** (the `/var/www` htdocs+var convention); the
   offsite backup is KEPT (same-host is not a backup) but relocates out of the
   doomed site bucket into a dedicated bucket — which also unblocks st-vjd's
   site-bucket teardown. AWS leaves the hot paths (serve/build/ingest); DR
   backups stay offsite by design (AWS now, Akamai object storage a later
   single-vendor option).

5. **st-nee write path (reshaped):** commit → shared flock → `npm run fetch-data`
   notes-only (`--from notes-harvest … notes.json`, `STELIS_REBUILD_KEYS=<name>`)
   → `npm run build` → merge-swap → `live` / `saved; publish pending`. Same
   build+place the nightly runs, scoped to notes. Commit-first / flock /
   never-roll-back are unchanged.

**Cost accepted:** the render runs unconditionally (~18s) per note write AND per
nightly — Stelis's content-addressed early-cutoff render-skip is gone. It only
ever helped a no-change build (a note write always changes `notes.json`), so the
loss is ~18s on a rare no-op nightly. Fine single-user, for now.

**Work:** (A) `site` out of graph + `fetch-data`; (B) site build tagging
(postbuild + slim manifest, slim `manifest.ts`); (C) `nightly.sh` shrink +
duckdb-local; (D) CDK duckdb-backup relocation; (E) st-nee write path. st-vjd
teardown last (now also depends on D).

## Amendment — the single-author premise expires (2026-08-01, st-1aw)

Advertising the site and inviting authors retires decision #3's "Slow POSTs are
accepted (single author)". (Decision #1's "single-user stakes, downtime accepted"
governed the DNS flip — a one-time act, completed 2026-07-17, not re-violable.)

Whether the POST must still block on the publish was re-opened and **decided in
beeatlas**, not here: ADR 0018 (coalescing publish queue) — it still blocks.
Recorded there rather than re-argued here.

**Correction to the Model Y amendment.** Its "Cost accepted: the render runs
unconditionally (~18s) per note write AND per nightly — Stelis's
content-addressed early-cutoff render-skip is gone" is **superseded**. The
render-skip came back, but not the way Model Y gave it up: not as early cutoff
over a `site` node in the graph (that node left, and stays out), but as
beeatlas's own build receipt gated by Stelis's per-key delta — `--moved-keys`
over the `notes/` observation history (`delta.rkt`, st-066), consumed by
beeatlas's ADR 0017 (scoped note render). That is the first consumer of a Stelis
delta by a targeted step *outside* the engine.

Decision #4's deferral and Model Y #1's "provisional" both stand; the reason that
could reclaim the render is per-page provenance (st-hdm), not render speed.

## Amendment — the render returns as two nodes; per-page provenance earns it (2026-08-01, st-hdm)

Model Y #1 left the door open — "Provisional — Stelis may reclaim the render later
if a reason appears" — and the multi-author amendment above named the reason in
advance. This amendment acts on it. **Model Y decisions #2–#5 are unchanged**
(asset tagging, publish flow, DuckDB persistence, the st-nee write path); only #1's
"`site` LEAVES the graph" is revised. Decision #4's Datalog deferral is untouched:
this reclaims a *render invocation*, not a render substrate.

### What changed since Model Y

**1. The reason's enabling capability now exists and is verified (st-nbu).**
`--history <artifact>:<key>` answers "why does this member look the way it does?"
by walking the recorded observation history backward. Verified on a real notes
build: `notes:'bombus mixtus.json'` → `notes-store.db:bombus mixtus`, terminating
at the ingestion boundary. The missing hop is `notes/` → the pages, and it exists
only if the render is a node. Before st-nbu, "per-page provenance" was a promise
with no machinery under it; the argument would have been unfalsifiable.

**2. The speed argument is dead, and this amendment does not get to use it.**
st-ak1 failed on exactly that ground ("early cutoff makes the write path cheap"),
and then did not even deliver it (st-nee). beeatlas has since delivered it
*externally* — ADR 0016/0017/0019 took the note publish from 23s to 8.5s and
skipped the bundle on note writes. **A reclaim that regresses the measured publish
latency is a failure of this amendment, not a cost of it.**

**3. What beeatlas built to get there is three re-implementations of Stelis
machinery, and beeatlas's own ADRs say so:**

| beeatlas | Stelis | beeatlas's words |
|---|---|---|
| `scripts/build-receipt.mjs` | `prior-complete-build?` (st-243) | "deliberately the same shape as Stelis's" (ADR 0017 §3) |
| `BEEATLAS_RENDER_KEYS` | `STELIS_REBUILD_KEYS` (st-pd1) | "mirrors Stelis's … exactly, including set-but-empty" (§1) |
| `scripts/build-app.mjs` | cache.rkt's skip + fan-out-key's stray check | input fingerprint + output-presence + `assets/` stray deletion |

ADR 0019 also documents the near-outage: `rsync -a` preserves mtimes, so a reused
bundle would eventually have aged past the publish's 30-day prune and been **deleted
out from under the pages referencing it** — nightly, with a green build. That is the
specific failure "content-addressed, not timestamped" exists to prevent, and it
appeared the moment the cache lived outside the engine. It was found by review, not
by the outage; so were three others.

**4. The node separation already exists**, as two npm scripts (`build:app` /
`build:content`) with a documented contract about what each may touch. The two graph
nodes map 1:1 onto scripts that are already there — the reclaim is smaller than
st-hdm assumed when it was filed.

**5. The blockers are closed** (beeatlas-d3y dropped eleventy-plugin-vite; the
beeatlas-0gx epic shipped and deployed 2026-07-31).

### A correction to Model Y's own justification

Model Y said putting the render in the graph "cut against this project's own stated
line (`DESIGN.md` / the pivot doc: 'the build system's role narrows to the heavy
derived pipeline… **not the site render**')." That line is in
`docs/server-pivot-discussion.md` (26–27) **only** — the doc *this ADR itself
resolved* and keeps as the historical record of the fork. `DESIGN.md` says something
of the opposite shape: "IO, external API ingestion, secrets, and **rendering** live
at declared edges as first-class node types." A render node is the DESIGN
commitment, not a violation of it.

Model Y's appeal to `DESIGN.md` was therefore mistaken. Its *other* ground —
dissolving the CDN-era coupling between an unhashed export dir and a hashed served
root, rather than bridging it — stood on its own, still stands, and is preserved by
decisions #2–#3, which this amendment does not touch.

### Decision

1. **The render returns as TWO nodes, not one.** `app-bundle` (inputs: `src/`, both
   Vite configs, `package.json`, `package-lock.json`, the `.env*` files; output: the
   hashed `assets/` subtree) and `site-content` (inputs: the data artifacts, `notes/`,
   and the render code — templates, `_data/`, `lib/`, configs — as `'code` artifacts;
   output: the pages subtree). One node was st-ak1's shape, and it fused two things
   whose inputs are disjoint: the bundle is entirely invariant to note content.
2. **The justification is per-page provenance, and only that.**
   `--history <pages>:<path>` must reach the note that produced the page. If it
   cannot, the reclaim has not delivered, whatever else it improves.
3. **Retiring the duplicates is the test that this landed**, not a bonus.
   `build-receipt.mjs` and `build-app.mjs`'s gate retire when the engine owns those
   decisions. Two caches that can disagree is strictly worse than one cache outside
   the engine — so a half-migration is the one outcome to refuse.
4. **Transformations still stay external.** Stelis invokes 11ty and Vite; it does not
   render. This is the same commitment decision #2 made in the first place, and it is
   why this needs no ADR 0008 D5-style argument: a render node is an *invocation*,
   not a transform moved inside the engine.

### Known costs and open questions — deliberately not settled here

- **`_site` has three producers** (Stelis's data export, Vite's assets, Eleventy's
  pages) writing into one tree. One-producer-per-artifact demands disjoint output
  subtrees; exactly where those boundaries fall, and what happens to
  `postbuild-data.mjs`'s slim manifest, is design work this amendment authorizes
  rather than performs.
- **`_scaffold-check/index.html` bakes wall-clock `builtAt`**, so it differs between
  any two builds (ADR 0017 measured precisely this). A whole-tree digest of the pages
  can therefore never cut off. Per-*page* observation survives it — only that one key
  moves — but the node's own digest does not. Fix or exclude; not decided here.
- **`_site` is load-bearing state now** (ADR 0017's own consequence).
  `prior-complete-build?` is the engine-side equivalent of the receipt that made it
  safe, which is the point — but its interaction with `merge-swap.sh`'s age-prune
  must be designed, not assumed.
- **The dev loop must not go through Stelis.** `npm run dev` is `eleventy --serve`
  plus Vite middleware. A graph node must not become the only way to render a page.
- **Key correspondence stays undeclared.** Per beeatlas ADR 0017, Stelis must not
  learn that a `notes/` key is a species. So `--history <pages>:<path>` will name the
  notes that moved *in the same build*, not the one note that produced that page —
  exact in the one-note-one-page publish, a set on a nightly. Narrowing it needs a
  `fan-out-key` manifest declaring the mapping, and whether that is worth declaring
  is a separate decision.

### Consequences

- **st-hdm's acceptance criterion is half-spent.** Its second clause — "a note write
  does not rebuild the app bundle" — is already true, externally. This amendment is
  accountable for the first clause only, and st-hdm should be re-scoped to say so.
- **ADR 0016/0017/0019 do not become wrong; they become redundant.** Their reasoning
  is the specification of what the engine must keep doing — particularly the four
  bugs ADR 0017/0019 found by review, each of which is an invariant the engine now
  inherits responsibility for.
- **Model Y #1's "provisional" is spent.** If this reclaim fails, the render leaves
  the graph again *with a stated reason*, not by reverting to a provisional posture
  that invites a third attempt on the same unexamined grounds.
