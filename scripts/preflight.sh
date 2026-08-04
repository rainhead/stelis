#!/usr/bin/env bash
# Can this host RUN the engine? (st-7lm)
#
# A stelis push reaches the deploy host through the nightly's `git pull`, and
# nothing on that path checks the host can load what it just pulled. Tests passing
# locally and in CI say nothing about a missing collection on the target: on
# 2026-08-01 `sha` was absent on maderas, every `racket src/main.rkt` failed to
# load, and the nightly's whole fetch-data leg was dead — surfacing as a module
# resolution stack trace with nothing in it naming the fix.
#
# So this answers the narrow question early and namefully, BEFORE an hour of data
# build. Run it from anywhere; it locates the checkout from its own path.
#
# Exit codes follow the nightly's idiom: 78 (EX_CONFIG) for "this host is not set
# up", which is a provisioning problem and not a build failure.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STELIS_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

DEPS_FILE="$STELIS_DIR/racket-deps.txt"
VERSION_FILE="$STELIS_DIR/racket-version"

# --- 1. racket at all ---------------------------------------------------------
if ! command -v racket > /dev/null; then
    echo "FATAL: racket is not on PATH — the engine cannot run on this host." >&2
    echo "  Install Racket (see $VERSION_FILE for the version this repo targets)." >&2
    exit 78
fi

# --- 2. every declared collection actually loads ------------------------------
# One require per collection rather than one combined require: the point is to
# NAME the missing one, and a combined form stops at the first failure with a
# message about a module path rather than about provisioning.
missing=()
checked=0
while read -r dep; do
    dep="${dep%%#*}"                       # strip comments
    dep="$(echo "$dep" | tr -d '[:space:]')"
    [[ -z "$dep" ]] && continue
    checked=$(( checked + 1 ))
    if ! racket -l racket/base -e "(require $dep)" > /dev/null 2>&1; then
        missing+=("$dep")
    fi
done < "$DEPS_FILE"

if (( ${#missing[@]} > 0 )); then
    echo "FATAL: stelis needs Racket collections this host cannot load:" >&2
    for m in "${missing[@]}"; do echo "  - $m" >&2; done
    echo "" >&2
    echo "Install them (user scope — an installation-wide install needs root and" >&2
    echo "fights the system package manager when racket came from a distro package):" >&2
    echo "  raco pkg install --auto --batch ${missing[*]}" >&2
    echo "" >&2
    echo "NOTE: a collection that ships in the full distribution is already present" >&2
    echo "at installation scope and must NOT be re-requested as a user package." >&2
    exit 78
fi

# --- 3. the Racket version, REPORTED and not gated ----------------------------
# Deliberately not fatal, and the reason is evidence rather than leniency: what
# actually protects the host is the test suite the nightly runs right after this,
# on THIS interpreter. If a stelis change needs something this Racket lacks, that
# suite fails and blocks the publish — naming the broken behavior, which a version
# string cannot. Measured 2026-08-04: the full suite passes on maderas's 9.1 while
# the repo targets 9.2, so gating here would have blocked a working pipeline over
# a delta with no symptom, and the standing bypass that followed would have been
# the real cost (ADR 0006's flag-vs-gate line: this is an operator alarm, and the
# gate is downstream).
want="$(tr -d '[:space:]' < "$VERSION_FILE")"
got="$(racket --version | sed -n 's/.*v\([0-9][0-9.]*\).*/\1/p')"

echo "preflight: racket $got, $checked collection(s) load"

if [[ "$got" != "$want" ]]; then
    echo "NOTE: this host runs Racket $got; the repo targets $want ($VERSION_FILE)." >&2
    echo "  CI tests on $want, so $got is a runtime nothing else exercises." >&2
    echo "  Not fatal — the stelis test suite runs next on THIS interpreter and is" >&2
    echo "  what actually gates the publish." >&2
fi

exit 0
