# React/WASM migration

ST-47 keeps browser rendering and input in React and moves shared editing semantics
to Swift. ST-45 and ST-46 deliver native authoring first; ST-104 verifies the migrated
production editor in Chromium, WebKit and Firefox. These gates remain open.

## Current integration

The production `./react` export and `demo/src/App.tsx` use the TypeScript editor.
`./swift/react` provides an opt-in `SwiftBlockEditor` and `SwiftEditorSurface`.
The host supplies WASM bytes or a compiled module, document identity, actor identity,
initial blocks or an accepted snapshot. The adapter shows loading and failure with
Retry; canceled loads cannot publish an obsolete session. A host connection failure
closes the created session, and host disconnection cannot prevent session cleanup.

`tests/swift-loading.spec.ts` covers this lifecycle with controlled runtime sessions.
Malformed WASM and missing exports exercise the real WASM initializer. Run this suite
without compiling Swift using:

```sh
bunx playwright test --config playwright.swift-loading.config.ts
```

This suite establishes loading behavior only. It does not validate Swift editing,
protocol migration, system IME, persistence or production feature parity.

## Remaining shared behavior

| Workflow | Current Swift React behavior | Required handoff and acceptance |
| --- | --- | --- |
| Paragraph Enter and boundary Backspace | Enter inserts an empty paragraph; no merge | Shared split/merge, one author undo, marks/references and resulting caret preserved |
| Slash menu, conversion, Markdown shortcuts | No adapter controls | Shared writing/conversion commands plus caret menu, restrictions and composition guards |
| Inline formatting | Browser `InlineEditor` transforms inline nodes, then `setInline` | Swift owns formatting semantics; contextual tools and keyboard input use stable selections |
| Plain/rich structured paste | Inline paste sends plain text through `replaceText` | Browser decodes clipboard; shared command validates structure, identities, references and host restrictions |
| Dragging, indentation and nesting | Root Move up/Delete only | Shared node commands with insertion preview, keyboard/accessibility equivalents and preserved descendants |
| Cross-block selection and batch edits | Per-field DOM selection only | Shared selection/batch commands and browser range/focus adapter |
| Lists/tables/toggles | Existing item/cell/summary text editable; no creation/restructuring controls | Shared authoring commands, recursive lists, row/cell editing and checklist continuation |
| Images and embeds | Host `renderImage` or preservation text; embed title/URL text | Host-controlled resolution/upload/editing and safe embed policy; no implicit network access |
| Offline authoring and recovery | Separate reference host owns accepted/pending persistence | ST-96/ST-105 host workflows and all-browser process reopen; accepted receipts remain separate |
| Production entrypoint | TypeScript engine remains default | Switch after native command/input handoff and ST-104 acceptance with exact source/artifact provenance |

## Shared command handoff

ST-42 owns `src/swift.ts` and the core ABI. Its in-progress version 3 design opts in
with a separate collaboration epoch, preserves document IDs and legacy defaults,
and returns positions based on immutable writing atoms so carets can follow
split/merge. The React adapter must consume the tested typed command/result API.
It must not imitate missing shared semantics by replacing nested JSON in TypeScript.

ST-96 owns the browser recovery/storage host; ST-105 owns relay process-restart
acceptance. Coordinate overlapping files before changing those integrations.

## Acceptance evidence

Record the source SHA, WASM hash, browser/version and local/collaborative mode for
each interaction run. Exercise Unicode, marked text, atomic references, paste,
selection, composition, host-controlled images, author undo and offline rejoin.
Dispatched composition events, Chromium IME protocol input and actual system IME
are separate evidence. Keep system IME/file-picker gaps explicit. Successful loader
tests and opt-in reference interaction do not establish production migration.
