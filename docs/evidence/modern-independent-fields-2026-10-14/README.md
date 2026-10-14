# Checked field reuse and complete Android fixture readback

`d66db54` reuses immutable baseline atoms, groups structural placements by
collection and validates the final appearance/document envelope once.
`6ac855c` shares checked scalar-field projections, rebuilds changed fields with
the original graph algorithm and uses direct retained-key membership for caret
and paste validation. Cross-field edges, transfers, joins, aliases and different
Unicode wire spellings retain full replay. Durable histories have no cache data.
Literal tests check peer text/marks, tombstones, Unicode offsets, virtual heads,
author deactivation, malformed keys and exact captured spelling against complete
graph replay. Opaque appearance and signed zero remain exact.

| Verified boundary | Result |
| --- | --- |
| Full native run before final lookup/wire guard | 588 core + 99 Apple + eight other tests; normal exit |
| Final affected native projection/history/paste | 89 tests; normal exit |
| Final native C ABI / typed consumer | 968 responses / 30 fixtures; 504 requests / 55 fixtures / 26 commands |
| Final affected browser editor/context/preservation | 42 cases in Chromium, WebKit and Firefox; normal exit |
| Matching API35 arm64 HTTP/recovery | Five distinct processes, terminal readbacks and complete documents passed |
| Complete fixture reader | Four injected-outcome tests and exact real native-proof readback passed |
| Direct actual-WASM author probe | Accepted appends 1,104–1,131 ms; not a surface budget pass |

The fixed 1,000-block workload and existing expected documents are unchanged.
Field/collection work alone measured about 2.6 seconds per append. The first
independent-field probe overlapped native regression and is retained as
contended; its source patch hash omits then-untracked files. Later serial probes
pin every source file, including new files. They expose the retained-set rebuild
cost: direct membership lowers no-op shortcuts to 25–29 ms and mark reads to
about 1 ms. Process resident memory is diagnostic, not resource/lifetime proof.
The unchanged 50/100 ms rendered targets remain unaccepted.

The frozen production candidate at `e72376b2` recorded all twenty input/display
samples per engine after excluded warmups: observed sample p95 is 3,943.8 ms in
Chromium, 6,591 ms in WebKit and 6,528 ms in Firefox. Every combined campaign
then reached its unchanged 240-second deadline during menus, retaining fourteen,
seven and zero menu samples respectively. All three terminal results are failed
and incomplete; no complete menu p95 or combined acceptance exists. Chromium's
focus assertion includes a closed-session error after the overall timeout and
does not independently establish a focus defect. Keep the original workload,
rendered targets and raw reports. Remaining full snapshot/binding work must be
repaired before repeating this campaign.

Prior `f6603602` CI `38507059718` passed general, Swift, WASM, API26 x86 and
translated API35 ARM. API35 x86 failed after passing RuntimeCompatibility
instrumentation: the corpus transfer is truncated at 1,753,088 bytes, and the
subsequent environment read exits 255 with empty output. Guest diagnostics show
the ADB transport closing/reconnecting around this boundary. The raw partial
corpus, original job log, contextual guest excerpt and complete artifact hashes
are retained. Parity consequently failed; these failures remain failures.

`e72376b` streams and hashes fixture copies against the immutable native file,
retaining partial bytes and failure receipts. Recovery is bounded to three
attempts for an empty exit 255 or a byte mismatch. Missing, denied and malformed
small-source reads fail immediately; timeouts retain captured output and fail.
Large aggregate reports remain streamed and require the existing full parity
verifier. All instrumentation, environment, resource and fixture comparisons
remain required. The real reader check uses an exact copy of the completed
synthetic native redo proof in the owned test package; it does not establish a
repaired hosted API35 run. Fresh exact-head CI remains required.

Original test/compiler failures remain beside repaired results. Initial literal
signed-zero and missing-return compilation failures are harness/code failures;
the malformed-source test initially supplied the wrong digest and failed before
its corrected explicit digest case passed. No expected fixture was regenerated.

Complete rendered/input/assistive/performance/resource and private-install
acceptance stays open. Physical devices and Luca's final review remain deferred.
Private registry 0.2.0 and Foliostrate work are unchanged; no merge or new release
is claimed. Source, raw reports and qualifications are pinned in
[receipt.json](receipt.json).
