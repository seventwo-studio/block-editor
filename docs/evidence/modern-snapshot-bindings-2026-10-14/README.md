# Exact snapshot sharing and checked renderer bindings

Runtime change `db04bade` shares only exactly equal immutable JSON subtrees,
including raw Unicode, signed zero, property order and opaque own keys. Snapshot
notifications and history/recovery flags still publish. Equal document values
do not imply equal causal identities: a changed receipt invalidates bindings,
including a peer replacement with identical text and reused labels.

Swift supplies the checked batch of actual schema nodes and destination fields.
React verifies its accepted schema traversal against that batch. Swift still
owns origins, field aliases, validation, mutations and author history. Older
runtimes fall back to individual reads only when the additive read is absent;
other errors propagate. Swift, bridge, TypeScript and Kotlin contracts match.

| Affected verification | Result |
| --- | --- |
| Focused native identity/structural/captured reads | Seven cases passed |
| Snapshot sharing/fallback unit checks | Three cases, twenty expectations passed |
| Native C ABI | 968 responses, thirty fixtures passed |
| Typed native consumer | 512 requests, 55 fixtures, 26 commands, twelve groups passed |
| Browser editor/context/preservation/consumer | 42 passed, three wrapper failures; affected three reran and passed |
| Browser relay/wire/recovery | Fifteen passed across three engines |
| Matching Kotlin/JNI typed consumer | One complete instrumentation case passed |
| Type/declaration, native, WASM and JNI builds | Passed; original compiler failures retained |

The browser contract completed its twelve groups before the wrapper failed
because it still expected eleven. `4639bd1d` updates that explicit count; no
expected fixture changed. The forty-five checks are qualified across the
original failed run and affected rerun, not one normally exited full suite.
Full required exact-head CI remains necessary. Earlier full native results do
not become a current full-suite pass.

The unchanged production workload has 1,000 mixed schema blocks. At frozen
`4639bd1d`, observed twenty-sample input p95 is 3,122.5 ms Chromium, 5,047 ms
WebKit and 5,279 ms Firefox. Chromium completed twenty menu samples, p95
1,616.4 ms, and preserved the document/history. WebKit and Firefox reached the
unchanged 240-second deadline after fifteen and six menu samples. These are
failed performance outcomes against the unchanged 50/100 ms targets. A completed
Chromium harness is not a target pass. Static JS/WASM stayed frozen, but creating
this evidence directory while the serial run was active caused the later
engines' source-clean flag to be false. That discrepancy remains in raw reports;
it is not normalized into a clean-source campaign claim.

Earlier `b7e4ac1` CI `38512832161` finished with general, Swift and WASM successes,
three Android provenance failures and failed parity. All Android rows reached
the clean-checkout provenance gate after instrumentation. An isolated Git
reproduction shows Python imports generating untracked bytecode with Linux-style
cache behavior. `4639bd1d` disables that bytecode generation in CI and includes
dirty paths in future provenance diagnostics. The reproduction passes and still
rejects untracked source; no exclusions or clean-source requirements are relaxed.
Fresh hosted CI must verify the remedy. Original job logs and receipt are retained.

Remaining authoring/rendering costs, full interaction/accessibility/resource,
private-install and native campaigns stay open. Physical checks and Luca's final
review remain deferred. Private 0.2.0, protected main and concurrent Foliostrate
work are unchanged. [Receipt](receipt.json) and [hashes](hashes.json) pin these
qualified results and retained failures.
