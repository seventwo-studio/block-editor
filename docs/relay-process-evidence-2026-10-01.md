# Hosted relay process evidence — 1 October 2026

[ST-105](https://linear.app/seventwo/issue/ST-105/complete-the-local-relay-demonstration-across-every-platform) remains In Progress. The harness and reference-host implementation are delivered in [draft PR #41](https://github.com/seventwo-studio/block-editor/pull/41). This record preserves the successful hosted relay increment and its source qualification; it does not establish all-platform acceptance.

## Recorded execution

[CI run 36871695166](https://github.com/seventwo-studio/block-editor/actions/runs/36871695166) at PR head `734a80bf0aa74471f7a880dd572a4fd0a9afea20` passed its WASM job on Linux x86_64:

| Suite | Passed | Skipped / failed / flaky | Duration |
| --- | ---: | --- | ---: |
| Reference-host relay | 42 | 0 / 0 / 0 | 120.646 s |
| Full browser and relay process restart | 9 | 0 / 0 / 0 | 119.008 s |

Every relay case has one successful result at retry zero. The restart suite runs three scenarios in each of Chromium 153.0.8010.12, WebKit 26.6 and Firefox 155.0:

- v1 offline author history, local undo preserving remote changes, and presence expiry that leaves saved content unchanged; three browser launches/exits and two relay launches/exits per engine.
- v2 rejected merge, separate accepted/pending archives, offline reopen/export/import, visible permitted repair and resubmission; four browser launches/exits and two relay launches/exits per engine, including actual HTTP 409.
- Transport capacity preserves unacknowledged history through export, offline restart and explicit retry; two browser launches/exits and two relay launches/exits per engine, including three actual HTTP 413 responses.

The separate engine-browser suite passed 116 cases with seven explicit skips, zero failures and zero flaky results. Its skipped coverage is not included in the relay totals.

## Source and binary qualification

The actual clean CI checkout is `c65a9520b3a1d307999a397b3a12b6d10fbba511`, a PR checkout merge commit, with tree `3c5169e43ee487aaaf345620c056882f7b35360a`. It is distinct from the PR head. All nine process attachments retain that checkout, per-source hashes, runtime manifest and actual process phases. Independent review matched every attached source hash and manifest input against this tree.

| Fresh hosted binary | Bytes | SHA-256 |
| --- | ---: | --- |
| WASM | 61,448,985 | `7e2fa10567e6117b25ecf0289d680f1da084e09166b173d4d6c328dd44ccbc1e` |
| Linux debug editor bridge | 2,910,440 | `a573a0655b11b1f5cb8f08b0c271a1107a153a680987ab6179aff91bb01cba38` |
| Linux relay client | 3,363,032 | `6ddf39d0926adfa55a71638ea2083e55fa21b891e0f238b6d9fabb11b3364b5f` |

The archived raw WASM binary was independently rehashed and matched the manifest. All nine process attachments match the recorded bridge/WASM hashes. Earlier macOS execution used a retained equivalent-input WASM build and remains separately qualified; it is not relabeled as this fresh Linux build.

The commands are `bun run test:relay:browser` and `bun run test:relay:restart`, using native relay executables and WASM built from the same checkout. Reports, manifests and process attachments are retained by the workflow; reruns require fresh exact-source provenance rather than reusing these outcomes.

## Remaining gates

This run failed overall: API 26 native paste and dependent runtime parity failed. Passing relay and WASM jobs do not make the entire PR eligible to merge. Subsequent diagnostic/fix commits require their own current-head checks; these results remain tied to the source above.

Actual relay interaction across all Apple families and minimum runtimes, native transport-limit recovery, expanded Android, accessibility/hardware and private consumer/release acceptance remain open. ST-96 remains ST-105's prerequisite. No production service, account system, chunking, compaction or package publication is introduced.
