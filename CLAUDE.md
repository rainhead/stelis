# CLAUDE.md

Operating instructions for an agent working in this repo. Keep this short. The
*what* and *why* live in `DESIGN.md` and `ROADMAP.md` — this file is for not
making predictable mistakes.

## Orient first

- Read `DESIGN.md` and `ROADMAP.md` before starting work.
- Treat `DESIGN.md`'s **settled commitments as decided** — don't relitigate them;
  raise a flag if one seems wrong, don't quietly work around it.
- Treat `ROADMAP.md`'s **horizons as the scope guard.** We are in **Horizon 0**.
  If a request would build a Horizon 1+ feature, say so before building it.

## What this is (one line)

Stelis is the build system. `~/dev/beeatlas` and `~/dev/salishsea-io` are
**case studies / test beds**, not the thing being built. Don't revamp them.

## Environment facts that cause real mistakes

- **Two conflicting Python interpreters in one pipeline.** dlt loaders need Python
  3.14; dbt needs 3.13 (dbt-core hard-crashes on 3.14 — `mashumaro
  UnserializableField`, on every machine). Per-task hermetic runtimes are the
  point, not a workaround.
- Secrets inject hermetically and must **never** reach logs.
- (Stub — fill in as Horizon 0 lands: how to build, how to run, how to test,
  project layout.)

## Standing guardrails (most-violated commitments)

These are in `DESIGN.md`; repeated here because they're the ones easiest to break
in code:

- **Transformations stay external in Horizon 0.** Orchestrate dlt / dbt /
  exporters; do **not** reimplement their logic in Racket.
- **Derived vs. authoritative.** Derived outputs are safe to destroy and rebuild;
  authoritative state is forward-only — **never rebuild it from scratch**
  (migrations only).
- **Effects at the boundary.** The derivation core stays pure; IO, ingestion,
  secrets, and rendering are declared boundary nodes.
- **Content-addressed, not timestamped.** Change is measured by content hash.
- **Determinism is a day-one property.** Build the same snapshot twice, compare
  hashes. Watch DuckDB parallelism, floating point, and spatial joins.

## Working mode

- Interactive and didactic. Be deliberate about what functionality is taken on in
  what order; the design space is large and the known failure mode is getting lost
  in it.
- When a request would pull scope forward a horizon, flag it rather than silently
  building it.
- Prefer small, working, end-to-end increments over broad scaffolding.

## Stack

- Core in **Racket** (Rhombus later, per-module, optional). Engine runs
  server-side; the browser is reached by **emission** (compile a small targeted
  artifact), not by running the engine in the browser.
- State in memory for now; a database later (representation designed to allow it).


<!-- BEGIN BEADS INTEGRATION v:1 profile:minimal hash:7510c1e2 -->
## Beads Issue Tracker

This project uses **bd (beads)** for issue tracking. Run `bd prime` to see full workflow context and commands.

### Quick Reference

```bash
bd ready              # Find available work
bd show <id>          # View issue details
bd update <id> --claim  # Claim work
bd close <id>         # Complete work
```

### Rules

- Use `bd` for ALL task tracking — do NOT use TodoWrite, TaskCreate, or markdown TODO lists
- Run `bd prime` for detailed command reference and session close protocol
- Use `bd remember` for persistent knowledge — do NOT use MEMORY.md files

**Architecture in one line:** issues live in a local Dolt DB; sync uses `refs/dolt/data` on your git remote; `.beads/issues.jsonl` is a passive export. See https://github.com/gastownhall/beads/blob/main/docs/SYNC_CONCEPTS.md for details and anti-patterns.

## Session Completion

**When ending a work session**, you MUST complete ALL steps below. Work is NOT complete until `git push` succeeds.

**MANDATORY WORKFLOW:**

1. **File issues for remaining work** - Create issues for anything that needs follow-up
2. **Run quality gates** (if code changed) - Tests, linters, builds
3. **Update issue status** - Close finished work, update in-progress items
4. **PUSH TO REMOTE** - This is MANDATORY:
   ```bash
   git pull --rebase
   git push
   git status  # MUST show "up to date with origin"
   ```
5. **Clean up** - Clear stashes, prune remote branches
6. **Verify** - All changes committed AND pushed
7. **Hand off** - Provide context for next session

**CRITICAL RULES:**
- Work is NOT complete until `git push` succeeds
- NEVER stop before pushing - that leaves work stranded locally
- NEVER say "ready to push when you are" - YOU must push
- If push fails, resolve and retry until it succeeds
<!-- END BEADS INTEGRATION -->
