# Agent Instructions

Start with **[`CLAUDE.md`](CLAUDE.md)** — it is the governing operating guide for
this repo (orientation, guardrails, working mode) and covers the points below in
context.

Work is tracked in **bd (beads)**. Run `bd prime` for the full command reference.

```bash
bd ready                # Find available work
bd show <id>            # View issue details
bd update <id> --claim  # Claim work
bd close <id>           # Complete work
```

Commit and push code only when the user asks. Beads are the exception: sync them
with `bd sync` without asking (see the beads section of `CLAUDE.md`).
