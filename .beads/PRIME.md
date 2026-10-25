# Beads workflow

This repo tracks its work in beads (`bd`). This file replaces the default text of `bd prime`. The repo's AGENTS.md (or CLAUDE.md) says how beads fits with GitHub Issues, commits and pull requests, and wins wherever the two differ.

## Rules

- Track work in beads, not TodoWrite, TaskCreate or markdown TODO lists. File an issue before writing code, and claim it when you start.
- **Sync beads without asking.** Run `bd sync` after filing, changing or closing issues, and before you finish. It pulls, stops on any conflict it can't settle, and pushes to `refs/dolt/data` on the GitHub remote. It never touches a git branch, so it needs none of the permission that `git push` does. The SessionStart hook runs it too, so a session starts with the other machine's changes.
- **Beads data is public.** The repo is public, and anyone can fetch `refs/dolt/data`, so everything in beads can be read by anyone: issues, notes, comments and memories. Don't use `bd remember`; keep persistent knowledge in Claude's file memory, which syncs between machines privately.
- Never run `bd edit`: it opens an editor and blocks.

## Before you finish

1. `bd close <id> ...` for finished work, with `--reason` when the reason isn't obvious.
2. Run the quality gates that apply: tests, linters, builds.
3. `bd sync`.
4. Commit and push code only as the repo's instructions allow.

## Commands

- Finding work: `bd ready`, `bd list --status=open`, `bd list --status=in_progress`, `bd show <id>`, `bd search <text>`
- Creating: `bd create --title="..." --description="..." --type=task|bug|feature|epic|chore --priority=2`. Priority is 0 to 4: 0 is critical, 2 medium, 4 backlog (not "high" or "low"). `--parent=<id>` makes a child; `--design`, `--acceptance` and `--notes` fill those sections.
- Updating: `bd update <id> --claim`, `bd update <id> --notes="..."`, `bd unclaim <id>`, `bd defer <id> --until=<date>`, `bd supersede <id> --with=<id>`
- Dependencies: `bd dep add <issue> <depends-on>`, `bd blocked`
- Closing: `bd close <id> ...`, `bd close <id> --suggest-next`
- Health: `bd stats`, `bd stale`
