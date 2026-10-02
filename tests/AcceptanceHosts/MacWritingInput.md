# Shared writing native acceptance host

This extends the existing `MacWritingInput` host with the same `WritingBlockEditorView` used by consumers. Every epoch is explicit; no legacy session, actor history or stored epoch is upgraded. Build or foreground use requires the coordinator's exclusive slot. Use Computer Use for all Mac input and screen observation.

```
bash scripts/build-apple-writing-host.sh 6 /absolute/issue-owned/evidence REVIEWED_SOURCE_TREE --build
```

The script is build-only. Launch the resulting `.app` and observe its foreground UI through Computer Use under the shared foreground reservation; no shell launch path is included.

Run separate protocol4/5/6 campaigns and separate minimum/current OS campaigns. The evidence directory is task-owned and synthetic fixture content only. Relaunching a protocol restores `protocol-N/archive-state.json`; choose a fresh evidence directory for a clean baseline. The script records exact staged tree, module/app hashes and SDK/runtime. A staged tree and preceding HEAD commit remain distinct source identities. Compilation or a foreground app is not accepted interaction.

## Actual host workflows

1. In the full editor, focus ORIGINAL in LEFT, select a reversed Unicode range, and compose using an actually installed input source. Schedule the45-second peer move, then return to the control before it arrives. The peer moves its opaque origin to RIGHT and inserts REPLACEMENT at the old LEFT/p path. Observe native marking, focus, selection and subsequent typing: they must follow ORIGINAL, and REPLACEMENT must remain unchanged. Repeat without composition, during composition and after reopen.
2. Schedule peer R15seconds before a real composition. Exercise native Enter, Shift-Enter, Backspace merge, contextual formatting, copy and real system paste while the batch is held. Verify marks, Task reference, original consumer metadata, returned destination caret and one author Undo/Redo; peer R must survive. Protocol4 plain text uses inline paste, including literal line breaks; protocol5/6 broader paste stays explicit. Protocol6 supports the shared cross-container command, while this native UI's cross-field selection remains unverified. Also test read-only transition, old disposed controls and failed native drafts through the current full view.
3. Select `Arm math race` with the fixture expression AB. In the actual Math native control delete only A, leaving accepted B. `Peer delete B` applies a concurrent deletion from the armed accepted prefix, yielding a required-field recovery proposal while the displayed accepted expression remains B. `Try empty repair` must retain exactly the accepted save and pending export. `Checkpoint` exports both; quit and relaunch the same host. The proposal remains pending. `Repair expression to R` explicitly admits a valid union; retry and inspect full retained history. Native composition failures and archived drafts remain visible, never silently reapplied.
4. Repeat offline native writing and author Undo/Redo before checkpoint/process restart. Retain both the archive and event log before and after restart. A marked native value is exported separately as an *unbound native observation*, requiring operator reconciliation; it is never treated as an accepted shared edit. Failed model drafts carry their original address, text and selection. This is recoverable evidence, not automatic draft reattachment acceptance.

The buttons are host-controlled peer/persistence/recovery operations. They do not synthesize key presses, composition, formatting or clipboard callbacks. Evidence records actual responder text, marked range, selection, opaque origins, accepted receipt, separate pending material and module source. Compare captured screens and archives with the independently expected text/ref/marks before checking a criterion; the observer has no `passed` flag.

## Per-family evidence boundary

| Family | Current preparation | Required actual acceptance |
|---|---|---|
| macOS | This full-view host, explicit4/5/6; compiled host pending at this checkpoint | OS26 and current runtime, installed IME/input source, keyboard/pointer, clipboard/consent, origin move/label reuse, recovery/restart, VoiceOver |
| iOS/iPadOS | Current shared UIKit input and full editor module; previous SDK27/deployment26 compilation is historical | Matched current-source host installation on OS26/current runtimes, real touch/keyboard/IME/paste, assets and VoiceOver; test phone and tablet separately |
| visionOS | Shared UIKit adapter; historical direct module compile, historical SwiftPM before-source trap | Matched current-source installed host, OS26/current runtime, actual indirect input/focus/IME/paste/assets/VoiceOver |
| watchOS/tvOS | Agreed smaller reading/text/checklist/order surface; historical SDK27/deployment26 module compilation | Actual OS26/current runtime/device or available simulator controls, accessibility and richer-content preservation |

This increment does not close ST-102 or ST-45. Slash menus, multi-block native selection, drag/nesting presentation, complete asset picker/storage integration and every family's actual accessibility scope must be verified separately. SDK27 with deployment26 cannot stand in for OS26 runtime proof. The existing legacy identity host and earlier PR evidence are unchanged.
