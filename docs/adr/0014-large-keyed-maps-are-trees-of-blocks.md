# ADR 0014 — A large keyed map is a tree of blocks, sharded by key hash

**Status:** accepted · **Horizon:** 2 · **Date:** 2026-10-02 (landed in 3a84ea4 and 052a1d5; recorded 2026-10-04, st-ml9.11)

Extends [ADR 0010](0010-dasl-primitives-for-state.md) (DASL CIDs over DRISL
blocks) and st-1e5 (a keyed artifact's per-key map IS one DRISL block, whose CID
is the artifact's digest). **A map of more than 256 entries is stored as a tree
of blocks rather than one block, and the artifact's digest is the root's CID.**
A map of 256 or fewer is exactly the flat block it always was, same CID.

## Context

st-1e5 made the roll-up and the parts one object: a keyed artifact's per-key
map is a DRISL map block, and its CID is the digest the cache compares. That
holds by construction and it is the right shape — but the whole block is
rewritten whenever any one key changes. salishsea's `days/` map has 4,398 keys,
about 250 KB as a block, and roughly every other build changes one day: on the
Fly machine's history that was 45 MB over 178 changes, the bulk of what a
five-minute build cadence (decision 061's cutover, salish-xv35.5) would add to a
1 GB volume. Retention (st-ml9.7, 30 days for salishsea) bounds the window, not
the rate.

## Decision

- **Sharding is by the key's hash, not the key.** A node maps the next byte of
  each key's sha256, as two hex digits, to the CID of the block holding that
  bucket; a bucket still above the leaf maximum is split again by the following
  byte. Buckets by hash spread every keyspace the same way — a path with a year
  in it, a species name, a numeric id — so the split does not depend on what the
  keys look like, and no key layout can degenerate it.
- **A node is told from a leaf by shape.** A node is the two-element array
  `["stelis/keyed-node/1", {bucket → CID}]`; a leaf is always a map. The two are
  distinguished by the array-vs-map shape alone, never by what a leaf's values
  are (strings today; if they became CIDs, a test by value type would break).
- **The digest is the root's CID**, so st-1e5's property is unchanged: the
  address is the stored object. One changed key rewrites one bucket and the root
  (~1 KB and ~10 KB for `days/`), not the map: over the same 178 changes, 2.4 MB.
- **The flat case is untouched.** 256 or fewer entries is the same flat block,
  same CID, so no artifact under that size moved; larger maps' digests changed
  once when this landed, and their consumers reran once.
- **History stores every block of the tree and reads a map back whole.** A
  missing bucket makes the map unreadable, never smaller — a lost block is
  corruption, not an empty day. Retention's block collection walks each surviving
  root to its buckets, so a bucket shared between two roots survives while either
  does.
- **The layout is our own.** Hash-prefix sharding like IPFS's HAMT directories,
  in DRISL with CID links like atproto's MST, but neither ecosystem's
  specification: nothing outside Stelis reads one of these trees as a map, and
  the tag names the format so a future reader can tell which it holds.

## Rejected alternatives

- **Keep the flat block, rely on retention.** Retention bounds the window, not the
  rate; at 288 builds a day the history still grows by the whole map every other
  build.
- **Shard by key prefix** (the first path element, the year). Cheap to read, but
  the bucket sizes then depend on the keyspace: `days/` would put a whole year in
  one bucket, and a species-keyed map would have one bucket per initial letter.
  Hash sharding is uniform by construction.
- **Adopt IPFS's UnixFS HAMT or atproto's MST wholesale.** Both carry what their
  ecosystems need (UnixFS's protobuf framing and link names; the MST's ordering
  and depth-by-leading-zeros invariant for a different access pattern) and
  neither is a DRISL map. The payoff for conforming would be interoperability
  with tools that do not read Stelis's blocks anyway.
- **Delta-encode a map against the previous build's.** That is the delta
  substrate (Horizon 2, delta.rkt), which answers "what moved" from the recorded
  per-key maps; storage of the maps themselves should not depend on it.

## Consequences

- `keyed-block.rkt` exposes `keyed-tree-blocks` (every block of a map, root first),
  `keyed-node?` and `keyed-node-links`; `history.rkt` stores the whole list, walks
  roots for retention, and reads a map back through its links.
- The chunk size (`LEAF-MAX`, 256) is a constant of the format: changing it
  changes every large map's CID. A change is a new tag, not a new constant.
- Reading a hash still tells you what kind of thing it is: a `'dir` artifact's
  digest is the CID of a block or of a root, and the reader does not need to know
  which until it opens it.
