# Native modern relay and paired reopen

The native reference at `fce23516081a36eaec3570a1eeb28640b41003f4` adds protocol-7
URLSession synchronization to the existing modern Apple model and serialized
paired store. It closes the empty restored-hold gap and persists stable relay
receipts alongside author history, recovery, actual held packets and original
input. [The contract](../../modern-relay-reference.md#native-swift-reference)
contains integration and ownership boundaries. [receipt.json](receipt.json)
and [files.json](files.json) pin sources, binaries, result logs and failed runs.

| Boundary | Result |
| --- | --- |
| Frozen native relay/input/clipboard/storage/provider/focus candidate | Initial 26 passed; final 27 passed, six suites;; normal exit 0 |
| Actual URLSession and separate real relay/native bridge process | Passed, including 13 independent exited native client processes and server exit/restart |
| Existing iOS reference app and new native APIs | Simulator build succeeded; signing disabled |
| Earlier contextual source `c5a41138…` | All seven required CI jobs passed; qualifies that earlier source only |

The real HTTP test loads the independently authored `columns-7000.json` corpus
document, synchronizes title, appearance and shared split edits by separate
authors, and compares the complete document, including nesting and opaque
metadata. It stops the server, restores from paired disk without credentials,
authors offline, restarts the server with its retained disk, rejoins and checks
two author Undo/Redo operations while peer appearance and layout survive.
Presence disappears on server restart. The initial test recreates client objects in one test process. The follow-up at
`e1ed08be43099fdfc1ab1b0303d7c5a8d50a30c5` instead executes thirteen independent
`modern-relay-client` processes, each restoring from disk and exiting normally.
It verifies offline authorship with the server stopped, restart/rejoin, complete
fixture equality and successive author Undo/Redo across separate invocations.

Seven injected native lifecycle cases use actual Swift sessions and paired disk:
failed ACK save and duplicate retry, input authored during transmission,
document/credential ABA, durable rejected recovery and own-only repair,
held packets and inert original marked input, duplicate envelope keys/foreign
epochs/unknown receipts, and capacity rejection retaining original local history.
Native input/clipboard/focus and provider/migration regressions run with them.
The 8 MB byte-edge and larger complete archive remain independently verified by
the prior native server/browser campaign; this native adapter capacity case
deliberately injects 413 and is not a new byte-edge test.

`initial.log` records the four passing native storage cases before the adapter.
`relay-tests-initial.log` records the first fourteen passing lifecycle/storage/
provider cases. The two original real-HTTP test compilation failures remain:
`real-http-initial.log` lacked throwing expectation syntax;
`real-http-compiled.log` supplied a NodeID where the existing API requires a
captured ModernColumnTarget. `real-http-captured-target.log` passed that corrected
test. `native-candidate.log` records the frozen 26-case affected run after removing
new test capture warnings. Expected document content and parser rejection checks
were preserved. `client-process-initial.log` retains a further test compiler
failure: asynchronous process ownership lacked main-actor isolation.
`client-process-isolated.log` passes both corrected process tests, and
`native-process-candidate.log` passes the frozen 27-case native candidate.
`runtime-provenance-tests-final.log` passes eight provenance cases, including
rejection when the modern native client binary is absent. CI builds both required
executables before these tests. No source edits occurred during either frozen
candidate.

Reproduce with pinned repository dependencies and Bun on PATH:

```sh
swift test --jobs 2 --filter '(ModernNative.*Tests|ModernHostStoreTests|ModernProviderActivationTests|NativeFocusTransferTests)'
xcodebuild -project Examples/AppleDemo/EditorLab.xcodeproj -scheme EditorLab-iOS \
  -destination 'generic/platform=iOS Simulator' -derivedDataPath <owned-path> \
  CODE_SIGNING_ALLOWED=NO build
```

Simulator compilation does not establish rendered/touch/assistive acceptance.
The native Kotlin binding, every required feature/platform scenario, long-document
performance, all-runtime private clean installation and explicit final acceptance
remain in the finishing project. Luca deferred device and final-review availability.
Fresh current-head CI/review and any later versioned private delivery are still
required. The installed/published private 0.2.0 artifact was not replaced.
