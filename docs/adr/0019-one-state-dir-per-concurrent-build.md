# ADR 0019 — One state dir per concurrent build, so salishsea is two projects

**Status:** accepted · **Horizon:** 2 (operations) · **Date:** 2026-10-25 (st-mxr.1.2, under the st-mxr epic; follows [ADR 0018](0018-a-build-yields-to-a-waiting-one.md))

A checkout may declare more than one project, each a graph over its own state dir. salishsea declares two: `salishsea-ingest`, the four source ingests, and `salishsea`, everything from the snapshot on. Both are built from one authored task list, partitioned, and what the ingests write is read on the derive side as upstream leaves.

## Context

A save's build on salishsea should not wait behind the five-minute scheduled build. ADR 0018 lets a waiting build ask the running one to let go, which bounds the wait by one task. But the scheduled build's longest tasks are the ingests, which are network-bound and must not be interrupted mid-fetch, so a save that lands during an iNaturalist sweep still waits for it. The way past that is for the ingests not to hold the lock the save needs at all: two builds that may overlap.

The engine's state dir assumes one writer. The history line is numbered from the line before and written by several write calls. A prune rewrites the log beside itself. The relation observer holds a relation's digest until a task in the same process writes the relation, so a second process writing it would make the first record facts about content it did not see. None of that is worth making multi-writer for two builds that share no task.

## Decision

1. **The unit of concurrency is the state dir, and a state dir belongs to one project.** The engine already refuses a state dir holding another project's builds (st-z1c). So two builds that must run side by side are two projects, each with its own default state dir, and a host that sets `STELIS_STATE_DIR` sets a different one for each.

2. **A project module may export several projects from one authored list.** salishsea.rkt authors its tasks once and partitions them by name: the ingest graph holds the four boundaries and what they read and write, the derive graph the rest. A task is in exactly one graph, which a test holds.

3. **What crosses the cut is the same artifact on both sides, declared upstream on the consuming side.** A relation an ingest produces is `'derived` with a producer in the ingest graph and `'upstream` with no producer in the derive graph: somebody else's data, snapshotted in, which is what ADR 0013's third value was for. Only the provenance differs: the name, the artifact kind (a database relation), the table it names and the digest it is observed by are the same in both graphs, so a record on either side names the same fact, and a reader can follow a why across the cut by content rather than by build number (st-mxr.1.3).

4. **The split makes two state dirs possible, not two builds at once.** Until the register leaves the snapshot DuckDB file (salishsea `salish-vedj`), ingest-register writes into it and ingest-inaturalist reads from it, and DuckDB lets one process hold a file for writing with nobody else open. salishsea serializes the two builds under its lock until then.

## Rejected alternatives

- **One graph, two invocations.** `--build` of the ingest targets outside the lock and of the rest inside it. Two engine processes on one state dir, which is the thing the state dir does not support.
- **Make the state dir multi-writer.** Numbering under a lock, an append in one write, a prune that merges concurrent appends, an observer that re-checks. All for two builds whose task sets are disjoint; a graph each is the smaller change and the truer model.
- **Keep the whole graph as a third project.** The union would declare every task twice and invite building it, which is what the split exists to prevent.

## Consequences

- `--project salishsea --all` builds 22 tasks, not 26. A host's schedule must build `salishsea-ingest` as well, with its own state dir and before the derive build; the save path builds only `salishsea`. salishsea's share is `salish-mee7`.
- `--why` in the derive graph ends at the mirror: "maplify_mirror.sightings changed". The ingest graph's history says why it changed. Continuing the walk across the cut is st-mxr.1.3.
- The relation observer is one per graph, since what is pending depends on which graph's boundaries are still to run.
