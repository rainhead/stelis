#!/usr/bin/env bash
# The digest of the Stelis image built from a commit (ADR 0017, st-9ov):
#
#   scripts/image-digest.sh <commit>
#   → ghcr.io/rainhead/stelis@sha256:...
#
# A project that builds with Stelis pins the image by DIGEST in its Dockerfile, not
# by the commit tag: a tag can be moved, a digest names one set of bytes. This is
# where the digest comes from. It asks ghcr.io for the manifest the commit's tag
# names, then reads the image's own org.opencontainers.image.revision label and
# refuses unless that label is the commit asked for, so a consumer's pin is the
# pair (commit, digest) checked against each other, never a tag taken on trust.
# The consumer's build checks the other direction: /opt/stelis/commit in the image
# against the commit it pinned.
#
# The image is public, so no login is needed. Exit 1 when the registry has no image
# for the commit (the image workflow publishes one per push to main, a few minutes
# after the push) or the label disagrees; 2 for usage.

set -euo pipefail

IMAGE=${STELIS_IMAGE:-ghcr.io/rainhead/stelis}

commit=${1:-}
if ! [[ "$commit" =~ ^[0-9a-f]{40}$ ]]; then
    echo "usage: image-digest.sh <full 40-character commit>" >&2
    exit 2
fi

registry=${IMAGE%%/*}
repository=${IMAGE#*/}
# A pull token for a public package needs no login. The registry answers 403 here
# when no package by that name exists yet, before the first push to main.
if ! token=$(curl -fsL "https://$registry/token?scope=repository:$repository:pull" 2> /dev/null \
        | python3 -I -c 'import json, sys; print(json.load(sys.stdin)["token"])' 2> /dev/null) \
    || [[ -z "$token" ]]; then
    echo "image-digest.sh: $registry issued no pull token for $repository; does the package exist yet?" >&2
    echo "  The image workflow creates it on the first push to main." >&2
    exit 1
fi
auth=(-H "Authorization: Bearer $token")
accept=(-H 'Accept: application/vnd.oci.image.index.v1+json, application/vnd.oci.image.manifest.v1+json, application/vnd.docker.distribution.manifest.list.v2+json, application/vnd.docker.distribution.manifest.v2+json')
manifests="https://$registry/v2/$repository/manifests"
blobs="https://$registry/v2/$repository/blobs"

# The tag's digest, from the manifest response's header: what `docker pull` by
# digest would resolve, an index when the build attached attestations. A tag the
# registry has not got is a 404 with no such header, reported below.
digest=$(curl -sIL "${auth[@]}" "${accept[@]}" "$manifests/$commit" \
    | tr -d '\r' | awk 'tolower($1) == "docker-content-digest:" { print $2 }' | tail -1)
if [[ -z "$digest" ]]; then
    echo "image-digest.sh: $IMAGE has no image tagged $commit" >&2
    echo "  The image workflow publishes one per push to main; is this commit on main, and has it run?" >&2
    exit 1
fi

# The revision label lives in the image config. Walk index → manifest → config.
label=$(curl -fsSL "${auth[@]}" "${accept[@]}" "$manifests/$digest" \
    | python3 -I -c '
import json, subprocess, sys
auth, accept, manifests, blobs = sys.argv[1:5]
def fetch(url):
    return json.loads(subprocess.run(
        ["curl", "-fsSL", "-H", auth, "-H", accept, url], check=True, capture_output=True).stdout)
doc = json.load(sys.stdin)
if "manifests" in doc:   # an index: the linux/amd64 image, not an attestation
    entry = next(m for m in doc["manifests"]
                 if m.get("platform", {}).get("os") == "linux"
                 and m.get("platform", {}).get("architecture") == "amd64")
    doc = fetch(manifests + "/" + entry["digest"])
config = fetch(blobs + "/" + doc["config"]["digest"])
print(config.get("config", {}).get("Labels", {}).get("org.opencontainers.image.revision", ""))
' "${auth[1]}" "${accept[1]}" "$manifests" "$blobs")
if [[ "$label" != "$commit" ]]; then
    echo "image-digest.sh: $IMAGE:$commit is labelled revision '$label', not $commit; not trusting the tag" >&2
    exit 1
fi

echo "$IMAGE@$digest"
