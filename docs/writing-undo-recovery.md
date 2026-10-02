# Protocol-4 author undo recovery

A valid author Undo or Redo that would violate the final document schema is kept
as a separate `WritingRecovery`, exactly as a rejected received union is kept.
Accepted document, save, author history and receipts remain unchanged. Ordinary
authoring and history commands wait for an explicit permitted repair. Export the
proposal separately from `save()` and restore it with `restoreRecovery`; retain any
additional unacknowledged input separately on capacity failure.

`repairRedo(target)` explicitly reactivates this author's accepted transaction,
which can cancel a rejected Undo. It does not delete the failed toggle or peer
history: the ordinary later author toggle wins during replay. Existing
`repairUndo(target)` can disable the author's accepted transaction. Neither can
toggle a different author's transaction or bypass composition/remote holds.

`repairText(node:field:text:)` supports a single existing live text field of the
rejected protocol-4 union. It makes a minimal Unicode-scalar diff, retaining
untouched atoms, marks, references and metadata, and rejects partial atomic
reference edits. The old and new text are bounded to 100,000 UTF-16 units.
For example, Undo of an inserted math block retained for a peer's metadata edit
can leave its required expression empty. An explicit replacement expression
completes that Undo while retaining the original identity and remote metadata.
The repair is one ordinary author edit; undoing it can require recovery again.

Repair planning uses a private projected structure and atom view. It never exposes
an invalid accepted document and does not bypass protocol, role ownership, atom or
rich-code constraints. Final admission validates the entire union and capacity
before publishing accepted state. Repairs that cannot make the whole union valid
leave both accepted state and the pending proposal intact. This narrow API does
not provide arbitrary multi-action schema/move repairs or automatic cutover.

Swift, Kotlin and TypeScript expose typed repair methods. The bridge uses existing
ordinary writing changes; no new wire operation or protocol version is introduced.
Protocol-3 author Undo/Redo behavior remains unchanged. Prior engine/runtime and
host evidence retains its original source identity. This candidate requires new
matched Swift/JNI/WASM tests; native reference-host recovery controls, persistence,
actual input/accessibility, resource-threshold matrix and release limits remain
separate acceptance work. No issue completion is claimed by this source patch.
