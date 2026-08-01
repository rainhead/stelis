# vendor/dasl-testing

Conformance fixtures for [DASL](https://dasl.ing/), vendored from
[hyphacoop/dasl-testing](https://github.com/hyphacoop/dasl-testing) at commit
`7c93e309b90e0c7d92415a8c1ff4475c5a984b22`. MIT licensed; `LICENSE` is the
upstream copy, unmodified. Only `fixtures/cbor/` is vendored — the upstream
harnesses (Go, JS, Python, Rust, Java) and its report site are not.

Vendored rather than fetched because [`src/drisl-test.rkt`](../../src/drisl-test.rkt)
runs these as a normal `raco test` unit, and CI has no network.

## What a fixture says

Each file is a JSON array of `{type, data, name, tags, desc}`, where `data` is
hex-encoded CBOR and `type` is one of:

- `roundtrip` — decoding then re-encoding must reproduce `data` **byte for byte**
- `invalid_in` — decoding must be refused
- `invalid_out` — the *value* `data` denotes must be refused by the encoder

`tags` names the specs a case belongs to, and **cases in different tags
contradict each other on purpose** — half-precision `f93e00` is a valid
`rfc8949` roundtrip and an invalid `dag-cbor` input, because those are different
specs, not different opinions. Upstream runs everything and reports a matrix.
`drisl-test.rkt` instead runs only the tags this repo claims, and says so in its
header.

To refresh: re-copy `fixtures/cbor/` and `LICENSE`, update the commit above, and
re-run `raco test src/drisl-test.rkt` — new upstream cases show up as failures or
as a changed skip count, which is the point of pinning a commit.
