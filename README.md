# @seventwo-studio/block-editor

Framework-neutral block editor core for structured documents.

This package owns the portable pieces of the editor:

- Zod schemas and TypeScript types for block documents.
- Block factories, transforms, markdown parsing, and markdown serialization.
- Slash command metadata without React or icon dependencies.
- A deterministic CRDT operation layer for insert, update, move, delete, merge, encode, and decode flows.

The Ambiently web app still owns the current React UI shell. That shell consumes this package and maps command ids to local icons and menu components.

## Public Entrypoints

- `@seventwo-studio/block-editor`
- `@seventwo-studio/block-editor/model`
- `@seventwo-studio/block-editor/schema`
- `@seventwo-studio/block-editor/crdt`

## Verification

```sh
bun install
bun run typecheck
bun run test
bun run build
```
