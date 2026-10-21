#!/usr/bin/env bash
# Install the Racket the engine runs on, with the packages it needs (st-2t1):
#
#   scripts/install-racket.sh --prefix /usr/local        # a container image
#   scripts/install-racket.sh --prefix "$HOME/racket"    # CI, a developer machine
#
# One place for the version (racket-version), the build and its checksum
# (racket-downloads.tsv), the mirrors, and the packages with their pinned sources
# (racket-deps.txt). Every host that runs Stelis calls this instead of carrying its
# own copy of those steps: salishsea's fly/Dockerfile, beeatlas's, Stelis's own CI.
#
# What it does: picks this platform's row from racket-downloads.tsv; fetches the
# installer from STELIS_DOWNLOAD_MIRROR/<sha256> if that is set, then from each
# upstream URL, keeping the first whose bytes match the sha256; installs the
# minimal distribution under --prefix (bin/racket, bin/raco, share/racket); installs
# racket-deps.txt's packages at installation scope from the sources it pins, without
# documentation; and runs scripts/preflight.sh against the result, so a host that
# gets this far can load everything the engine requires.
#
# Rerunning it is cheap: a prefix already holding this version, whose packages load,
# is left alone. It installs a minimal Racket and manages only that prefix; it does
# not touch a distribution the host installed some other way.
#
# Exit codes: 2 for a usage or platform problem, 1 for a download or install that
# failed, 78 (EX_CONFIG, preflight's) when the install finished but the engine's
# collections still do not load.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STELIS_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

prefix=
while (( $# > 0 )); do
    case "$1" in
        --prefix) prefix=${2:?--prefix needs a directory}; shift 2 ;;
        -h|--help) sed -n '2,25p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "install-racket.sh: unknown argument $1" >&2; exit 2 ;;
    esac
done
if [[ -z "$prefix" ]]; then
    echo "usage: install-racket.sh --prefix <dir>" >&2
    exit 2
fi

version="$(tr -d '[:space:]' < "$STELIS_DIR/racket-version")"
racket="$prefix/bin/racket"
raco="$prefix/bin/raco"

# --- 0. already done? ----------------------------------------------------------
if [[ -x "$racket" ]] && [[ "$("$racket" --version 2>/dev/null)" == *"v$version "* ]] \
    && PATH="$prefix/bin:$PATH" bash "$SCRIPT_DIR/preflight.sh" > /dev/null 2>&1; then
    echo "install-racket.sh: $prefix already holds Racket $version and every collection loads"
    exit 0
fi

# --- 1. which build ------------------------------------------------------------
os="$(uname -s | tr '[:upper:]' '[:lower:]')"
arch="$(uname -m)"
name="racket-$arch-$os"
line="$(grep -v '^#' "$STELIS_DIR/racket-downloads.tsv" | awk -v n="$name" '$1 == n')"
if [[ -z "$line" ]]; then
    echo "install-racket.sh: no pinned Racket $version build for $arch-$os in racket-downloads.tsv" >&2
    echo "  Add a row there (name, sha256, URLs) for this platform." >&2
    exit 2
fi
# shellcheck disable=SC2086 # the row is whitespace-separated on purpose
set -- $line
sha=$2
shift 2
urls=("$@")
if [[ -n "${STELIS_DOWNLOAD_MIRROR:-}" ]]; then
    urls=("${STELIS_DOWNLOAD_MIRROR%/}/$sha" "${urls[@]}")
fi

# --- 2. fetch, the checksum deciding ------------------------------------------
installer="$(mktemp -t racket-installer.XXXXXX)"
trap 'rm -f "$installer"' EXIT
got=
for url in "${urls[@]}"; do
    if curl -fsSL --connect-timeout 20 --speed-limit 10000 --speed-time 60 -o "$installer" "$url" \
        && echo "$sha  $installer" | sha256sum -c - > /dev/null 2>&1; then
        got=$url
        break
    fi
    echo "install-racket.sh: $url failed or did not match $sha; trying the next" >&2
done
if [[ -z "$got" ]]; then
    echo "install-racket.sh: no source gave a Racket $version installer matching $sha" >&2
    exit 1
fi
echo "install-racket.sh: Racket $version ($name) from $got"

# --- 3. install ----------------------------------------------------------------
# Unix-style: bin/, share/racket/, etc. under the prefix, the layout a container's
# /usr/local expects and a PATH entry serves.
sh "$installer" --unix-style --dest "$prefix" --create-dir > /dev/null
rm -f "$installer"
if [[ "$("$racket" --version)" != *"v$version "* ]]; then
    echo "install-racket.sh: $racket reports '$("$racket" --version)', not v$version" >&2
    exit 1
fi

# --- 4. the packages, from their pinned sources --------------------------------
# datalog by name comes from the release catalog, which names one zip and its
# checksum for this version; sha from the git commit racket-deps.txt pins (st-8u3).
# --no-docs: datalog's dependencies carry documentation whose build needs SQLite,
# and the engine never reads it.
sources=()
while read -r line; do
    [[ "$line" =~ ^[[:space:]]*# ]] && continue
    line="${line%%[[:space:]]#*}"
    read -r dep source <<< "$line"
    [[ -z "$dep" ]] && continue
    sources+=("${source:-$dep}")
done < "$STELIS_DIR/racket-deps.txt"
"$raco" pkg install --auto --batch --no-docs --scope installation "${sources[@]}"

# --- 5. prove it ---------------------------------------------------------------
PATH="$prefix/bin:$PATH" bash "$SCRIPT_DIR/preflight.sh"
