# Table interaction capture and completed failed measurements

`fd83d10` removes table-target capture from every rendered cell. Opening a
cell-action menu captures checked opaque origins/cohort, row width/count and
header intent together. Peer changes retain the capture; incompatible structure
rejects without mutating document/history. Successful actions dismiss. Reopening
captures updated structure. Replacement origins remount their local controls.

All nine focused keyboard/peer/Undo/structure/reopen checks pass across Chromium,
WebKit and Firefox. The full affected editor/context/preservation/typed-consumer
run then passes all 54 cases with normal exit on the frozen renderer. Existing
expected acceptance JSON is unchanged. JS/declarations and actual WASM build
clean at `90f4e12`; its further change adds explicit measurement budget assertions.

The short instrumented diagnosis observed nearly 50,000 table captures before
the remedy and none in the same post-remedy render/input/menu sequence. Those
profiles pin fixture/WASM hashes but omit JS bundle hashes; the after profile
precedes final dismissal wiring. They explain the repair and are diagnostic,
not immutable final-source or performance acceptance.

The final uninstrumented serial run completes all twenty input and twenty menu
samples after three excluded warmups in every engine. Each report records clean
source, the unchanged 1,000-schema-block fixture and matching WASM. Trusted
initiating input, accepted/displayed content, menu focus, history preservation
and second-frame verification remain unchanged.

| Browser | Input p95 | Menu p95 | Result |
| --- | ---: | ---: | --- |
| Chromium | 1,644.1 ms | 139.6 ms | Both targets failed |
| WebKit | 1,852 ms | 241 ms | Both targets failed |
| Firefox | 2,240 ms | 285 ms | Both targets failed |

Targets remain 50/100 ms. Measurement completion is separate from target success;
all three tests terminate with explicit budget failures, without deadline
truncation. Previous original failures remain retained. The host is Mac16,9 /
Apple M4 Max / 14 logical CPUs / 36 GiB / macOS 27.0.1. This does not establish
physical input, assistive, resolved-media, resource or full platform acceptance.

The initial WASM stamp failed at sandbox-denied SwiftShims cache writes. The same
pinned compiler/SDK build succeeds with permitted existing-cache access; both
logs remain. Prior required CI belongs to `6b18a917` and was running at capture;
fresh candidate CI/review are required. No merge, private release or concurrent
Foliostrate change occurred. Physical/final-review checks remain deferred without
a waiver. ST-142/ST-104 stay open for remaining authoring/snapshot/rendering costs
and their full campaigns. [Receipt](receipt.json) and [hashes](hashes.json) pin
raw results, matching build receipts, hardware and retained qualifications.
