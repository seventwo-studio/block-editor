# Shared reads, captured cohorts and the failed mixed-surface baseline

Structural read reuse is `0cf341ad`; validated cohort reuse is `6a00550`;
snapshot-scoped React bindings are `ca3dad7`, with schema-only outline traversal
at `a5d8fe7`. The initiating-keydown measurement is `f983e0c`.
The code and expected corpus were frozen during the affected execution; later
documentation/harness-only commits do not alter shared/native runtime inputs.
[receipt.json](receipt.json) pins source/results/artifacts and qualifications.

| Boundary | Completed evidence |
| --- | --- |
| Full native Swift regression | 580 core, 99 Apple and 8 other tests passed; normal exit |
| Native ABI / typed consumer | 968 responses / 30 fixtures; 504 requests / 55 fixtures / 26 commands |
| Affected browser interaction/preservation/typed consumer | 42 passed across Chromium, WebKit and Firefox |
| Real modern/legacy server, wire and process regressions | 14 passed / 226 assertions |
| Matching actual JNI/private host/codec/typed consumer | Eight plus nine plus one tests passed on owned API35 arm64 emulator |
| Matching independent Android HTTP/recovery | Five phases / five distinct PIDs passed |
| Integrated modern browser relay/wire/recovery | Fifteen passed across the three engines |
| Shared/native/WASM/JNI and production measurement builds | Passed |
| Frozen matching JS/declarations/WASM and isolated package | Passed at `a352a38d`; local installation only |
| 1,000 mixed-block surface input/menu budgets | **Failed/incomplete**, not accepted |

The fixed workload has 1,000 schema blocks (860 roots), including twenty valid
two-column layouts, wide tables, code, lists/toggles, images, headings, references,
Unicode and opaque data. Existing acceptance documents were not regenerated.
The available host is Mac16,9, 14 logical cores, 36 GiB memory and macOS 27.0.1;
raw hardware is retained in `hardware.json`. The local Android runtime/SDK
identities remain those qualified in the earlier Android campaign.

The initial valid production render exceeded four minutes without samples.
A native debug CLI diagnostic measured repeated same-origin reads at about half
a second; its boundary includes IPC/JSON and is not surface acceptance. Sharing
validated placement/address/order results fixes repeated structural work while
value-copy mutations invalidate only that copy. Independent tests cover nested
mutation, deletion/touch visibility, moves, original identities and Undo/reopen.

The next original run rendered but failed its first input check. The profiled
run found repeated 2.8-second mark/semantic reads rebuilding admitted captured
cohorts, plus repeated contextual scans. Current/previous cohort reuse validates
closure before returning a read; unknown/duplicate IDs still reject. One bounded
historical read is ephemeral, never a saved or replicated authority. React reads
Swift-returned identities once per accepted snapshot; a new snapshot replaces
the bindings. Tests preserve opaque arrays named like schema collections and
replace a deleted/reused label's binding while retaining peer work through Undo.
The outline likewise ignores consumer data that resembles a heading.

The final **uninstrumented initiating-keydown** run has sixteen verified
accepted-text/display samples: 9,371–9,487.2 ms, median 9,411 ms. It then exhausted
its four-minute deadline before twenty samples and menu measurements. This
contradicts the 50 ms input target. It does not establish a complete input p95,
menu result or accepted performance. Preserve the same workload and profile/
repair the remaining authoring/snapshot path. The read fixes alone do not solve
that path. Method and remaining requirements are in
[the surface contract](../../modern-surface-performance.md).

## Original failures and qualifications

The first generated workload used an invalid callout attribute. Its exact input
and rejected result remain here; the corrected required `variant: info` passed
unchanged native admission. This was a new fixture error, not a passed product
check. Compiler/type failures are retained alongside the repaired checks.

The captured-read literal test initially omitted the empty marks emitted by the
public `textNode` constructor for newly authored plain text. The expected two
segments were corrected explicitly from that constructor's contract; original
baseline/peer inputs and the existing corpus stayed unchanged. The failed
original and passing literal result are separate files.

The local test APK installation failed because its debug signature differed
from the existing owned-emulator test package. Only that test package was
replaced, with earlier proofs retained; the matching eighteen checks then passed.
This does not change production/Git signing credentials or user hardware.

Earlier exact-head CI `38493147964` passed general, Swift, WASM and both x86
Android jobs. Translated ARM exceeded the whole-host-suite 300-second deadline
at the large retained-history test after six completed tests, so parity failed.
Original partial instrumentation, sanitized job output and raw log hash remain
failed evidence. The repaired driver retains all nine assertions in one process
and gives this translated row a bounded 600 seconds; other rows remain 300.
No input size, case count or surface target is reduced. Fresh CI must still pass.

Complete functional/rendered/assistive/resource/native/browser performance,
resized/stacked/scroll/selection/resolved-media workloads, larger-document
preservation, all-runtime private installation and explicit acceptance remain
open. Physical/final-review availability is deferred. Private registry 0.2.0 is
unchanged; a local build is not a new release or approved protected-main landing.
