# Implemented modern command API

ST-122's protocol-7 session uses immutable format-1 ModernDocument snapshots. Create with createModern and collaborationVersion 7; legacy create/restore do not promote an old session. The shared C ABI routes the new JSON endpoints. Typed Kotlin/TypeScript wrappers and executed Android/WASM parity remain unfinished.

A modernCommand request has documentID, epoch, command, target and arguments. Results carry status (applied/noop/unavailable/recoveryRequired), the materialized snapshot, actual admitted author transaction, and local focus/selection intent. Unsupported commands and host/composition policy restrictions return unchanged unavailable results. Malformed schemas and wrong scope return the existing structured error boundary. Checked column commands return unchanged unavailable results for invalid target/argument values; other invalid/stale targets retain the structured error boundary. Pending retained recovery disables further conflicting author edits. A result is planned against the validated candidate before publishing its document/history. Result intents are not replicated instructions to move peers' focus.

## Captured targets

Use the capture endpoints and retain their returned canonical objects unchanged. Unknown nested fields reject; optional nil fields are omitted in canonical Codable targets. A host must also recheck its own invocation generation, active document and composition/held-peer state before submission. The engine validates document/epoch, causal observation, liveness, ordering and policy again.

| Capture endpoint | Input | Returned target |
| --- | --- | --- |
| modernCaptureTextRange | field, start, end (scalar-safe UTF-16 adapter offsets) | ModernTextRange with anchored endpoints and observed causal frontier; direction retained |
| modernCaptureBoundary | collection, optional after NodeID | ModernBlockBoundary with documentID, epoch, collection, captured after placement and observed frontier |
| modernCaptureNodes | nodes in logical document order | ModernNodeSelection with documentID, epoch, ordered origins and observed frontier |

Whole-node selection rejects duplicates, ancestor/descendant overlap, document metadata and non-block collection owners. Movement supports compatible root/existing column-child collections; no general document-block indentation is exposed. Captured boundaries keep their original collection placement if their anchor later moves or is deleted; a deleted collection owner rejects. A stale selected origin never resolves through a reused display label.

A captured nonempty field-end caret anchors after its observed last atom. A later peer suffix therefore leaves that caret before the suffix, including through conversion and reopen. Explicit nil-anchor positions retain their field-boundary meaning.

## Advertised commands

| Command | Target | Arguments | Result |
| --- | --- | --- | --- |
| replaceText / replaceTitle | ModernTextRange | text, optional typingGroup | Caret after accepted insertion; captured atoms only; plain title and literal fields retain their policy |
| format | ModernTextRange | markType, optional mark (null removes) | Anchored text range with original direction |
| softBreak | ModernTextRange | Empty object | Replace captured atoms with a newline in one author step; preserve later peer text and return the insertion caret |
| convertBlock | Collapsed ModernTextRange in a body field | type, optional level/style/variant appropriate to that type | Inline/code/list shape or containing-list style conversion; retain atom origins, opaque metadata and the captured caret; reject lossy conversion |
| splitBlock | ModernTextRange in inline block content or a list item | newBlockID (fresh scoped label) | Fresh paragraph/item tail with retained suffix atoms; delete captured selected atoms and preserve source metadata; a sole empty root list item exits to its owner paragraph |
| mergeBlocks | ModernNodeSelection containing exactly two adjacent paragraph origins | Empty object | Retained field join, preserving peer text; return the original boundary caret |
| setAppearance | Explicit document NodeID | field, value | Shared independent preset register |
| insertBlock | ModernBlockBoundary | block | First editable descendant field caret, or whole-node selection for a non-text block |
| move | ModernMoveTarget: selection, boundary, optional caret | Empty object | Ordered whole-node selection; an optional caret inside the selected subtree follows its origin |
| delete | ModernDeleteTarget: optional nodes selection, ranges array | Empty object | Boundary caret/fallback; selected subtrees and captured text atoms form one author transaction |
| createColumns | ModernCreateColumnsTarget: exactly one selection or boundary, optional caret | layout with two empty columns and splitBasisPoints 5000 | New layout node selection; optional selected-subtree caret follows its origin |
| removeColumns | ModernColumnTarget: layout origin, optional descendant caret | Empty object | Flattened child selection with retained caret, or an insertion boundary for an empty layout |
| resizeColumns | ModernColumnTarget: layout origin, optional descendant caret | splitBasisPoints (integer 1000–9000) | Layout selection; unchanged split adds no transaction |
| undo / redo | Omitted or null | Empty object | Actual author history transition; peer history retained |

Multi-node movement preserves capture order, origins, descendants and metadata. Captured text deletion preserves later peer atoms; mixed ranges inside selected subtrees do not create redundant atom deletions. Deliberate commands create one Undo step. No-op placement/caret-only deletion adds no transaction. Structural conflicts that cannot form a valid accepted union remain separately recoverable; repair cannot disable a peer's history.

convertBlock defaults heading level to 1, callout variant to info and list style to unordered. Levels are 1–3, variants are info/warning/error/success and styles are unordered/ordered/todo. A list-item caret targets its containing list's style while keeping that item caret. Conversion does not overwrite a conflicting opaque field to install an attribute. Code conversion requires plain text without rich marks, references or opaque inline properties. Inline/code conversion and single-item list collapse retain immutable field births and aliases; creating a list introduces one retained item. List collapse preserves checked/opaque item fields and children only when the root has no conflicting values; multi-item collapse rejects. Retained field handles and captured carets resolve to their current destination through Undo/Redo/reopen. New text uses that current field birth, and formatting validates the current causal field even when its atoms were born in code. Invalid or lossy metadata/arguments return unchanged unavailable results. A noncollapsed or title target rejects. softBreak has its own host command policy and rejects title targets; literal body fields retain plain text and atomic labels remain indivisible for editing.

splitBlock retains observed prefix and suffix ownership in the existing ordered-cut projection. Concurrent cuts partition suffix atoms in text order, even when author ordering differs. Nested checklist splits retain original children/metadata and reset the new item's checked state. A stale captured caret can follow a prior observed peer split before a new cut. Explicit cut proofs are checked against the original capture and author cohorts even when inactive; arbitrary transfers are not admitted. A sole empty root list item exits to a paragraph at the original owner, retaining metadata, child origins and peer text through Undo. Nested and multi-item empty Enter/exit plus later commands on retired list roles remain pending and return unchanged unavailable results. Undoing a list conversion projects a peer-created sibling item as a paragraph instead of dropping its text. The command does not turn title, code, toggle summary or table cells into paragraphs; hosts use their documented Enter/soft-break behavior for those fields.

mergeBlocks requires current and captured compatible adjacency. It retains the destination paragraph's metadata and rejects source metadata/collections that would be lost, including list/toggle/table structure. Original source atoms and field heads follow the joined field. Captured edits re-resolve their actual field, and new tail edits retain original anchor origins. A split tail's empty head can resolve through its exact birth boundary after author Undo, including chained retired splits; explicit unrelated deletion still rejects. Both commands form one author step and keep local focus out of peer packets.

New rich block marks use the same validation as text insertion; opaque consumer metadata remains opaque. Column containers cannot be individually created/moved/deleted through generic commands. Nested layouts reject, including indirect nesting through toggles. Whole-layout deletion deletes the observed subtree; removeColumns instead flattens first-column then second-column children without copying content. Generic insertion/movement remains root or existing column children; captureBoundary also supports a typed block-child collection for explicit column creation outside any layout.

createColumns accepts current contiguous sibling origins or a captured insertion boundary. Its caller supplies fresh layout/column labels, two empty children arrays and splitBasisPoints 5000; consumer metadata remains opaque. Selected blocks retain their origins in the first column and the second stays empty. Empty insertion creates no paragraph. Creation, removal and the final shared resize each form one author Undo step; resize preview/cancel remains personal host work. Optional carets must belong to the affected subtree.

Removal retains column owners as offline routing anchors. Late inserts and text still reach the flattened document, while explicit peer moves outside those owners retain precedence. Concurrent removals select one route and render each origin once. Creation Undo restores original selected placements, then routes active peer children after the restored selection and before following siblings. Inactive derived placements remain anchors, so later root insertions following a flattened child stay outside a restored layout. Unsatisfiable label/identity unions retain recovery rather than silently discarding content.

The protocol-7 columnRoute placement namespace includes the layout, originating route slot and child origin; legacy protocols reject it without advancing receipts. Downstream exhaustive Swift NodePlacementID switches must handle the new case. Modern edited text omits empty marks when the birth field did not explicitly use that representation; untouched run JSON and explicit birth empty marks remain preserved.

## Local result intents

focusIntent is a ModernFocusIntent enum: text(WritingPosition), nodes(ModernNodeSelection) or insertion(ModernBlockBoundary). selectionIntent is text(WritingTextRange), nodes(ModernNodeSelection) or null. Standard Swift enum Codable discriminants are used, matching the existing origin/operation wire conventions.

The earlier focus and selection fields remain compatibility aliases: focus contains a WritingPosition only for text focus, while selection contains the text range or whole-node selection. For insertion focus both aliases are null. Hosts should consume the canonical intents so empty/non-text targets do not become fake paragraphs or title edits.

Deletion first preserves a surviving partial-text caret. Whole-node fallback searches following surviving text, then preceding text at its end. If the body is empty it returns a root insertion boundary with no persisted placeholder. A remaining read-only body falls back to the editable title. Hosts apply the local result only while their invocation/focus ownership remains current; peer receives publish no focus intent.

```swift
let boundary = try session.captureBoundary()
let result = try session.insertBlock(Block.paragraph(id: freshID, text: ""), at: boundary)
// Apply result.focus/result.selection only to the still-current local invocation.
```

The sixteen advertised commands have shared-core and compiled native ABI checks, including independently authored nested-move/writing fixtures and literal split/merge, code/list conversion and sole empty-item Enter expectations. Versioned clipboard, remaining Enter/list-role transitions, list structure, semantic block defaults, async completion, archive-based migration, typed host facades and the complete native/Android/WASM acceptance matrix remain required work. See [implementation evidence](modern-editor-foundation.md); no full host/scenario row is promoted by these command subset checks.
