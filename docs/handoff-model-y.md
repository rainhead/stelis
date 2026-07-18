# Resume — Model Y (ADR 0007 Amendment)

Operational handoff for the Model-Y arc. The **design** is in
[`docs/adr/0007-serve-from-build-host.md`](adr/0007-serve-from-build-host.md)
(the Amendment section); the **work items** are beads with full descriptions
(implementation notes on each).

## LANDED (2026-07-17, evening)

**A+B+C+E are on both `main`s and live on maderas.** The landing checklist ran
in one sitting: DNS verified at maderas → both `model-y` branches merged +
pushed → §6 migration (htdocs+var, DuckDB persistent at
`var/beeatlas.duckdb`, vhost + `-le-ssl` repointed, apache reloaded) → hand-run
nightly **green end-to-end** (first-run diff tests skipped as designed; stelis
31 ok · 4 cached · 0 failed in 309s; gate passed; merge-swap published in 2s;
baseline snapshotted; offsite backup trap ran) → cron re-enabled. The slim
manifest + hashed artifacts serve 200 over HTTPS. **Tonight's 03:00 nightly is
the soak start.**

**E is enabled in production**: `NOTE_PUBLISH_ENABLED=true` in the
`beeatlas-api` systemd user unit. Verified on maderas: a hand-run
`data/publish-notes.sh` completes in **~26s** (scoped stelis → 22s render →
2s merge-swap — under Apache's default 60s proxy timeout), and a held
`publish.lock` produces the bounded-wait → exit 75 tempfail with no build
work. Beads: st-5em, st-mfb, st-jeu **closed**; st-bgy was already closed.

## What remains (beads carry the detail)

- **E — `st-nee` (in progress, nearly done).** Two items before close:
  1. The human round-trip: sign in as an author, POST a note, see
     `"publish": "live"` (~30s POST), reload the species page — the note is
     burned in. (The live island shows `@login` immediately; full display
     name upgrades at the next bake — expected.)
  2. `ProxyTimeout 300` on the `api.beeatlas.net` vhost (sudo). Only matters
     for a CONTENDED write (up to 60s lock wait + 26s build > the 60s
     default); an uncontended publish fits under the default.
- **D — `st-pry` code DONE, deploy pending** (user only, local `rainhead`
  identity): `npx cdk diff BeeAtlasStack` (expect only the
  `PipelineBackupBucket` + two pipeline-user statements + an output),
  `npm run deploy`, then set `PIPELINE_BACKUP_BUCKET` in the maderas crontab
  from the stack output. Until then the trap falls back to the site bucket —
  backups never lapse. Unblocks `st-vjd`.
- **`st-vjd`** teardown (after soak + D): site bucket, distribution, deploy
  IAM, `artifacts.py`'s now-vestigial verbs (`publish-plan`, `manifest`,
  `build-time-fetch`), and `pull-published`'s S3 dependence (repoint at
  `https://beeatlas.net/data/` + the live slim manifest — note the slim
  manifest no longer names the baked artifacts it pulls today).
- **`st-29z`** (P3): the surviving `js-tests.yml` CI leg is red on main from
  17 PRE-EXISTING prime/sw env failures (no Cache API in CI jsdom — same
  count locally at clean HEAD). Fix the env or quarantine so the leg means
  something.

## Soak watch (first nights)

- Nightly log: `~/beeatlas-nightly.log` on maderas; healthcheck ping at the
  end. Second night exercises the diff tests against a REAL baseline for the
  first time.
- A note write during the 03:00 window correctly returns `pending` (exit 75
  path) and is baked by that same nightly if its harvest hadn't run yet.
