# ADR 0020 — A project's graph lives in the project's repository

**Status:** accepted · **Horizon:** 2 (operations) · **Date:** 2026-10-26 (st-ab3; the owner's call after salishsea's register move, salish-vedj)

A project's graph, the Racket module that declares its artifacts, tasks, runtimes and resolvers as one `project` value, may live in the project's own repository, beside the scripts it names. The engine is a Racket collection, `stelis`, that such a module requires by collection path, and `--project` takes the module's path as well as a registered name. salishsea moves first; beeatlas follows when its graph next changes.

## Context

Every graph has lived in this repository, in `src/beeatlas.rkt` and `src/salishsea.rkt`, and every change to one has been a Stelis commit. The register move showed what that costs. The move changed the engine (a DuckDB file attached read-only beside the SQLite mirrors), the graph (where `register.*` lives and what two tasks are handed), and salishsea's scripts (what they open), and the graph's half and the scripts' half are one change: a task's arguments and the script that reads them. Kept in two repositories, they became two pull requests that could not land apart, a pin computed only after the image published, a merge order with a warning attached ("nobody bump the pin in between"), and a commit stranded on a branch reused after its pull request had merged. The same shape held for the two-project split. Of this week's seven engine pull requests, three were salishsea's graph and nothing else.

The graph's own tests are the other half of the cost. salishsea-test, the checkout test, the keys test and the TypeScript import comparison check the graph against the salishsea checkout, and in this repository's CI there is no checkout, so they skip. The drift they guard against happens in salishsea's repository, on pull requests that CI never sees.

## Decision

1. **The engine is a collection.** `src/info.rkt` names it `stelis`, and `scripts/link-collection.sh` links it, at installation scope in the image and in CI and at user scope on a developer's machine. A graph outside this repository requires `stelis/model`, `stelis/project`, `stelis/relation-digest` and the rest. The engine's own modules keep requiring each other by relative path, so nothing here needs the link to run.

2. **`--project` takes a module path.** A path (anything with a separator or ending in `.rkt`) is loaded with `dynamic-require` and must provide `project`, a project value; the registered names stay for the graphs still kept here. A missing module, a module without `project`, and a `project` that is not a project value are each refused by name.

3. **A project repository owns its graph, its graph's tests and its engine pin.** The graph module and the four tests move to salishsea-io (`salish-dhts`), where CI runs them inside the Stelis image, with the checkout present. The Dockerfile compiles the module against the engine it copied from the image. A change to the graph and to the scripts it names is then one pull request and one deploy, and the pin moves only for engine changes.

4. **The project-facing API is an interface to keep.** `make-project`, `make-task`, `make-artifact`, the recipe and runtime constructors, `sqlite-db` and `duckdb-db`, `store-keyed` and the resolvers' shapes are what a graph outside this repository binds to. A change to them is made compatible where it can be, as `attached-db` was, and otherwise lands with the consumers' pins moved in the same arc, which is the dance this decision removes from everything else.

## Rejected alternatives

- **Keep the graphs here and script the dance.** A workflow that opens the consumer's pin pull request when an image publishes would shorten the wait but not remove the lockstep, and the graph's tests would still run without the checkout they test against.
- **Move the engine into salishsea-io.** The engine serves two projects and is the thing being built; its consumers are case studies. The dependency points the other way.
- **A project's graph in a third repository.** One more place to coordinate, with neither the engine nor the scripts beside it.

## Consequences

- Racket appears in a TypeScript repository, as a declaration rather than application code; salishsea's one-language rule is noted as bent, not broken. The image gives its CI and Dockerfile the Racket to run it.
- The engine's registry shrinks as graphs move out, to beeatlas and then to nothing; `--project` without a path then needs a default that is not a registered name, which is a later change.
- The "known projects" the engine can name on a machine are the ones it was linked with; a graph by path can be anyone's, so the state-dir ownership check (st-z1c), which keys on the project's name, is what keeps two graphs from sharing a state dir.
