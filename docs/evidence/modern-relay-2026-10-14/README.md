# Modern relay lifecycle and recovery

Finishing evidence for [ST-104](https://linear.app/seventwo/issue/ST-104) and the
shared expectations reused by [ST-141](https://linear.app/seventwo/issue/ST-141).
Implementation is `a939dfc6600d08436a06ce0fb917fa4a157984a2`; package inventory
verification adds `8a8b720020d7b5ded0d5bc651ee624879df554df`. The
[contract](../../modern-relay-reference.md) explains service/application ownership,
durability, scope, capacity and recovery. [receipt.json](receipt.json) and
[files.json](files.json) retain exact source/artifact identities and original runs.

| Executed boundary | Result |
| --- | --- |
| Protocol 7 browser lifecycle in Chromium, WebKit and Firefox | 12 passed; normal exit 0; no skipped/flaky/unexpected cases |
| Affected editor/contextual/preservation/adapter regressions in three engines | 36 passed; no skipped/flaky/unexpected cases |
| Existing protocol 1/2 browser process-restart regressions | 9 passed; normal exit 0 |
| Modern and legacy native relay regressions | 13 passed, 210 assertions |
| Source/demo/modern-test/relay type checks; workflow syntax | Passed |
| JavaScript and bundled reference builds | Passed |
| Official pinned Swift/WASM rebuild and matching provenance | Passed; actual WASM hash unchanged |
| Isolated local package installation and new relay export | Passed; no registry publication |

Each browser performs actual editing, local save, browser process exit/restart,
server process exit/restart, offline reopen without credentials, rejoin and
peer-preserving author Undo/Redo. The column/appearance/title case compares the
complete expected document through a native Swift checker. Presence is ephemeral
and disappears after restart.

The recovery case starts from independently authored conflicting inputs, verifies
unchanged server bytes and original local accepted history/receipt on rejection,
reopens the retained proposal with readable accepted input, and explicitly repairs
only this author's rejected work. The peer's content survives. The capacity case
retains and exports the entire valid eight-million-character payload/history,
reopens it after real process restart, and retries the unchanged 8 MB rejection
without receipts or document clipping. Static application assets are served
locally; this is relay-offline recovery rather than service-worker/disk-cold
offline browser startup.

The separate actual WASM/IndexedDB contract injects HTTP failure/delay deliberately.
It checks that failed ACK persistence leaves work pending, duplicate retry authors
no extra transaction, deactivation/reactivation rejects an old response, wrong
receipt scope cannot apply valid peer data, and held packets/original drafts
remain inert across reopen until explicit release/retry. Author Undo then retains
the peer's work and opaque document metadata. This is not physical IME evidence.

## Retained failures and corrections

`browser-initial.json` retains three failed Chromium flows: storing native fetch
as an object method supplied an invalid browser receiver. The client now binds
the callable to its global receiver. `browser-fetch-repaired.json` passes capacity
but retains the rejoin/recovery failures caused by an empty restoration hold.
The host now holds only actual retained packets, so future valid peer work is
not indefinitely deferred. Valid retained recovery opens its accepted document
instead of closing the restored session when the expected recovery error occurs.
`browser-held-repaired.json` records the three focused passing Chromium flows.

`browser-candidate.json` retains three passing lifecycle checks and nine failed
process-case evidence guards. The run supplied incorrect label `a939dfc7` rather
than the exact source SHA; the provenance check was preserved. This is a failed
run even though workflow assertions executed. `browser-source-corrected.json`
records all twelve cases passing against the full exact implementation SHA.

`package-check.log` is the original missing-npm environment failure. The retained
npm 11.6.2 tool and the locked official Swift 6.4 compiler restored package
verification. `matching-wasm-build.json`, `matching-javascript-build.json` and
`local-package-provenance.json` pin the same clean inventory source. The WASM
hash remains `6f5febcfb962f735abde4bb8980aa175e568c64fd63c00404b83d512c73014fb`.
`package-export-verified.log` records an isolated installation, actual WASM editing,
legacy exports and the new offline relay constructor/export. Its local version
label is 0.2.0; it is not a registry release and must never replace published
private 0.2.0. Later delivery requires a new reviewed version and concrete approval.

## Reproduction and remaining acceptance

```sh
bun test tests/relay.test.ts tests/relay-recovery-limits.test.ts tests/modern-relay.test.ts
bunx playwright test --config playwright.modern-relay.config.ts
bunx playwright test --config playwright.relay-restart.config.ts
bun run typecheck
bun run demo:typecheck
bun node_modules/typescript/bin/tsc -p tsconfig.modern-tests.json --noEmit
```

The CI additions run modern native/server and all three browser checks alongside
the existing seven-runtime matrix. Fresh current-head CI and review remain
necessary. This candidate does not supply native Swift/Kotlin modern transport
bindings, every feature interaction, comprehensive accessibility, the 1,000-block
surface-performance thresholds, all-runtime private clean installation or Luca's
explicit final acceptance. Physical-device and final-review availability remain
deferred; their acceptance requirements are not waived.
