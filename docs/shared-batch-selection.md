# Shared batch selection commands

Writing v3 exposes the same selection, copy, delete, move and duplicate commands in Swift, Kotlin and TypeScript. Platform adapters pass shared positions and node identities; they do not replace document arrays.

`selection(from:to:)` captures forward or backward ranges in visible preorder. Partial endpoint text and fully intervening subtrees are distinct. A collection ancestor on the boundary retains its identity and unselected descendants. `selectedText` anchors ranges to observed atoms, so retained selections follow a peer's split, including a full-field range, a trailing range and an empty end caret.

`copy` returns current rich node values and selected text atoms. `delete` removes observed atoms and descendants in one local-author transaction and returns collapsed stable positions. Whole-node `move` keeps identities; `duplicate` creates fresh structural identities, preserves marks/references/unknown consumer metadata and avoids retained-label collisions. Move and duplicate reject partial text selections. Unsupported destinations, overlapping ranges, cycles and commands during composition fail before mutation. Host adapters must commit composition before invoking structural commands.

Swift tests cover root and nested ranges, partial rich boundaries, remote-preserving undo and reopen, nested movement, duplicate references/metadata, retained split positions and label reuse. The shared writing fixture has 322 requests, including 48 field-end counterexample requests. Typed Kotlin instrumentation has four tests; actual WASM facade coverage has two tests in each browser engine.

Local native execution verifies 3,023 responses across bridge, structure, recovery, documents and writing fixtures. Independent review reproduced and resolved three regressions: retained selections rejected after a remote split, duplicate-label collisions after epoch reset, and field-end selections losing the moved suffix. Current delivered-head CI must execute Swift, packaged JNI on API 26 and current architectures, and actual WASM in Chromium/WebKit/Firefox before cross-runtime acceptance. Platform input acceptance remains separate.
