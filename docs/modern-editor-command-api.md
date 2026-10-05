# Implemented modern command API

ST-122's protocol-7 session uses immutable format-1 ModernDocument snapshots. Create with createModern and collaborationVersion 7; legacy create/restore do not promote an old session. The shared C ABI routes the new JSON endpoints. Typed Kotlin/TypeScript wrappers and executed Android/WASM parity remain unfinished.

A modernCommand request has documentID, epoch, command, target and arguments. Results carry status (applied/noop/unavailable/recoveryRequired), the materialized snapshot, actual admitted author transaction, and local focus/selection intent. Unsupported commands and host/composition policy restrictions return unchanged unavailable results. Malformed schemas, wrong scope and invalid/stale targets return the existing structured error boundary. Pending retained recovery disables further conflicting author edits. A result is planned against the validated candidate before publishing its document/history. Result intents are not replicated instructions to move peers' focus.

## Captured targets

Use the capture endpoints and retain their returned canonical objects unchanged. Unknown nested fields reject; optional nil fields are omitted in canonical Codable targets. A host must also recheck its own invocation generation, active document and composition/held-peer state before submission. The engine validates document/epoch, causal observation, liveness, ordering and policy again.

| Capture endpoint | Input | Returned target |
| --- | --- | --- |
| modernCaptureTextRange | field, start, end (scalar-safe UTF-16 adapter offsets) | ModernTextRange with anchored endpoints and observed causal frontier; direction retained |
| modernCaptureBoundary | collection, optional after NodeID | ModernBlockBoundary with documentID, epoch, collection, captured after placement and observed frontier |
| modernCaptureNodes | nodes in logical document order | ModernNodeSelection with documentID, epoch, ordered origins and observed frontier |

Whole-node selection rejects duplicates, ancestor/descendant overlap, document metadata and non-block collection owners. Movement supports compatible root/existing column-child collections; no general document-block indentation is exposed. Captured boundaries keep their original collection placement if their anchor later moves or is deleted; a deleted collection owner rejects. A stale selected origin never resolves through a reused display label.

## Advertised commands

| Command | Target | Arguments | Result |
| --- | --- | --- | --- |
| replaceText / replaceTitle | ModernTextRange | text, optional typingGroup | Caret after accepted insertion; captured atoms only; plain title and literal fields retain their policy |
| format | ModernTextRange | markType, optional mark (null removes) | Anchored text range with original direction |
| setAppearance | Explicit document NodeID | field, value | Shared independent preset register |
| insertBlock | ModernBlockBoundary | block | First editable descendant field caret, or whole-node selection for a non-text block |
| move | ModernMoveTarget: selection, boundary, optional caret | Empty object | Ordered whole-node selection; an optional caret inside the selected subtree follows its origin |
| delete | ModernDeleteTarget: optional nodes selection, ranges array | Empty object | Boundary caret/fallback; selected subtrees and captured text atoms form one author transaction |
| undo / redo | Omitted or null | Empty object | Actual author history transition; peer history retained |

Multi-node movement preserves capture order, origins, descendants and metadata. Captured text deletion preserves later peer atoms; mixed ranges inside selected subtrees do not create redundant atom deletions. Deliberate commands create one Undo step. No-op placement/caret-only deletion adds no transaction. Structural conflicts that cannot form a valid accepted union remain separately recoverable; repair cannot disable a peer's history.

New rich block marks use the same validation as text insertion; opaque consumer metadata remains opaque. Column containers cannot be individually created/moved/deleted through generic commands. Nested layouts reject, including indirect nesting through toggles. Whole-layout deletion deletes the observed subtree; removeColumns will be a separate flattening operation and is still unfinished. Column creation, synchronized split/resize, removal/late-child routing and creation Undo routing must be implemented before ST-122 closes.

## Local result intents

focusIntent is a ModernFocusIntent enum: text(WritingPosition), nodes(ModernNodeSelection) or insertion(ModernBlockBoundary). selectionIntent is text(WritingTextRange), nodes(ModernNodeSelection) or null. Standard Swift enum Codable discriminants are used, matching the existing origin/operation wire conventions.

The earlier focus and selection fields remain compatibility aliases: focus contains a WritingPosition only for text focus, while selection contains the text range or whole-node selection. For insertion focus both aliases are null. Hosts should consume the canonical intents so empty/non-text targets do not become fake paragraphs or title edits.

Deletion first preserves a surviving partial-text caret. Whole-node fallback searches following surviving text, then preceding text at its end. If the body is empty it returns a root insertion boundary with no persisted placeholder. A remaining read-only body falls back to the editable title. Hosts apply the local result only while their invocation/focus ownership remains current; peer receives publish no focus intent.

```swift
let boundary = try session.captureBoundary()
let result = try session.insertBlock(Block.paragraph(id: freshID, text: ""), at: boundary)
// Apply result.focus/result.selection only to the still-current local invocation.
```

The currently advertised subset has shared-core and compiled native ABI checks, including an independently authored nested-move fixture. Versioned clipboard, split/merge/conversion/list structure, semantic block defaults, compound columns, async completion, archive-based migration, typed host facades and the complete native/Android/WASM acceptance matrix remain required work. See [implementation evidence](modern-editor-foundation.md); no full host/scenario row is promoted by these command subset checks.
