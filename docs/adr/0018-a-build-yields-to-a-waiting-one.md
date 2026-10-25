# ADR 0018 — A build yields to a waiting one at a task boundary

**Status:** accepted · **Horizon:** 2 (operations) · **Date:** 2026-10-25 (st-mxr.1.1, under the st-mxr epic: a user command posted to an API takes effect within three seconds)

A build that holds the lock a project builds under can be asked to stop. It finishes the task it is on, records every task it has not reached as **yielded**, appends the build to the history as usual, and exits with a distinct code so that its caller takes the lock again and reruns it. The engine never takes the lock itself, and it never stops a task part way through.

## Context

salishsea's write API starts a build after every save ([decision 065](https://github.com/salish-sea/salishsea-io/blob/main/docs/decisions/065-the-store-and-write-api.md)), scoped to the store and what derives from it. It shares one lock with the five-minute scheduled build, which runs the three source ingests and everything downstream, thirty to fifty seconds of task CPU. A save's build that found the lock held exited and was retried after a fixed thirty seconds, so a save that landed during a scheduled build reached the site half a minute late however fast the build itself was.

The inventory behind the st-mxr.1 design asked what the lock protects, with an eye to letting the two builds run side by side. The answer rules that out. Beyond the two-rename directory swap and the engine's own state writes, salishsea's snapshot DuckDB file is a hub: one process may hold it for writing, and while one does, no other process may open it at all. Both builds write it on every run and nearly every task opens it. The engine's state directory likewise assumes one engine process, and nothing enforces it: the history line is numbered from the line before and written by several write calls, a prune rewrites the log beside itself, and the relation observer holds a digest until a task in the same process writes the relation. Two builds on one state directory would not interleave badly. The second would fail or record facts about content it did not see.

So the question is not how two builds share a state directory but how one waiting build gets the lock sooner.

## Decision

1. **The request is a file in the state directory, `<state-dir>/yield`.** A caller that wants the lock creates it, blocks on the lock, and removes it once it holds the lock. The engine looks for it before each task's decision. A file rather than a signal: it needs no process id, which matters because `pgrep -f` against a build launched through `sh -c` matches the wrapper shell as well; it passes through a cron runner and a container unchanged; and it can be seen. Honoring the request removes the file, so a request nobody is waiting on yields one build and not every one after it.

2. **The engine yields between tasks and nowhere else.** Between two tasks every shared object is quiescent: no DuckDB file is open, no directory is half swapped, every receipt is complete. Yielding there changes no single-writer assumption, which is why the engine can do it without knowing what its tasks write. A yielded task is recorded with outcome `'yielded`, no decision and no observation, and the plan ends. The build is appended to the history as far as it got, and `--explain --last` and the build log say what was yielded and why.

3. **A yielded build exits 3 and writes no build report.** Exit 1 means partial success with nothing to rerun. The shell's exit 75 means the lock was held and the caller skipped. Exit 3 means the caller should take the lock again and rerun the build, which decides every task afresh against the content the preempting build left; the tasks that ran before the yield are current and skip. A build report (`--report-dir`) is an answer about the target, and a yielded build has none, so the rerun writes it.

4. **The engine does not take the lock.** It belongs to the project's shell, which already uses it for deploys and maintenance ([salishsea decision 066](https://github.com/salish-sea/salishsea-io/blob/main/docs/decisions/066-a-deploy-takes-the-build-lock-and-the-machine-stops-its-writers.md)). The protocol between the two is the file, the exit code, and nothing else.

## Rejected alternatives

- **Run the two builds side by side.** Impossible on one snapshot file, and the engine's state is single-writer. Where two builds genuinely do not share outputs, the answer is two graphs with two state directories (st-mxr.1.2), not two processes on one.
- **Kill the running build.** Safe for the data under ADR 0013, since every derived artifact is safe to destroy and rebuild and every salishsea producer recovers a half-swapped directory. But the killed build leaves no history record and the cron monitor reads it as a failure, and killing the engine alone orphans the task process, which keeps the snapshot file open. A vanished build is worse than a yielded one.
- **Kill the running task, then yield.** Bounds the wait by nothing rather than by one task. Left for later, once the plain yield has been measured: a boundary must never be killed mid-ingest, and the gain over a yield is one task's remaining run time.
- **Join in process.** The engine runs the waiting build's plan itself and resumes. Saves one launch and costs two history records from one process and a plan recomputed mid-run. A refinement for when the launch time matters.
- **A signal rather than a file.** Needs the engine's pid, which the caller does not reliably have (see 1).

## Consequences

- A save's build waits for at most the task the scheduled build is on, not the whole build. On salishsea today that is under two seconds for most tasks and 8.6 s for the Darwin Core archive.
- The caller owes a loop: on exit 3, take the lock again and rerun. salishsea's is `salish-vpru`; beeatlas's nightly and note publish share a lock the same way and can use the same protocol.
- `'yielded` joins the outcome vocabulary (`trace.rkt`). Every history reader that enumerates outcomes keys on `'ok`, so older records and newer readers agree.
- Splitting salishsea into an ingest graph and a derive graph (st-mxr.1.2) narrows "one task" to "one derive task", so a save never waits behind an iNaturalist sweep.
