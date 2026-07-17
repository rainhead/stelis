# Resume — Model Y (ADR 0007 Amendment)

Operational handoff for the Model-Y arc. The **design** is in
[`docs/adr/0007-serve-from-build-host.md`](adr/0007-serve-from-build-host.md)
(the Amendment section); the **work items** are beads with full descriptions.
This file is just branch state + resume order + the one deployment gotcha.

## Where things stand (2026-07-17)

- **Design:** grilled and settled (Model Y). Captured in the ADR Amendment.
- **Capture on `main`:** ADR amendment + reshaped beads. Safe — docs only.
- **Step A done, on branch `model-y`:** `site` removed from the Stelis graph
  (`src/beeatlas.rkt`), plan pins restored (`src/plan-test.rkt`, 35 tasks),
  450 tests pass. Pushed to `origin/model-y`. **Not on `main`.**

## The deployment gotcha (why the code is on a branch)

maderas's nightly does `git pull` on **`main`** at 03:00. Removing `site` from
the graph (A) without the nightly rendering via npm (C) would leave a nightly
half-state: data updates, HTML goes stale. So **A and C are deployment-coupled**
— the whole Model-Y code chain must land on `main` together, coherent. Until
then it lives on `model-y`. Keep `main` on the current site-in-graph code so the
live nightly keeps rendering.

## Resume order (beads carry the detail)

- **A — `st-5em`** ✔ done on `model-y` (site out of graph + the reader seam kept).
  Still TODO on this bead: the `npm run fetch-data` interface — and note the
  naming collision: `fetch-data` ALREADY exists (an S3 dev-pull, `scripts/
  fetch-data.sh`) and `build:data` still calls the deleted `run.py`. Resolve the
  dev-pull-vs-stelis-build semantics as the front edge of B.
- **B — `st-mfb`** (beeatlas): build-time-baked artifacts drop out of the
  manifest; a site-repo postbuild hashes the ~5 runtime binaries + writes the
  slim manifest; slim `src/manifest.ts`/`resolveDataUrl` to runtime binaries;
  `generated_at` from the data build. Replaces `make-local-manifest.js`.
- **C — `st-jeu`** (beeatlas + maderas, PRODUCTION): `nightly.sh` → sync +
  fetch-data + build + merge-swap (rsync: assets/data first no-`--delete`, pages
  `--delete`, manifest `mv` last, age-prune). Delete S3 push / CloudFront /
  GH-dispatch / bash-manifest. duckdb → persistent maderas path (`/var/www`
  htdocs+var convention), drop the S3 pull. **Land A+B+C on `main` together.**
- **D — `st-pry`** (beeatlas `infra/` CDK): relocate the duckdb backup out of
  the site bucket to a dedicated offsite bucket (unblocks `st-vjd`). Deploy
  locally as `rainhead` (see `infra/README.md`), never a manual `aws` edit.
- **E — `st-nee`** (beeatlas API, PRODUCTION): the write path — commit → flock →
  fetch-data(notes) → build → merge-swap → live/pending. Depends on C.
- Then **`st-vjd`** teardown (after soak + D).

## Verify (for C/E, on maderas)

Full nightly renders + serves over HTTPS (burned-in notes, cache headers); a
note write round-trips (POST → reload shows the note); nightly and a write race
serialize on the flock.
