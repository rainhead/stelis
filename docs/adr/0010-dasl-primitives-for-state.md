# ADR 0010 — DASL primitives are the canonical encoding for state (st-b7v)

**Status:** accepted · **Horizon:** 2 (state layer) · **Date:** 2026-08-01

Stelis writes its own state — the observation history, the topology snapshots, the
cache sidecars — and until now it answered *"what are these bytes' identity?"* three
different ways. This ADR adopts one spec'd answer: **DASL CIDs** for addresses and
**DRISL** for the bytes those addresses name.

## Context

Three canonicalization schemes, each canonical only by habit:

| what | how it was addressed | where |
|---|---|---|
| a `'file` artifact | raw bytes → sha1 hex | `cache.rkt` |
| a keyed set (`'dir` tree, relation columns, notes store) | `"path=hash"` lines joined by `\n` → sha1 | `tree-digest.rkt` |
| the topology snapshot | `(format "~s" datum)` → sha1 | `model.rkt` |

DESIGN names **determinism as a day-one property**. The third row quietly made that
property depend on Racket's printer — on `write`'s output being stable across
Racket versions, and on hash iteration order not moving. Nothing was broken, but
the guarantee rested on an implementation detail rather than on anything written
down.

The second row has a subtler cost. An artifact's roll-up digest and its per-key
parts are computed separately and *asserted* to agree — `cache.rkt` has to say in
prose that "the two granularities can never disagree." An invariant maintained by
comment is one refactor from being false.

**Why DASL rather than a house format.** It is small enough to implement in an
afternoon (a CID is four framing bytes and a sha-256; DRISL is a CBOR subset), it
is the format atproto normatively uses — its data model spec calls DRISL "the
successor to DAG-CBOR" — and it comes with a conformance suite. Adopting a spec we
did not write means the encoding's authority lives outside this repo, which is the
entire point: a canonical form no one can quietly redefine.

## Decision

**D1. A CID is the DASL profile of CIDv1, and nothing wider.** Version 1, codec raw
`0x55` or DRISL `0x71`, sha-256, 32 bytes, `b`-prefixed lowercase base32. CIDv0, any
other codec, any other hash, and the long-form tag are refused. The codec travels
*in* the address, so a DRISL block and a raw blob with identical bytes are
different CIDs — which a bare hash string cannot express.

**D2. Parsers reject; they never soften.** The conformance suite types every
malformed input as `invalid_in`: the failing side is the **decoder**. This is not
defensiveness. Each accepted deviation — a non-minimal integer head, an unsorted
map, a 16-bit float — would be a *second spelling* of a value that already has one,
and two spellings of one value is precisely what a content-addressed store cannot
survive.

**D3. Map keys sort length-first.** Two conventions exist (RFC 7049 canonical, which
DAG-CBOR took, vs. RFC 8949 §4.2.1 bytewise-on-encoded-key). For DRISL they are the
same rule: a CBOR text string's head byte is monotonic in length, so bytewise-on-
encoded sorts by length first anyway, and DRISL admits no non-string keys — the only
case where the two diverge. The suite's "map keys in correct order" case is tagged
**both** `rfc8949` and `dag-cbor`, which is upstream asserting exactly this.

**D4. Conformance is a runner over vendored fixtures, not transcribed cases.**
`vendor/dasl-testing` is pinned to an upstream commit and executed by
`drisl-test.rkt`. The suite's tags **contradict each other by design** — half-
precision `f93e00` is a valid `rfc8949` roundtrip and an invalid `dag-cbor` input —
so no single implementation passes all of it. We run the tags DRISL and the DASL
CID consist of (`dag-cbor`, `basic`, `dasl-cid`) and **assert the skip count**, so a
fixture refresh that adds cases in a tag we claim fails the build instead of
vanishing.

**D5. Adoption is incremental, and the graph snapshot goes first.** It is already
content-addressed, already write-once, and has exactly one reader — so a wrong byte
costs one snapshot. sha1 remains the live content hash for artifacts and cache
decisions until the keyed-observation layer moves (st-1e5).

**D6. A keyed artifact's digest is the CID of the block holding its WHOLE keyed map
— but only where the parts constitute the identity** (st-1e5). True for a `'dir` tree and for the keyed
notes store. **Not** true for a `db-relation`, whose identity is
`relation-digest.rkt`'s row-coherent digest: per-column multiset digests alone
false-skip on a cross-row value swap, which st-d5d proved. Its per-column parts ride
*alongside* its identity rather than constituting it. The asymmetry is load-bearing,
and D1's "the codec travels in the address" is the same instinct — what a digest is
*of* is part of what it means.

Two defects fall out rather than being chased. `digest-of-pairs` joined
`"<key>=<value>"` with newlines, so `{"a=b" → "c"}` and `{"a" → "b=c"}` produced one
digest for two maps — and paths containing `=` are legal on every filesystem we run
on. And its order-independence lived in the *callers* all sorting their pairs, not
in the function; DRISL orders map keys as part of encoding, so the property now
belongs to the format.

## Consequences

**The snapshot's filename becomes a claim you can check.** It is addressed by the CID
of its own bytes, so corruption is *detectable* rather than merely unparseable —
re-hash and compare. (It first landed at `graphs/<cid>.drisl`; st-1e5 moved it into
the shared `blocks/` store below, so there is one block layout rather than two.) The old envelope (a `'version` and
`'graph-hash` sitting beside the payload) is gone: the version rides inside the
block, and the hash is the name.

**GRAPH-SNAPSHOT-VERSION 2 → 3, and v2 snapshots become unreadable.** In policy:
`.stelis/` is derived, disposable, format-versioned state, and `history-graph`
already answers `#f` for anything it cannot read. The build log itself is untouched.

**Symbols are the impedance.** DRISL has text strings and no symbols, so every name
crosses as a string and back through `string->symbol`. Field names are spelled out
rather than positional, so a block is legible to a reader that has never seen
`graph->datum`. Callers holding symbol-keyed data convert at the same boundary. Note
the history LOG LINE has not crossed and is still a symbol-keyed Racket datum — only
the blocks it names are DRISL.

**A new dependency, `sha`.** Not in the full Racket distribution (unlike `datalog`),
so CI installs it explicitly. base32 is clean-room from RFC 4648: Racket's `base32`
package implements **Crockford**, a different alphabet, and carries no license.

**What this does NOT change.** Freshness. ADR 0005 holds: freshness is answered from
content hashes and the dependency graph, never from the history's sequence. When the
history becomes a hash-linked chain, the `parent` link must stay browsing-only — a
parent link *is* sequence, and letting freshness consult it would reintroduce the
clock this design refuses.

**Blocks are one store, and dedup is real but shallow** (st-1e5). `.stelis/blocks/`
holds both the graph snapshot and each record's keyed maps; `block-ref` re-addresses
what it reads and refuses a mismatch. The observation history stops rewriting an
unchanged `notes/` map on every build — which matters because it is the one part of
state designed to grow forever. But this is **dedup of identical maps, not per-key
sharing**: one changed species still writes a whole new block. Real per-key sharing
needs a trie, and this store is one node deep. Do not describe it as a Merkle tree.

**Binary state needs a way out, so `--block <cid>` exists.** Inspectability was the
price of the format change; a command that prints any stored block as a readable
datum is what buys it back. It renders maps as key-sorted alists, because a hash
prints in no useful order and the entire point of the format is that one value has
one spelling.

**What st-1e5 delivered, and what is still open.** The per-key map is now a block
whose CID *is* the artifact's roll-up digest for a `'dir` and the notes store, so
`digest-of-pairs` is gone and the asserted invariant is structural. The observation
history stores those maps as blocks, so it stops rewriting the whole `notes/` map
every build. Still open: a build CID as the name for a whole build state (ROADMAP
H3), and per-KEY rather than per-map sharing, which needs a trie.

## Alternatives considered

**Keep sha1 over `~s` and write down the format.** Cheapest, and it would have made
the existing behaviour explicit rather than incidental. Rejected because it buys
only documentation: no structural sharing, no verifiable filenames, no external
authority, and the roll-up/parts invariant stays a comment.

**DAG-CBOR by that name, via an existing library.** There is no Racket one, so the
implementation cost is identical; DRISL is the same codec with a tighter profile
and a live conformance suite.

**Defer until st-1e5 needs it.** Rejected: the encoder is the risky part and the
keyed layer is the valuable part. Landing them together would have meant debugging
a new encoding inside a change to the cache's core invariant.
