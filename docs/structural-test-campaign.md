# Structural collaboration test campaign

The v2 campaign covers root blocks, toggle children, list items, table rows and
table cells. It supplements focused protocol, cycle, collision and recovery
regressions; it does not establish unrestricted convergence or complete ST-96
resource/repair acceptance.

## Generated Swift histories

`GeneratedStructureTests.swift` runs the Cartesian product of five collection
kinds and eight fixed seeds: 1, 7, 42, 255, 65537, 20260930, 999983 and 4294967295.
Each of the 40 cases uses three authors and 18 rounds. A round gives each author
an insert, move, text, format, delete, undo or redo slot; a slot may be a no-op
when its collection is empty or history has no action to reverse. The generator
uses a fixed UInt64 linear congruential sequence, not the system random source.

Each case starts with concurrent placement of the same identity at different
parents (or different root anchors). Actor zero then remains disconnected for nine
rounds, including save/restore. Other authors exchange shuffled partial batches
with duplicate changes. Every fourth round replaces each session with its restored
instance. Final delivery supplies the complete union in independently shuffled
orders; all three documents and the independently collected receipt set must match.

Local insertion and movement have exact payload checks, and text insertion has an
independent string expectation. The payloads include emoji sequences, combining
characters, Japanese and Hebrew text, marked text, atomic entity references,
descendants and opaque metadata. A final sentinel has concurrent author formatting
and text additions. Undo in shuffled author order removes only that author's text;
redo restores the complete document. Undo of local bold retains remote code marks,
and removing both formats restores the original payload exactly. Removing the
sentinel restores the pre-sentinel document. Settled saves restore documents and
receipts, and intermediate saves also preserve undo/redo availability.

Failures name the seed and collection. Command failures include the last twelve
round/author/operation entries, so a failed history can be reproduced with:

```sh
"$SWIFT_BIN" test --filter generatedStructuralCollectionsOfflineEditsAndHistoryConverge
```

## Shared Swift/JNI/WASM histories

`scripts/generate-collection-history.py` appends 40 labeled cases to the existing
`structure.json`. It constructs commands and expected documents without calling
the editor. The original 212 steps and their oracles are retained. Each new case
has 44 commands; eight document checks per case give 320 independent preservation
oracles, rather than accepting equality between replicas alone.

Two authors start disconnected. A moves and types; B types, formats and makes a
competing move. A saves, closes and restores before receiving B's work. Both sides
receive duplicate batches. A's text and movement undo must preserve B's placement,
text, bold mark, original italic text, references, descendants and metadata. Redo
and a second undo cycle run before B undoes its three actions. Both documents and
a final reopened snapshot must equal the pristine baseline. Before undo and after
redo, independent documents must contain both authors' additions.

The seed selects the source member and parent; the native campaign additionally
generates longer mixed histories and delivery schedules. The shared cases are not
a cross-runtime replay of all 18-round native histories. Both use the same five
collection categories and retain distinct coverage claims.

```sh
python3 scripts/generate-collection-history.py
python3 scripts/generate-collection-history.py --check
"$SWIFT_BIN" test --filter sharedStructureBridgeFixture
bun scripts/run-native-compatibility.mjs .build/debug/editor-bridge
COMPATIBILITY_OUTPUT=/tmp/collection-reports bunx playwright test --config playwright.swift.config.ts tests/runtime-compatibility.spec.ts
python3 scripts/run-android-ci.py 26 x86_64
bun scripts/compare-runtime-reports.mjs /path/to/runtime-reports
```

Native Swift, browser WASM and Android JNI executors each require every named
document capture and compare its blocks with the independent oracle. The shared
structure transcript now contains 1,972 commands; together with the unchanged
bridge, recovery and migration corpus, each runtime report contains 2,297 actual
responses. CI checks that the generated fixture is current and runs the existing
seven-runtime matrix, including API 26 and all three browser engines.

The Android executor streams each response to a fixture file and assembles the
report with buffered reads. It retains the complete transcript without building a
second large JSON string in the instrumentation heap. Failure paths still publish
the executed responses and close live sessions; incomplete reports fail parity.

Runtime fixtures do not accept platform input, accessibility, full reference-host
process recovery, production browser migration or private-package delivery. These
remain separate Linear gates. ST-95 delivery also requires reviewed merge and
actual default-branch verification; ST-96 retains its threshold/concurrent repair
and host recovery work.
