# @seventwo-studio/block-editor

Framework-neutral block editor core for structured documents.

This package owns the portable pieces of the editor:

- Zod schemas and TypeScript types for block documents.
- Block factories, transforms, markdown parsing, and markdown serialization.
- Slash command metadata without React or icon dependencies.
- A deterministic CRDT operation layer for insert, update, move, delete, merge, encode, and decode flows.
- A basic React editor surface with CSS variable theming.

## React UI

```tsx
import { makeBlock } from "@seventwo-studio/block-editor"
import { BlockEditor } from "@seventwo-studio/block-editor/react"
import "@seventwo-studio/block-editor/react.css"
import { useState } from "react"

export function Editor() {
  const [blocks, setBlocks] = useState([makeBlock("paragraph")])

  return (
    <BlockEditor
      value={blocks}
      onChange={setBlocks}
      onOperation={(operation) => console.log(operation)}
      placeholder="Type / for commands"
    />
  )
}
```

The UI is intentionally plain browser React: no app-specific component library,
no Ambiently dependency, and customization through CSS variables such as
`--s2be-bg`, `--s2be-text`, `--s2be-accent`, `--s2be-radius`, and `--s2be-font`.

## Public Entrypoints

- `@seventwo-studio/block-editor`
- `@seventwo-studio/block-editor/model`
- `@seventwo-studio/block-editor/react`
- `@seventwo-studio/block-editor/react.css`
- `@seventwo-studio/block-editor/schema`
- `@seventwo-studio/block-editor/crdt`

## Demo

The repository includes a Vite demo for GitHub Pages. It shows the React editor,
theme customization, emitted UI operations, CRDT operation state, and markdown
serialization side by side.

```sh
bun run demo:dev
bun run demo:build
```

## Verification

```sh
bun install
bun run typecheck
bun run demo:typecheck
bun run test
bun run build
bun run demo:build
```

## Visual-only editing

Pass `allowMarkdown={false}` to `BlockEditor` to hide the raw Markdown editor.
Block editing, slash commands and Markdown typing shortcuts remain available.
The default is `true`, preserving existing integrations.

```tsx
<BlockEditor value={blocks} onChange={setBlocks} allowMarkdown={false} />
```

If the prop changes to `false` while raw editing is open, the current draft is
converted to blocks and emitted through `onChange` and the existing `markdown`
operation, just like pressing **Done**. The draft is not silently discarded.
This prop controls editor UI; consumers still validate document content and
permissions at their own application boundary.

## Updating inline text

`setBlockText` uses `updateInlineText` for inline content. Plain-text edits retain
formatting and structured references outside the changed range rather than
flattening the whole field. New text inherits the adjacent edited text span's
marks. A reference whose label is partially edited becomes ordinary text, so it
cannot silently retain an incorrect entity identity. Unicode comparisons use
code points to avoid splitting surrogate pairs.

`updateInlineText` treats the difference between two plain-text values as one
contiguous replacement. For editors with explicit selections and richer editing
operations, use the structured `InlineNode` model directly. This helper does not
sanitize links, implement visual formatting controls, or resolve concurrent edits.
