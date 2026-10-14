# Exact capacity admission and Android terminal readback

Runtime source `fd7955a` avoids full-document encoding solely to prove the 32 MB
capacity limit for ordinary admitted values. A conservative bound reserves six
JSON bytes per UTF-8 string byte plus structural punctuation; numbers retain
actual codec sizing. When that bound cannot prove capacity, the original exact
encoder decides. A loose estimate never rejects otherwise valid content. Schema,
depth, finite numeric, opaque data, history and causal checks remain unchanged.

Literal escape/Unicode/numeric cases and unchanged acceptance documents exercise
exact byte boundaries. A complete document containing a large opaque field at
exactly 32,000,000 bytes is admitted unchanged; one byte more is rejected. The
initial compiler-cache sandbox error and missing-try compile error are retained
beside their repaired pass.

| Matching runtime verification | Result |
| --- | --- |
| Focused native capacity/document | 15 passed |
| Full native | 598 core + 99 Apple + 8 other = 705 passed |
| Native ABI | 968 responses / 30 fixtures passed |
| Typed native consumer | 515 requests / 55 fixtures / 26 commands / 12 groups passed |
| Three-engine browser editor/context/preservation/consumer | All 63 passed |
| Matching actual JNI typed consumer | 1 case, normal instrumentation |
| Matching clean JS/declarations/WASM/JNI | Built from fd7955a |

Two sandbox server-start failures precede the authorized browser pass; its
original configuration and all assertions stayed unchanged. This capacity fix
has only modest diagnostic impact; direct append sampling is qualified by
concurrent regression work and excludes surface rendering/resource acceptance.

The frozen production run retains the same 1,000-block fixture, three excluded
warmups and every twenty input/menu sample with original verification boundaries.

| Browser | Typing p95 | Menu p95 | Result |
| --- | ---: | ---: | --- |
| Chromium | 389.5 ms | 48.9 ms | Input failed; menu passed |
| WebKit | 465 ms | 65 ms | Input failed; menu passed |
| Firefox | 435 ms | 67 ms | Input failed; menu passed |

All tests correctly fail the unchanged 50 ms input target; measured menus meet
100 ms. Chromium input does not improve relative to the preceding run. Broader
replay, immutable-baseline capacity encoding and full-document publication remain
costs to resolve. No surface acceptance or aggregate speedup is claimed.

Hosted run 38543944129 at prior PR head 03adbf45 fails API26 x86_64 after preceding
instrumentation and two complete recovery phases. Rejoin data validated, then
`pidof` returned empty output and exit 255 during terminal verification. The
original log, failed receipt and complete phase proofs are retained. Partial
content successes do not become a successful process-recovery campaign.

Repair `f399bad` allows this ambiguous empty status only after a fresh successful
`ps -A` read with a recognized header, real complete PID rows and no package or
package-service process. Nonempty errors, malformed/empty lists, live processes
and failed transport still reject. Five unit cases/twenty expectations pass.
An actual owned API35 process listing verifies the fallback, with 255 injected
only after a real absent pidof response; it is explicitly not an API26 rerun.
The matching native/Android HTTP campaign passes all five distinct processes
with full documents, history and terminal readbacks after the repair. Fresh
required hosted API26 verification remains necessary.

Physical checks and Luca's final review remain deferred without waiving them.
Full native/browser/assistive/resource/private-install/final campaigns and current
hosted CI/review remain open. Protected main, private 0.2.0 and concurrent
Foliostrate work are unchanged. [Receipt](receipt.json) and [hashes](hashes.json)
pin sources, original failures, all samples, runtime artifacts and qualifications.
