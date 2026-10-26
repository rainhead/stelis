#!/usr/bin/env bash
# Link the engine's src/ as the Racket collection `stelis` (st-ab3, ADR 0020), so a
# project's graph module outside this repository can `(require stelis/model)` and the
# rest. Idempotent: a second run finds the collection loading and does nothing.
#
#   scripts/link-collection.sh                 # installation scope: the image, CI, a
#                                              # prefix install such as ~/racket
#   scripts/link-collection.sh --scope user    # a distro Racket, where installation
#                                              # scope is root's
#
# --no-setup: the link's compiled code is what `raco make` makes under src/compiled,
# the same files the engine runs from; a setup pass would compile the whole
# collection again, tests included, for nothing.
set -euo pipefail
scope=installation
while [[ $# -gt 0 ]]; do
    case "$1" in
        --scope) scope=${2:?--scope needs installation or user}; shift 2 ;;
        *) echo "usage: link-collection.sh [--scope installation|user]" >&2; exit 2 ;;
    esac
done
src="$(cd "$(dirname "${BASH_SOURCE[0]}")/../src" && pwd)"
# A successful require says a collection named stelis loads, not that it is THIS
# checkout's: a link left by an older checkout would answer too, and an external
# project would then build against the older engine. So compare directories.
if racket -l racket/base -e '(require stelis/project)' > /dev/null 2>&1; then
    linked="$(racket -l racket/base -l racket/path -e '(display (path-only (collection-file-path "project.rkt" "stelis")))')"
    if [[ "$(cd "$linked" && pwd -P)" == "$(cd "$src" && pwd -P)" ]]; then
        echo "link-collection: stelis already loads from $linked"
        exit 0
    fi
    echo "link-collection: a collection named stelis already loads from $linked, not from $src." >&2
    echo "  Remove that link first (raco pkg remove --scope <its scope> stelis), then run this again." >&2
    exit 1
fi
# the options before the source: `--link` takes none, and `--name` must precede it
raco pkg install --scope "$scope" --no-setup --deps force --batch --no-docs --link --name stelis "$src"
racket -l racket/base -e '(require stelis/project)'
echo "link-collection: stelis -> $src ($scope scope)"
