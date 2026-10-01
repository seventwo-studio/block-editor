# WASM section and name metadata analysis

The inspector measures the release artifact from source
`e787146c432e649e71a1a6423fe4a24c55e21f5c`, already verified in the
[three-browser baseline](../2026-10-01-wasm-three-browsers/README.md). The original
SHA-256 is `d659fd2f1212d8242e3c18397f69a540cf76d23c63cd2e073eba15a669518457`.
The [machine-readable result](sections.json) records every section's offset,
payload and framed size, exact hashes and computed gzip level-9 sizes.

| Artifact | Raw bytes | Computed gzip level-9 bytes |
| --- | ---: | ---: |
| Original release, stripped debug | 61,435,676 | 20,370,961 |
| Separate candidate with only custom `name` sections removed | 54,630,266 | 19,307,383 |
| Saving | 6,805,410 | 1,063,578 |

The candidate removes one 6,805,405-byte payload plus its 5-byte section header.
It preserves `.swift1_autolink_entries`, `producers`, `target_features` and every
standard section byte. The concatenated module header and standard sections have
the same SHA-256 before and after:
`dd93e3d3de49955b58c5978d1d7de1078c310386c90d70668fae3c00dfcff250`.
Candidate SHA-256 is
`f7162960ab5f34f57ee23c3279c27408d54e39f3a966486d43740d2f0bf919f7`.

The code payload is 16,619,360 bytes and the data payload is 37,657,082 bytes.
Those are binary section measurements, not attribution to specific dependencies.
Gzip savings cannot be obtained by adding independently compressed section sizes.
Name removal saves 5.22% of whole-artifact gzip size and still exceeds the
**unagreed** 10,000,000-byte proposal by 9,307,383 bytes.

The [WebAssembly specification](https://webassembly.github.io/spec/core/binary/modules.html#custom-section)
defines custom sections as metadata outside execution semantics. Name removal
also removes profiler/debugging labels. Keep the original named artifact for
diagnosis. No compiler flag, core code or canonical artifact changed.

## Reproduce

From the checkout containing the exact original artifact:

```sh
bun scripts/wasm-size.mjs dist/block-editor.wasm

# Explicit opt-in: writes a new file and refuses existing paths.
bun scripts/wasm-size.mjs dist/block-editor.wasm \
  --strip-names=/tmp/new-owned-name-stripped-candidate.wasm

bun test tests/wasm-size.test.ts
```

The output path recorded in `sections.json` is local evidence of a separate
candidate; it is not a packaged asset. Exclusive creation refuses overwrite,
including existing symlinks and hardlinks. The inspector validates bounded
section framing and UTF-8 custom names, not instructions or full module validity.
Tests also compile/instantiate a small fixture and cover malformed lengths,
name preservation, executable-byte equality and refusal to overwrite archives.

## Actual candidate verification

All six sequential tests passed in Chromium 153.0.8010.12, WebKit 26.6 and
Firefox 155.0: complete compatibility and preserved-content smoke in each.
Each compatibility run produces **2,297 responses** against the checkout's exact
fixture hashes. The three independently captured raw transcripts are
byte-identical, so [one compressed transcript](compatibility/transcript.json.gz)
is retained with each browser's original output path and hashes in
[validation provenance](validation-provenance.json). All three original raw
outputs remain at their recorded local paths. Gzip preserves the full transcript;
it is not a selection of responses.

The smoke profile contributes six complete samples, with eight edits per author,
one repetition and no warmup. It checks both collaboration versions, convergence,
receipts, reopen and local undo. [Strict verifier output](verification.txt),
[test log](candidate-playwright.log), [smoke reports](smoke/) and
[Firefox launch/cleanup provenance](launch-provenance.json) accompany the result.
The Vite cache and Firefox application-data roots were isolated. The first
candidate was safely deleted during disk exhaustion and regenerated to the same
hash before testing; the canonical named artifact was preserved throughout.

The checkout has staged documentation/tooling additions, so the smoke reports
honestly record `sourceDirty: true`. Production inputs, fixtures, bridge and
measurement harness are unchanged from e787146; provenance records that check.
These tests establish this historical artifact's candidate compatibility. They
do not establish later engine performance, numeric-budget agreement, a linker
`--strip-all` result or adoption of a default packaging change.
