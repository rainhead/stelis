# ADR 0017 — Stelis ships as an image per commit, and consumers pin its digest

**Status:** accepted · **Horizon:** 2 (operations) · **Date:** 2026-10-21 (st-9ov; the install script it builds on is st-2t1)

Every host that runs Stelis is now a container built from a Dockerfile: salishsea's
Fly machine already, beeatlas's once it leaves maderas (beeatlas-gcdo). **Stelis's own
CI builds one image per commit, holding Racket, the engine's packages and the engine
compiled, and publishes it as `ghcr.io/rainhead/stelis:<commit>`. A project that
builds with Stelis copies two trees out of that image by digest instead of installing
Racket and fetching the engine in its own Dockerfile.**

## Context

[st-2t1](../../scripts/install-racket.sh) gave Stelis one script that installs the
Racket it runs on: the pinned minimal build from `racket-downloads.tsv`, mirror first,
and the packages from the sources `racket-deps.txt` pins. salishsea's `fly/Dockerfile`
calls it, Stelis's CI calls it, and beeatlas's Dockerfile was about to. That removed
three copies of the steps, but each image build still does the work: a two-minute
Racket install, a package fetch from Racket's catalog host and GitHub, a tarball of
the engine from GitHub, and a `raco make`. Each of those is a host the consumer's
deploy depends on. salishsea-io#727 was Racket's download host redirecting to a mirror
Debian did not trust; CodeRabbit's review of salishsea's install step pointed out that
the packages are pinned but still fetched from two more hosts on every build. Mirroring
them properly would mean copying a package catalog into salishsea's bucket, for a
problem beeatlas would then have again.

There is a second cost on the consumer side. salishsea's image must build on Fly's
remote builder, because Racket CS does not run under Docker's x86_64 emulation on
Apple silicon, so the Racket install and the engine compile cannot run in a local
build there.

The slotting rule's second arm (ROADMAP, 2026-10-21) is what admits this: two projects
that build with Stelis are about to provision it separately, and each one's deploy is
worse for it.

## Decisions

**D1. One image per commit, built by Stelis's CI, tagged with the commit and nothing
else.** The [image workflow](../../.github/workflows/image.yml) builds the
[Dockerfile](../../Dockerfile) on every pull request and push to main, runs the test
suite inside the result, and on main pushes it as `ghcr.io/rainhead/stelis:<40-character
commit>`. There is no `latest` and no branch tag, so the only tag an image has is the
commit it was built from; a consumer names it by digest (D2). The image carries the
commit twice: as the OCI `revision` label, and as `/opt/stelis/commit` inside the tree.

**D2. Consumers pin the digest, and the pin is checked in both directions.** A tag can
be moved; a digest names one set of bytes. `scripts/image-digest.sh <commit>` resolves
the tag to its digest and refuses unless the image's revision label is that commit,
so a consumer's pin is the pair (commit, digest) with each vouching for the other. The
consumer's own build then asserts `/opt/stelis/commit` against the commit it pinned, so
a digest pasted from the wrong commit fails the image build rather than running the
wrong engine. salishsea's `fly/stelis-commit` keeps naming the commit, which is what a
release names and what its mirror script reads; the digest sits beside it.

**D3. Consumers COPY two trees; the image is also usable FROM.** Racket installs
unix-style under `/opt/racket` and the engine, compiled, under `/opt/stelis`, and a
consumer takes exactly those:

```dockerfile
ARG STELIS_IMAGE=ghcr.io/rainhead/stelis@sha256:...
FROM ${STELIS_IMAGE} AS stelis
...
COPY --from=stelis /opt/racket /opt/racket
COPY --from=stelis /opt/stelis /opt/stelis
ENV PATH=/opt/racket/bin:$PATH
```

COPY rather than FROM, because a consumer's base is its own choice (salishsea's machine
stage is `debian:bookworm-slim` with node copied in from the node image), and a FROM
would make the Stelis image the place that choice is made. The trees must land at the
same paths: a unix-style install records its prefix, and the compiled bytecode records
where its sources are. The image is itself `debian:bookworm-slim`, pinned by digest, so
`FROM` it works for a host that wants nothing else; its entrypoint is the engine.

**D4. The image's final stage is a consumer, and the suite runs in it.** The
Dockerfile installs and compiles in a build stage and copies the two trees onto a bare
base, the way a consumer will. The workflow then runs `raco test` inside that stage as
a non-root user on a read-only filesystem, which is how salishsea's machine runs the
engine. The first run of that gate found that the `sha` package opens libcrypto
through the FFI and the bare base has none: the build stage had it only as a
dependency of the CA store, and so does any consumer that installs curl, which is why
neither preflight nor salishsea's build had ever seen it missing. The final stage
installs `libssl3`, and the Dockerfile says a consumer's base must carry it too.
That is the whole of what the copied trees ask of their host: a glibc and zlib the
Racket binary links against, which any Debian 12 base has, and a libcrypto for the
FFI, which on Debian is `libssl3`. A base that lacks one completes the COPY and
fails when `racket` starts; a consumer that cannot supply them takes the image
`FROM` instead, which carries all three. Preflight in the build stage proves the
install; only the suite in the final stage proves the image.

**D5. The image build downloads what the install script downloads, once.** The build
stage runs `install-racket.sh`, so the image installs exactly what a host running that
script would, from the same pinned build, through `STELIS_DOWNLOAD_MIRROR` first when a
build gives one. The packages are fetched in that stage and nowhere else afterwards,
which is the answer to the CodeRabbit note: the image is the package mirror, so no
catalog copy is needed. The Racket layer is keyed by the five files the install reads
and cached across engine commits that leave them alone.

**D6. What the image deliberately does not hold.** The DuckDB CLI, which the engine
runs as a subprocess to content-address relations: its version is coupled to the
project's DuckDB library (the one that writes the files the CLI reads), so it stays a
project's pin, in `fly/downloads.tsv` for salishsea and in Stelis's own CI for the
tests. The projects' toolchains (uv, node, dbt), for the same reason. And git: the
engine's build clock (ADR 0004) reads a project checkout's committer date, and a host
without that checkout pins `SOURCE_DATE_EPOCH`, as CI does.

## Consequences

- A consumer's Dockerfile loses the Racket download, the package fetch, the engine
  tarball and the compile. Its deploy depends on one more registry, ghcr.io, and on
  two fewer upstreams (Racket's catalog and GitHub's tarball endpoint; the Racket
  installer mirrors leave too, since the image build is where they are reached).
- Moving Stelis for a consumer is: pick the commit, run `scripts/image-digest.sh` on
  it, and change the commit and the digest in one pull request. The image exists a few
  minutes after the commit lands on main; the script says so when it does not yet.
- beeatlas's offline gate (beeatlas-3je9: a nightly in the container with egress to
  code and package hosts blocked) gets the engine as a layer rather than a fetch.
- salishsea's image build no longer runs Racket for anything but its own smoke check,
  so a local build on Apple silicon is one step closer to possible.
- The install script stays: it is how the image is built, how CI tests the install
  path, and the way onto a host that is not a container.
- The image is public on ghcr.io, as the repo is. The first push creates the package;
  that it is public has to be confirmed in the GitHub packages settings once.
- Size: 607 MB, most of it the Racket prefix (the `--auto` dependency walk pulls
  gui-lib in, as st-2t1 noted). A trim is possible and separate.
