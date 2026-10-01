# Identity-preserving paragraph commands: protocol v3

ST-97 requires Enter/Backspace commands that retain original text atoms. Current
protocol v2 has field-scoped atom IDs, field-scoped formatting/deletion, and
positions containing an address plus a field-local anchor. It cannot transfer a
suffix between fields with existing mutations. A new collaboration version is
required; document schema versions remain independent.

The experimental v3 core and JSON bridge use this contract. Creation is explicit;
legacy session defaults and replay remain unchanged. Shared command tests establish
core semantics. Native input, packaged JNI and actual three-browser WASM acceptance
require their own exact-source evidence before consumer adoption.

## Why existing mutations are insufficient

Run `python3 scripts/verify-writing-counterexamples.py <editor-bridge>` against
the existing v2 engine. `--expect-correct` intentionally fails when these proposed
copy/delete shortcuts violate the desired writing behavior. Replicas converge in
all three witnesses, demonstrating that equality alone does not prove preservation.

| Operation and concurrent author action | Desired content | Copy/delete result |
| --- | --- | --- |
| Split `ab\|cd`; peer inserts X between c and d | `ab`, `cXd` | `abX`, `cd` |
| Split `ab\|cd`; peer makes c bold | `ab`, bold c followed by d | `ab`, unformatted `cd` |
| Merge `ab` and `cd`; peer appends X to the right paragraph | `abcdX` | `abcd`; X is hidden with its original node |

Each shortcut also records at least two authored edits. One undo therefore reverses
only part of the logical action. A copied suffix has fresh atoms, so replaying the
original field's marks cannot format the copy. Deleting the source node is not a
transfer and can hide newly received text. These outcomes are not bugs in the
existing advertised v2 primitives; they prohibit using those primitives as a split
or merge implementation.

## Stable identity and placement

An atom's immutable key is `(origin field, ElementID)`. The origin field contains
its stable `NodeID` and text field name, rather than its current display block/path.
Baseline ID zero is reused in different fields today; the origin is essential to
avoid collisions when two paragraphs join. Existing marks and atomic references
stay on their original atoms.

Separate immutable atom creation from current text placement. Each placement has
its own stable ID, destination field, and ordering anchor. A transfer places
observed atoms without creating replacement text or deleting their birth records.
Author undo disables only that author's placement transaction. Full replay resolves
competing placements with the established total order, independent of delivery.

For new insertions, retain both the ordering anchor and the field-affinity anchor:

- Inserting immediately before atom c follows c's effective field if c moves.
- Inserting immediately after atom b follows b's effective field if b moves.
- At a split boundary b\|c, these two affinities therefore remain distinguishable.
- An empty-field position has an explicit stable field and edge affinity. It cannot
  invent a nearest atom or depend on whether another replica has received a split.
- A deleted/tombstoned atom retains its routing identity and placement. Deleting
  text must not detach another author's insertion anchored to it.

Current field placement must not overwrite immutable insertion ancestry. Otherwise
undoing a split would strand an insertion created against the moved suffix.
Position resolution follows the effective field of the composite atom key and
returns that field plus a UTF-16 offset. A field-scoped offset alone is insufficient.
Cycle handling must use a deterministic fallback or retain a canonical rejected
proposal; it cannot silently discard atoms or choose arrival-order placements.

## Commands and undo

One edit contains selection deletion, optional insertion, node creation/consumption
and all text transfers for the logical command. It creates one undo-stack entry.
The result includes a stable selection whose atoms can follow later remote edits.

Paragraph split creates an empty compatible sibling, then transfers the observed
suffix to its content field. It does not copy its inline JSON. The destination node
keeps a stable creation identity. New remote text anchored to suffix atoms follows
them through split undo/redo. If the new paragraph was empty and an independent
remote author writes to its unanchored field, undo retains that paragraph as a
container for the remote text rather than hiding the author’s content.

Compatible boundary merge joins the two fields and consumes the right paragraph
through a reversible join relation, rather than ordinary node deletion. The join
retains both original field origins and redirects insertions at an empty source
edge while active. Undo removes that relation and restores the earlier projection;
remote atoms anchored to either origin remain visible on their original side.
Incompatible block kinds, descendants and opaque host fields cannot be silently
removed to make a merge succeed. Unsupported cases fail atomically or retain the
source as a required container with an observable outcome.

Selection replacement and Shift-Enter use the same global identities and transaction
boundary. A soft line break inserts a newline text atom. Split boundaries use
UTF-16 offsets, reject scalar splits, and reject partial atomic-reference edits.
Marked text remains marked; an atomic reference transfers as one atom. Native
adapters commit composition before invoking a command and apply the returned stable
selection without stealing focus on remote delivery.

## Version and migration boundaries

Keep v1/v2 decoding, replay, default selection and fixtures unchanged. A v3 batch,
snapshot and receipt advertise v3 explicitly. V3-only operations are rejected by
older sessions. Relays and hosts must select the same contract before accepting
writes; upgrading a UI bundle does not upgrade a room silently.

An explicit reviewed cutover archives the original accepted snapshot, pending
proposal and unacknowledged input; pauses old writers; keeps the original document ID and selects a separate collaboration epoch;
and preserves materialized block IDs, marks, references, nesting and unknown fields.
Migration of existing collaborative identity/history requires a deterministic origin
mapping, including inserted nodes and disabled author transactions. Merely rebuilding
from the visible document resets atom identities and cannot preserve pending edits
or author undo. That simpler route is allowed only as an explicit archived epoch
cutover with old writers reconciled, never as a transparent migration.

A new capability attached to v2 would still change mutation decoding and anchor
semantics. Explicit v3 is preferable because incompatible peers can fail before
acceptance instead of silently interpreting field-local IDs differently.

## Verification required before delivery

Verify exact documents, atom-origin sets and mark/reference payloads independently
of replica equality. Cover concurrent insertion on both sides of each boundary,
formatting/deletion of a transferred span, simultaneous splits at different/same
positions, concurrent merge/split and reversed merges, and author undo/redo while
remote edits continue. Include empty fields, Unicode, atomic references, duplicate
and reordered batches, accepted/pending save/reopen and failed-command preservation.

Run the same finite writing corpus through Swift, packaged Kotlin/JNI and actual
Chromium/WebKit/Firefox WASM. Typed Swift/Kotlin/TypeScript commands and returned
stable selections must agree. Actual IME, keyboard, selection and accessibility
acceptance remains native adapter work after shared semantics are verified.

## Public API

Swift uses `WritingSession`, Kotlin uses `WritingSession`, and TypeScript uses
`SwiftWritingSession`. These explicit facades call the shared engine. The JSON
bridge accepts `create` with `collaborationVersion: 3`, `documentID`, `actorID`,
`epoch` and `blocks`; omitting the epoch fails. Legacy `create` stays v1 by default.

| Command | Inputs | Result |
| --- | --- | --- |
| replaceText | address, UTF-16 start/end, text, optional marks | snapshot and WritingPosition |
| softBreak | address, start/end | snapshot and WritingPosition |
| splitParagraph | address, start/end, newBlockID | snapshot and WritingPosition |
| mergeParagraphs | adjacent left/right NodeID | snapshot and WritingPosition |
| position | address, offset, affinity | document/epoch-bound WritingPosition |
| resolvePosition | WritingPosition | effective address and UTF-16 offset |
| format, undo, redo, receive | typed command payload | accepted snapshot |
| save, changes, syncState | optional epoch-bound receipt | explicit v3 history or receipt |
| mergeRecovery, restoreRecovery | separately stored proposal | explicit pending state or accepted snapshot |
| repairWritingUndo | accepted ChangeID of this author | repaired union with remote content retained |

Selections can display inside a reference label at Unicode-scalar boundaries;
editing still rejects partial references and split surrogate pairs. Adapters hold
remote changes while composition owns its buffer, capture stable selections before
receive, commit input, clear composition state, then release delivery. Deferred
packets remain outside accepted saves and receipts; export them separately. A drain
retains packets queued by callbacks and failed protocol packets within its bounds.

A split records a boundary as well as its observed suffix transfer. Simultaneous
cuts partition overlapping observed suffix atoms at the greatest original boundary;
ChangeID breaks ties. Created siblings follow boundary order and retain observed successor constraints;
concurrent ties use ascending ChangeID. A later Enter at the same original source
end inserts before its already observed next paragraph. Different cuts at 1 and 3 in `abcd` yield `a`, `bc`, `d`, independent of
actor ordering. Two cuts at 2 retain two breaks: `ab`, an empty paragraph, `cd`.
Undo removes only the selected author's cut. A merge routes its source through the
effective field of its boundary anchor, so a concurrent split of the left paragraph
at `a|b` yields `a`, `bcd`, retaining the source's concurrent content.

A merge requires compatible adjacent paragraphs and refuses opaque source metadata
at authoring time. Metadata received concurrently keeps its source paragraph visible
while text follows the join. Ordinary structural deletion and legacy text commands
are unsupported in the initial v3 facade; the bridge rejects them atomically.

`WritingCutoverArchive` retains the accepted legacy snapshot, pending recovery,
unacknowledged batches and reconciled legacy snapshot. Snapshot bytes are base64
JSON on the wire. `ProtocolMigration.cutoverToV3` requires explicit acknowledgments
that old writers stopped, the archive was durably persisted, and local undo resets.
Every archived change must occur unchanged in the valid reconciled legacy history.
The new session keeps the document ID, starts the selected epoch and fresh undo
history, and rejects old versions and mismatched epochs. This does not migrate
legacy atom identities or provide legacy undo continuity.

Accepted histories are limited to 100,000 changes and a 64 MB encoded history;
materialized documents retain the shared 32 MB bound. Queued remote input is bounded
to 64 packets and 64 MB, including packets being drained. Capacity failures leave
accepted state unchanged; hosts retain/export the incoming input for retry. Pending
recovery is exported separately from accepted save and receipt state.

A pending union can be repaired by explicitly disabling an accepted local-author
transaction with `repairUndo`. It replays the complete proposal, retains remote
changes and all birth identities, and updates receipts only after successful
admission. Unauthorized or unsuccessful repairs leave accepted history and pending
proposal intact. Ordinary edits and undo remain blocked while recovery is pending.

Reordered undo/redo packets reconcile local availability against the winning
greatest-ID toggle for each target. A delayed undo cannot move an active redo
transaction into the redo stack. The same bookkeeping correction applies to legacy
v1/v2 sessions without changing their decoders, materialized documents or receipts.

V3 element indices use the portable nonnegative 32-bit range (0 through
2,147,483,647), while Lamport change counters remain safe 53-bit unsigned values.
This keeps native and wasm32 admission consistent. The internal virtual field
head uses index -1 and is never admitted as a real atom.
