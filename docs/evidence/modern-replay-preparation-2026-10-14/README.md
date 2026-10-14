# Replay preparation and native accessible names

Engine `0468ef6` retains the exact immutable baseline byte count once per session
for history-capacity checks. The actual public envelope codec sizes a two-byte
placeholder plus all metadata/changes; replacing those two bytes with the exact
baseline count preserves the original byte limit and history reserve. Fifty-five
independent modern baselines and every change-body shape match public wire sizes;
the four legacy inputs still reject at modern admission. The count never enters
saved history and every fresh session owns its own count.

Role projection sorts only possible fallback candidates when all active
placements are initial identities with strict raw-byte order. Authored, role and
route identities retain the original full sort and every dynamic role/visibility
check. Historical String/UTF8 semantics remain unchanged. Unicode, peer-retained
paragraph roles, column routing and Undo expectations pass. The first focused
fixture run failed on four legacy documents; the repaired test explicitly asserts
those rejections and the original 55-document modern corpus.

| Verification | Result and source |
| --- | --- |
| Full native engine candidate | 600 core + 99 Apple + 8 other = 707 passed at 0468ef6 |
| Final focused engine | 29 cases passed |
| ABI / typed native consumer | 968 responses / 30 fixtures; 515 requests / 55 fixtures / 26 commands / 12 groups passed |
| Actual three-engine editor/context/preservation/consumer | All 63 passed |
| Actual JNI typed consumer | One complete consumer passed |
| Native/Android HTTP recovery | Five distinct processes with complete documents/history and terminal readbacks |
| Native label fix | Two focused cases and all 101 Apple cases passed at 49ee623 |
| UIKit iOS/visionOS | Both simulator targets compiled; no interaction or assistive claim |
| Final JS/declarations/WASM/JNI builders | Clean 49ee623 matching source receipts |

Native input `49ee623` refreshes accessible names on AppKit/UIKit updates instead
of only at creation. The original AppKit failure retains "Block text" after the
host label changes. Its repair keeps the exact native view, first responder,
marked Unicode buffer and original pending input. The full modern canvas updates
its accessible name through paragraph-to-heading conversion and Undo. These are
actual native metadata/interaction checks, not a full VoiceOver campaign.

The full native run predates the label-only change; the following full 101-case
Apple run is separate. Do not present them as one final-source 709-case suite.
Initial build receipts were refreshed before archival; they are not fabricated
as old receipts. Final genuine builders record 49ee623 and the tested WASM plus
APK-packaged JNI bytes match rebuilt artifacts by exact hash. Their code inputs
remain unchanged by the native-only label repair.

The frozen production run keeps the original 1,000-block fixture, three excluded
warmups, twenty samples per input/menu operation and original assertions.

| Browser | Typing p95 | Menu p95 | Result |
| --- | ---: | ---: | --- |
| Chromium | 378.8 ms | 61 ms | Input failed; menu passed |
| WebKit original | 818 ms | 85 ms | Input failed; menu passed |
| Firefox | 407 ms | 68 ms | Input failed; menu passed |
| WebKit affected repeat | 392 ms | 64 ms | Input failed; menu passed |

The original WebKit run has two spikes at 818/851 ms; the same-source affected
repeat retains all samples and does not replace that failed original. Every
run still fails 50 ms, while measured menus meet 100 ms. Direct calls/CPU/RSS do
not accept surface/resource budgets or prove a causal speedup. Broader shared
replay, full snapshot transport and rendering costs remain unresolved.

Earlier head 20ad970's hosted run 38546578169 now passes API26, Swift, general
and API35 x86 jobs at the recorded observation; WASM/ARM/parity are not yet
accepted. The API26 artifact verifies all five recovery processes and terminal
readbacks; no ps fallback happened in this successful run. Preserve the older
failed pidof255 evidence in modern-capacity-admission-2026-10-14. These hosted
results belong to that earlier candidate and do not qualify this new head.

Full prototype, native/browser/assistive/resource/private-install campaigns and
current CI/review remain open. Physical checks and Luca's final review remain
deferred without waiving criteria. Protected main, private 0.2.0 and concurrent
Foliostrate work are unchanged. [Receipt](receipt.json) and [hashes](hashes.json)
retain exact sources, results, limitations and original failures.
