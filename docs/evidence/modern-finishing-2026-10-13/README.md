# First modern finishing candidate

Targeted execution for [ST-104](https://linear.app/seventwo/issue/ST-104) and
[ST-141](https://linear.app/seventwo/issue/ST-141). The runtime source remains
delivered commit `1bb9a89c3f73c043588f8acabcde62c4e1b16be3`; the acceptance
harness is `5a5f813cb1c3a76ae55bb8e30a9aeb61f5dcb12b`. No runtime, example,
document expectation or published 0.2.0 artifact changed.

[receipt.json](receipt.json) records source, hardware, compiler and binary
identities. [files.json](files.json) hashes the original receipts, failure logs
and rendered captures. The local test uses the delivered actual WASM hash
`6f5febcfb962f735abde4bb8980aa175e568c64fd63c00404b83d512c73014fb`.

| Executed boundary | Result |
| --- | --- |
| Chromium, WebKit and Firefox integrated browser candidate | 24 passed, no skipped/flaky/unexpected cases; normal exit 0 |
| Typed shared consumer contract in each browser | 55 independent documents, 26 applied commands and 11 semantic checks per engine |
| Real IndexedDB preservation in each browser | Four cases covering the shared portions of ACC-24–27 |
| Rebuilt native Swift C ABI | 963 responses against 30 independent fixtures |
| Same typed consumer through native C ABI | 504 requests, 55 independent documents, 26 applied commands, 11 semantic checks |
| Modern-test and relay TypeScript checks; diff whitespace | Passed |

The three integrated interaction cases exercise title-to-body focus, Unicode,
code whitespace/Tab, language metadata, tables, columns and narrow presentation,
paired save/reopen, slash cancellation, local asset/caption reopen, captured
formatting and author Undo. The captures retain the narrow rendered candidate in
each browser. They do not establish comprehensive visual or assistive acceptance.

The new preservation runner compares whole independent documents and exact
original bytes. It checks column split/nesting/scoped identities, explicit caret
restoration, separately retained input and duplicate receipts. Migration stages
are written to real IndexedDB: a deliberately failed readback leaves the old
active pointer intact; retry uses the same staged candidate. Rollback preserves
the newer epoch's saved edits and history. Reserved-tag collisions and unsupported
inline content remain unavailable with exportable originals. All 5,001 blocks
survive migration and durable reopen. Original expected JSON remains unchanged.

## Retained failures and launch repair

`browser-baseline.json` contains six passing Chromium/WebKit cases and three
Firefox launch failures before any editor assertion. A fresh explicit profile
also failed (`firefox-profile-probe.json`). These failures remain failed evidence.

Pinned Firefox 155 consults the installed application's data directory even with
a fresh profile. On macOS 27 that lookup can fail under privacy protection; see
the [upstream report and maintainer discussion](https://github.com/microsoft/playwright/issues/42768).
The harness supplies only headless Firefox with a temporary application-data
home through `CFFIXED_USER_HOME`. It preserves the shipped binary, the real
Firefox profile and macOS security settings. Other browser/platform launches
retain their existing behavior. The same isolation applies to explicit browser
process-restart launches as well as ordinary Playwright fixtures.

`firefox-repaired.json` records three passed interaction cases, but its runner
stalled during teardown and was interrupted (exit 130). It is not a successful
complete run. An exit-event cleanup hook was removed from the harness before
the normal completed runs; the stack sample showed an idle worker and does not
independently establish the cause of the stall. Temporary homes use the system
temporary directory rather than the user profile.

`preservation-run.log` / `preservation-browser.log` retain the initial new-harness
failure: extra fields in a local-selection request produced `invalidChange` in
Chromium and Firefox. The request was corrected to the documented scope and
range shape; expected documents were not regenerated. A stalled worker was
interrupted after browser shutdown. `preservation-fixed.json` records all twelve
preservation cases passing with a normal exit. `browser-candidate.json` then
records the coherent eight-case run in all three engines with a normal exit.

## Reproduction and remaining acceptance

With dependencies and the matching actual WASM already installed:

```sh
bun node_modules/typescript/bin/tsc -p tsconfig.modern-tests.json --noEmit
bun node_modules/typescript/bin/tsc -p tsconfig.relay.json --noEmit
bunx playwright test --config playwright.swift.config.ts \
  tests/modern-editor.swift.ts tests/modern-preservation.swift.ts \
  tests/modern-adapter.swift.ts --workers=1 --global-timeout=240000
xcrun swift build --product BlockEditorBridge
python3 scripts/test-modern-abi.py --library .build/debug/libBlockEditorBridge.dylib \
  --output test-results/finishing/native-modern-abi.json
bun scripts/test-modern-adapter.ts .build/debug/libBlockEditorBridge.dylib \
  test-results/finishing/native-modern-adapter.json
```

These results do not close ST-104 or ST-141. All 44 scenarios, complete native
rendered/assistive input, production-independent relay restart/recovery, full
clipboard/composition/touch coverage, comprehensive accessibility, the 1,000-block
rendered performance thresholds and all-runtime clean private installation
remain separate acceptance rows. The fixture matrix retains its pending status
until each scenario's required evidence is complete. The native reports preserve
their original qualifications.

Luca deferred physical-device and final-review availability for now. ST-170,
ST-177 and the affected acceptance issues remain open; no deferral counts as a
pass or a scope waiver. The finishing project and goal remain active.
