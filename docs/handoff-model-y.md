# Resume — Model Y (ADR 0007 Amendment)

Operational handoff for the Model-Y arc. The **design** is in
[`docs/adr/0007-serve-from-build-host.md`](adr/0007-serve-from-build-host.md)
(the Amendment section); the **work items** are beads with full descriptions
(implementation notes on each). This file is branch state + the landing
checklist + the one deployment gotcha.

## Where things stand (2026-07-17, end of day)

- **Design:** grilled and settled (Model Y). Captured in the ADR Amendment.
- **beeatlas `model-y` is committed through D** (A/B/C/D are one commit each);
  E is in the working tree, uncommitted.
- **A — `st-5em` DONE.** stelis `model-y`: `site` out of the graph (committed,
  pushed). beeatlas `model-y`: `npm run fetch-data` = the Stelis
  data build (`scripts/fetch-data.sh`, exports into `public/data` by default);
  the old S3 dev-pull renamed to `npm run pull-published` (now syncs all three
  stable dirs); dead `build:data` deleted.
- **B — `st-mfb` DONE** (beeatlas `model-y`). The runtime set is
  **6** (occurrences_db, counties, ecoregions, wilderness, places, places_meta
  — occurrences.parquet is NOT runtime; it, checklist.parquet, and photos.json
  drop from publish entirely). `lib/runtime-artifacts.js` is the shared
  runtime contract; `scripts/postbuild-data.mjs` (npm `postbuild`) derives
  `_site/data` wholesale from the data dir (hashed binaries + stable dirs +
  slim manifest written last; `generated_at` from `SOURCE_DATE_EPOCH`, else
  `'local'`); `validate-db.mjs` reads `sqlite_master` itself via `node:sqlite`;
  `src/manifest.ts` slimmed; dead `seasonality-cache.ts` and the `hyparquet`
  dep deleted. Verified: full `npm run build` green end-to-end; suite = 958
  pass + the same 17 pre-existing env failures as clean HEAD (prime/sw/species
  tests — unrelated, worth a separate look).
- **C — `st-jeu` code DONE** (beeatlas `model-y`; **not yet run on
  maderas**). `nightly.sh` rewritten: publish flock (`var/publish.lock`,
  shared with the st-nee write path) → sync → baseline restore → `npm run
  fetch-data` → integration gate → `npm run build` → merge-swap into
  `SITE_ROOT` → baseline snapshot. All S3 site legs, CloudFront, GH-dispatch,
  and the bash manifest block are GONE; **the offsite DuckDB/taxa backup trap
  stays** (still the site bucket until D). DuckDB moves to the persistent
  `/var/www/beeatlas.net/var/` path (htdocs+var convention; vhost DocumentRoot
  now `htdocs/` — migration steps in beeatlas
  `docs/runbooks/serve-from-maderas.md` §6). The integration-gate baseline is
  now a local snapshot of the last *published* export
  (`artifacts.py baseline-files`, new verb + test). `deploy.yml` is deleted on
  the branch (it built from and deployed to S3; its build-time-fetch would
  hard-fail post-B anyway); the surviving CI test legs (ADR: "CI test legs
  remain") moved to `.github/workflows/js-tests.yml` (vitest + typecheck —
  build/smoke can't run in CI without a data dir). Merge-swap semantics
  verified against a scratch root; data fast-tier suite 519 pass. A two-axis
  code review ran 2026-07-17; all findings fixed (baseline snapshot now gated
  on actual publish, `BACKUP_BUCKET` rename, `_copy_baseline` dedupe, stale
  ADR 0002/0007 + infra/README + PRODUCT.md + pull-published header
  corrected).

## The deployment gotcha (why everything is on branches)

maderas's nightly does `git pull` on **`main`** at 03:00. The Model-Y chain is
deployment-coupled end to end: A without C leaves data updating while HTML goes
stale; C's nightly requires B's postbuild; landing any of it stops the S3
publishes. So **A+B+C land on `main` together**, and only when the landing
checklist below is satisfiable in one sitting. Until then `main` keeps the
current site-in-graph code so the live nightly keeps rendering.

## Landing checklist (A+B+C → main, in order)

1. **DNS must already point at maderas** (runbook §3, CDK deploy as `rainhead`
   — check first: `dig +short beeatlas.net` → `45.79.96.48`). Landing C stops
   the S3/CloudFront publishes, so a CloudFront-pointed DNS would go stale.
2. Commit + land beeatlas `model-y` and stelis `model-y` on their `main`s.
   (E rides along safely: its publish gate defaults off, writes respond
   `pending` and the nightly bakes them until runbook §7 flips it on.)
3. On maderas, with cron commented out: the §6 migration (htdocs+var mkdir +
   content move, `mv /tmp/beeatlas.duckdb var/`, vhost + `-le-ssl` DocumentRoot
   update, apache reload), `git pull` both checkouts.
4. Run `bash data/nightly.sh` by hand once. Expected: diff tests SKIP (no
   baseline snapshot yet), full Stelis rebuild (fresh `var/export/`), site
   builds, merge-swap publishes, baseline snapshots, healthcheck pings.
5. Re-enable cron. Next nightly is the real soak start.

## Resume order (beads carry the detail)

- **D — `st-pry` code DONE** (beeatlas `model-y`; **not deployed**).
  `PipelineBackupBucket` added to the stack mirroring the notes
  bucket (versioned/RETAIN/180d, pipeline user Put/Get+List only); the CDK
  assertion test now checks BOTH backup buckets (passes). `nightly.sh`'s trap
  reads `PIPELINE_BACKUP_BUCKET` (crontab, from the stack output) with a
  site-bucket fallback so backups never lapse. Remaining is the deploy — user
  only, local `rainhead` identity: `npx cdk diff BeeAtlasStack` (expect only
  the bucket + two pipeline-user statements + an output), `npm run deploy`,
  then set the crontab env. Unblocks `st-vjd`.
- **E — `st-nee` code DONE** (beeatlas `model-y` working tree, uncommitted;
  **not enabled anywhere**). The write path: every note-write route
  (create/edit/delete/takedown/restore), after `db_session.commit()`, calls
  `api/main.py:_publish_notes` → `data/publish-notes.sh`: the SAME
  `var/publish.lock` flock nightly takes (bounded wait, exit 75 = holder
  bakes the note) → `scripts/fetch-data.sh --from notes-harvest notes.json`
  (fetch-data now takes scope args; stelis derives the changed
  canonical_names from the store digest itself — no keys passed in) → `npm
  run build` → `data/merge-swap.sh` (nightly's step-6 rsync block, extracted
  as the shared publish contract). Responses carry `"publish": "live" |
  "pending"`; commit-first — every publish failure degrades to pending +
  loud log, never a rollback. Gated by `NOTE_PUBLISH_ENABLED`
  (env > `[launch] note_publish_enabled` toml > default OFF), so landing E
  with A+B+C is safe: writes keep working as pending until the operator
  flips the gate per runbook §7 (after §6 + one green nightly; also set
  Apache `ProxyTimeout 300` on api.beeatlas.net). Verified: 144 api tests
  pass (7 new); scoped stelis plan = exactly notes-harvest → notes-assemble
  (dry-run); merge-swap exercised against a scratch root (publish, prune,
  idempotence); lock-busy → 75 and absent-SITE_ROOT → 3 exercised.
- Then **`st-vjd`** teardown (after soak + D): site bucket, distribution,
  deploy IAM, `artifacts.py`'s now-vestigial verbs (`publish-plan`,
  `manifest`, `build-time-fetch`), and `pull-published`'s S3 dependence
  (repoint it at `https://beeatlas.net/data/` + the live slim manifest —
  note the slim manifest no longer names the baked artifacts it pulls today).

## Verify (for C/E, on maderas)

Full nightly renders + serves over HTTPS (burned-in notes, cache headers); a
note write round-trips (POST → reload shows the note); nightly and a write race
serialize on the flock.
