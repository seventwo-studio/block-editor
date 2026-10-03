# Notion-like editing behavior

The shared editor should feel like a continuous document made of directly editable
blocks. Notion is the interaction reference. Platform-native controls should make
the same operations natural with a pointer, touch, keyboard, or assistive technology.
This contract applies to the Swift-backed Apple, Android and React/WASM editors in
both standalone and collaborative modes.

Reference behavior: [Notion writing and editing](https://www.notion.com/help/writing-and-editing-basics)
and [keyboard shortcuts](https://www.notion.com/help/keyboard-shortcuts).
The requirements below are this editor's acceptance contract, not a claim that
every Notion feature is implemented or part of the shared engine.

## Everyday writing

The [modern editing decisions confirmed on 2 October 2026](modern-editing-decisions.md)
define the title, appearance, internal-link trigger, delivery and acceptance scope
that accompanies this behavior contract.

- Clicking or tapping text edits it in place. An empty document immediately offers
  a focused paragraph. Block controls and formatting tools appear in context;
  ordinary writing does not require a separate form or persistent buttons on every line.
- `/` opens a searchable block menu at the caret. Arrow keys navigate, Enter chooses,
  and Escape dismisses. Dismissing preserves the user's text. Host-disabled block
  types are omitted. Touch and accessibility offer an equivalent insert action.
- Enter splits a paragraph at the selection, retaining marks and references on
  each side and focusing the new block. Shift-Enter adds a soft line break.
  Enter during IME composition commits composition rather than splitting a block.
- Lists continue with the next item; Enter on an empty item exits or outdents one
  level. Backspace at a block boundary merges compatible text or changes the block
  type as appropriate. It must not silently delete images, children, or references.
- Arrow navigation crosses block boundaries without losing the caret's intended
  position. Home/End, selection extension, and deletion use platform conventions.
- Markdown typing shortcuts create headings, lists, checklists, quotes and code
  blocks. The transformation is undoable and does not trigger during composition.
- Inline bold, italic, strikethrough, code and links work through selection tools
  and platform keyboard shortcuts. Formatting a selection preserves focus; typing
  continues with the intended marks. Link editing validates allowed URL schemes.

## Blocks and structure

- A block handle offers move, duplicate, delete and supported type conversion.
  Dragging shows an insertion target before committing. Keyboard and accessibility
  actions provide the same operations without dragging.
- Tab/Shift-Tab and drag operations indent and outdent supported structures.
  Nested lists and toggles remain editable. Cross-parent movement preserves content,
  identity, references and descendants; ambiguous moves cannot silently lose data.
- Text selection can span multiple blocks, including partial first/last blocks.
  Whole-block selection supports batch move, duplicate, copy and delete.
- Headings, lists, checklists, quotes, callouts, code, math, images, tables and toggles
  render as their actual content. A preservation placeholder is not rich authoring
  acceptance. Hosts own image resolution/upload and permitted embed behavior.
- Type conversion preserves the existing block ID where possible and retains
  compatible formatting. Unsupported conversions must leave the source untouched.

## Paste, undo and collaboration

- Plain text, multiline text, Markdown and sanitized rich HTML paste at the current
  selection predictably. Copy/paste within the editor preserves supported block
  structure, marks and references while assigning new identities to duplicated blocks.
- Pasted content cannot cause automatic external asset downloads or bypass the
  host's permitted-block or asset policy.
- Each logical command (split, merge, conversion, indentation, drag or paste) is
  one author undo action. Undo/redo restores content, structure and a useful caret
  position without reverting unrelated remote edits.
- Local and collaborative modes use the same commands. Remote edits map the local
  selection, do not steal focus, and wait for active composition. Offline rejoin
  preserves concurrent content and deterministic ordering.

## Delivery and verification

Implement shared command semantics and selection results in Swift, then expose
them through Kotlin and TypeScript. Platform adapters own input events, menus,
focus, drag presentation and accessibility. Structural commands depend on ST-42's
nested merging rules; they must not replace nested JSON wholesale to imitate a UI.

Verify each workflow with Unicode, marked text, atomic references, formatted text,
undo/redo, save/reopen, and a concurrent remote edit where relevant. Run actual
interaction tests on native platforms and Chromium, WebKit and Firefox. watchOS
and tvOS retain the agreed smaller reading/text/checklist/reordering surface while
preserving richer content.

Current gaps include paragraph split/merge semantics, the native slash menu,
contextual controls, cross-block selection, drag/nesting, full rich block authoring,
and structured paste parity. Existing collaboration and recovery tests do not
close these gaps. Track platform completion in ST-45, ST-46 and ST-47, with shared
structure in ST-42 and reference acceptance in ST-48.

The Apple surface now renders editable table cells, toggle summaries/children and
recursive lists using stable nested text addresses. Headings and table headers have
native text styling; block actions use a menu and formatting controls appear for a
selection. Text fields size to their content. This improves editing existing rich
documents; creating or restructuring nested content still needs the shared commands
above. watchOS/tvOS retain read-only table cells and their smaller editing scope.
