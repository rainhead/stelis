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

**E is live and round-tripped**: `NOTE_PUBLISH_ENABLED=true` in the
`beeatlas-api` systemd user unit; a hand-run `data/publish-notes.sh` takes
**~26s** (scoped stelis → 22s render → 2s merge-swap), and a held
`publish.lock` gives the bounded-wait → exit 75 tempfail with no build work.
**The first production write found a real stelis bug (st-28p, fixed same
night, stelis 52c7276):** the keyed notes store was input-addressed by file
BYTES, which SQLite WAL freezes while a long-running writer holds the store —
so notes-harvest read "unchanged" and the POST published a stale harvest as
"live". Keyed stores are now addressed by the roll-up of their per-key
digests (the same boundary read the observation layer records); the stranded
note re-harvested targeted (1 key) and is verified burned into
`species/Bombus/fervidus/` over HTTPS. Beads: st-5em, st-mfb, st-jeu,
st-nee, st-28p **closed**; st-066 unblocked.

## What remains (beads carry the detail)

- ~~ProxyTimeout~~ — done 2026-07-17: `ProxyTimeout 300` set on the
  `api.beeatlas.net` vhost (covers the contended-write case: up to 60s lock
  wait + 26s build exceeds Apache's 60s default).
- ~~D — `st-pry`~~ — deployed 2026-07-17. `PipelineBackupBucket` live,
  crontab carries the RESOLVED bucket name (gotcha: `cdk diff` prints the
  output as `{Ref: logical-id}`; the real name only exists post-deploy in
  the stack outputs — `aws cloudformation describe-stacks`). Pipeline-user
  List+Put verified from maderas. First full DuckDB backup lands with
  tonight's nightly trap. `st-vjd` is now blocked only by the soak.
- ~~**`st-vjd`** teardown~~ — done 2026-07-19 after a 2-night green soak:
  site bucket + site distribution + GitHub OIDC deployer deleted (CDK);
  `GET /api/notes` live-read + the island's D-02 re-fetch replaced by
  reload-sees-it (`publish:"live"` → `location.reload()`; the harvest now
  bakes `body_md` so the editor prefills from the page); `artifacts.py`
  verbs pruned (`pull-plan` replaces `baseline-pull-plan` for the slim
  manifest); `pull-published.sh` is credential-free HTTPS; `nightly.sh`
  fails loud (EX_CONFIG) if `PIPELINE_BACKUP_BUCKET` is unset. On AWS now:
  DNS, the .com→.net redirect (origin swapped off the dead bucket), two
  backup buckets.
- ~~**`st-29z`**~~ — closed 2026-07-19: misdiagnosed. The CI red was 2-3
  data-dependent test files (ENOENT on gitignored `public/data`), fixed by
  the beeatlas test split (86f82021); the "17 env failures" were a
  wrong-Node artifact (v26 gates `localStorage` behind a flag — the pinned
  24.18 is green). Test-log stderr noise silenced separately (e50473a1).

## Soak watch (first nights)

- Nightly log: `~/beeatlas-nightly.log` on maderas; healthcheck ping at the
  end. Second night exercises the diff tests against a REAL baseline for the
  first time.
- A note write during the 03:00 window correctly returns `pending` (exit 75
  path) and is baked by that same nightly if its harvest hadn't run yet.
