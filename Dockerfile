# syntax=docker/dockerfile:1
#
# The Stelis image (ADR 0017, st-9ov): Racket, the engine's packages and the engine
# itself, compiled, in one image built once per commit by the image workflow
# (.github/workflows/image.yml) and published as ghcr.io/rainhead/stelis:<commit>.
#
# A project that builds with Stelis takes the two trees out of it by digest instead
# of installing Racket and fetching the engine in its own Dockerfile:
#
#   ARG STELIS_IMAGE=ghcr.io/rainhead/stelis@sha256:...   # scripts/image-digest.sh <commit>
#   FROM ${STELIS_IMAGE} AS stelis
#   ...
#   COPY --from=stelis /opt/racket /opt/racket
#   COPY --from=stelis /opt/stelis /opt/stelis
#   ENV PATH=/opt/racket/bin:$PATH
#
# Both trees must land at the same paths: a unix-style Racket install records its
# prefix, and the engine's compiled bytecode records where its sources are. The
# host image must carry libcrypto (Debian's libssl3; see the final stage below).
#
# Build it by hand (the workflow passes the same arguments):
#
#   docker build --build-arg STELIS_COMMIT="$(git rev-parse HEAD)" -t stelis .
#   docker run --rm stelis --help
#
# What the build downloads: the pinned Racket build (racket-downloads.tsv, through
# STELIS_DOWNLOAD_MIRROR first when that build arg is given) and the packages from
# the sources racket-deps.txt pins, both through scripts/install-racket.sh, so the
# image installs exactly what a host running that script would. The packages are
# fetched here once, which is why they need no mirror of their own.

# Pinned by digest, the way the actions in .github/workflows are pinned by commit:
# the index digest of debian:bookworm-slim on 2026-10-21. Debian 12, the same base
# as salishsea's machine stage. To move it: `docker buildx imagetools inspect
# debian:bookworm-slim` and replace the digest and the date.
ARG DEBIAN_IMAGE=debian:bookworm-slim@sha256:7ff6ba31527b9e336162fa061746c366c4b2032f4d2cff2078bea43f78efe3f8

# --- install Racket and compile the engine -----------------------------------
FROM ${DEBIAN_IMAGE} AS build
RUN apt-get update \
 && apt-get install -y --no-install-recommends ca-certificates curl \
 && rm -rf /var/lib/apt/lists/*

# The install step reads only the six files it pins, so its layer is cached
# across engine commits that leave them alone: a change to src/ does not fetch
# Racket again.
ARG STELIS_DOWNLOAD_MIRROR
COPY scripts/install-racket.sh scripts/native-code.rkt scripts/preflight.sh /opt/stelis/scripts/
COPY racket-version racket-deps.txt racket-downloads.tsv /opt/stelis/
RUN STELIS_DOWNLOAD_MIRROR="$STELIS_DOWNLOAD_MIRROR" \
      bash /opt/stelis/scripts/install-racket.sh --prefix /opt/racket
ENV PATH=/opt/racket/bin:$PATH

# The engine: the whole checkout (.dockerignore keeps out .git, the beads database
# and local state), compiled, with the commit it came from written beside it so a
# consumer's build can assert that the digest it pinned is the commit it meant.
ARG STELIS_COMMIT
COPY . /opt/stelis/
RUN test -n "$STELIS_COMMIT" \
 && echo "$STELIS_COMMIT" > /opt/stelis/commit \
 && raco make /opt/stelis/src/main.rkt \
 && bash /opt/stelis/scripts/link-collection.sh \
 && bash /opt/stelis/scripts/preflight.sh \
 && racket /opt/stelis/src/main.rkt --help > /dev/null

# --- the image: the two trees on a bare base ---------------------------------
# A consumer of this image is the stage below: it copies the two trees and sets
# PATH. Nothing the install needed (curl, the CA store) comes along. What does
# come from the base is the shared libraries the trees load: glibc and zlib,
# which Racket links, and libcrypto, which the sha package opens through the FFI
# (its SHA-1 is what addresses every 'file artifact). On Debian that is libssl3;
# the build stage had it only as a dependency of the CA store, and so does a
# consumer that installs curl, which is why no preflight saw it missing until
# the suite ran in this stage.
FROM ${DEBIAN_IMAGE}
RUN apt-get update \
 && apt-get install -y --no-install-recommends libssl3 \
 && rm -rf /var/lib/apt/lists/*
COPY --from=build /opt/racket /opt/racket
COPY --from=build /opt/stelis /opt/stelis
ENV PATH=/opt/racket/bin:$PATH
ARG STELIS_COMMIT
LABEL org.opencontainers.image.source=https://github.com/rainhead/stelis \
      org.opencontainers.image.revision=$STELIS_COMMIT \
      org.opencontainers.image.title=stelis \
      org.opencontainers.image.description="Stelis: Racket, its packages and the compiled engine, at one commit"
ENTRYPOINT ["racket", "/opt/stelis/src/main.rkt"]
CMD ["--help"]
