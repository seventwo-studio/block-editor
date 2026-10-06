# Integrated implementation evidence — 6 October 2026

This is a qualified snapshot for cumulative PR #70 and P-ST-85. It preserves
failures as well as reruns. It does not replace required current-head CI, code or
security review, private publication, consumer access or product acceptance.

## Source and scope

The broad Swift rerun ran the integrated source preceding the final catalog-focus
and containing-block insertion changes. It passed 571 Core tests, 89 Apple host
tests and eight transport tests. The original broad run failed opaque duplication
and `asset://` replacement; the implementation was corrected before that rerun.
The original failing log remains alongside the successful log.

Containing-block insertion and 19 paste fixtures were checked at
`1d6db3799219f53eb20985be583eefdba213e062`. They independently check a table-cell
and nested-list query, exact order, query consumption, Undo/Redo and restored
selection history. The earlier focus fixture incorrectly restored the session
without its paired selection history; both its failure and corrected paired
rerun are retained. A session save alone is not a complete host checkpoint.

The browser smoke at that source passed Chromium and WebKit for title/body,
Unicode, code language/text, table cells, exactly two columns, narrow stacking
without split mutation, slash cancellation and local image/caption reopen. The
initial global Insert failure from a table cell was a shared-boundary bug. The
subsequent failure was an ambiguous test locator matching both table descriptions
and Two columns. Both failing logs are retained. A frozen rerun passed; source
was not edited while that rerun was active.

Later captured-formatting checks cover browser selected Unicode, current-state
controls and shared Undo, plus native Format cancellation/focus. Their logs are included: six Chromium/WebKit checks and the iOS
Format cancellation/input/reopen check passed. The initial iOS test invocation
used an incorrect target name and failed before testing; that runner failure
is preserved separately from the successful corrected invocation. Android recovery and modern Compose checks run actual
JNI, not mocked mutations. The corrected recovery fixture identifies the peer
block by its captured identity instead of assuming it is the last display row;
it also checks that the original image survives.

## Required CI and unresolved checks

At `a2eb0ab3f818375a73034fff6e7d1e5255921c6e`, required `test` passed. WASM
compiled but provenance verification failed before browser execution. Source
digest dictionaries were compared through order-sensitive JSON serialization;
the fix compares every path/hash independently and records deterministic input
ordering. It still rejects changed, missing or added source files, stale artifact
hashes, dirty source and a different commit. The focused fixture covers those map
conditions. This cause remains subject to the new required CI rerun; the original
job log is preserved, and CI now retains build receipts for diagnosis.

All three Android jobs reached the modern consumer fixture and failed its
last-row assumption with `No value for content`. The exact job evidence is
retained. Local actual-JNI recovery and Compose reruns pass after correction;
new remote jobs must still pass before delivery.

Local Firefox could not launch its profile, including a clean explicit profile.
No Firefox editor assertion ran, so it is not a passed browser check. The remote
WASM job still requires all three engines. Comprehensive browser and physical
native campaigns remain in the separate finishing project.

## Distribution

An isolated 0.2.0 tarball from `1d6db3799219f53eb20985be583eefdba213e062`
installed and executed actual packaged WASM, checked modern and legacy exports,
React server rendering, declarations and CSS. Its npm integrity is recorded in
`isolated-package-install.log`. It is an earlier candidate identity; final source
requires matching rebuilt receipts and a fresh package identity. It was not
published. ST-34/ST-144 remain open until actual private artifacts, approved
Foliostrate access and usable handoff are delivered.

`files.json` records SHA-256 hashes of these retained logs. Source/runtime receipts
in the candidate package and required CI identify the exact final artifacts.
