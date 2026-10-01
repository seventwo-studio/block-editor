# Protocol 4 block commands

The writing facade exposes `convertBlock`, `markdownShortcut`, and
`enterListItem` in Swift, Kotlin, and TypeScript. They produce one author edit
and an immutable caret. Adapters must commit composition before calling them.
Local `allowedBlockTypes` restricts newly authored types; it is not persisted
and must be reapplied after restore. It does not reject retained remote content.

This increment supports lossless conversions among paragraph, heading, quote,
and callout, and list style changes. Those conversions keep the root `NodeID`
and public block ID. Marks, references, unknown fields, and child collections
remain intact. Markdown `# `, `## `, `### ` and `> ` consume the actual text
prefix in that same transaction; reference labels do not count as typed syntax.

List Enter splits the current item and continues a todo item unchecked. Empty
nested items outdent one level with the same item identity. An empty final root
item exits into a paragraph when earlier items remain. Its origin is joined to
the new paragraph so concurrent input follows it and author undo restores the
original list item. Unknown metadata and existing children remain preserved.

The explicit v4 schema commands below add paragraph-to-list/checklist/code
conversion and sole-empty-list exit. A non-final empty root-item exit remains
unsupported and leaves accepted state untouched.

A concurrent split or merge into a converted content field remains valid.
Converting the source of a concurrent paragraph merge needs explicit
reconciliation: both accepted documents remain untouched and the entire union
is retained as schema recovery. `repairUndo` can disable either author's own
conflicting command without dropping the other author's text or history.

## Wire compatibility

All newly introduced block conversion, Markdown shortcuts and list authoring
commands require an explicit protocol 4 epoch. Protocol 3 rejects these authoring
calls and incoming `convertBlock`/`schemaConvert` operations, including restore
from a spoofed version-3 batch, before accepted state changes. The previously
delivered version-3 writing/selection behavior and original fixtures are retained.
Existing v1/v2 replay remains unchanged. No mixed-peer capability is implied.

The shared `blockCommands.json` fixture is registered for native Swift,
browser-WASM and Android JNI. Registering a fixture is not proof that every
runtime executed it; acceptance must record the artifact and runtime actually
used.

## Explicit v4 schema conversion (implementation under verification)

Swift `WritingSession(..., protocolVersion: 4)`, TypeScript `createWritingV4`
and Kotlin `createV4` create a separate schema-conversion epoch. Its batches and
receipts carry version 4. V3 sessions reject these batches before accepted state
changes. This does not migrate a live v3 history: stop old writers and preserve
accepted snapshots, recovery proposals and unacknowledged changes before an
independently qualified new-epoch cutover. No implicit mixed-peer compatibility.

The v4 engine retains immutable field birth payloads and encodings, independently
of live node type. It validates old atom origins against those births and routes
retired field heads into the live field. Empty heads are retained as well as
Unicode text, marks and references. A paragraph-to-list conversion keeps the
root NodeID and public ID and introduces a separate first-item identity. Todo
sets the first item unchecked. Code conversion preserves the same root identity
and requires plain text with compatible payloads; rich input is rejected before
mutation, and a reordered rich remote union is retained as schema recovery.

A single item can collapse back into its original list root as a paragraph;
compatible item attributes are preserved when they do not conflict with root
metadata. Enter on a sole empty list item uses this conversion and keeps the list
root's identity. Paragraph/list/checklist/code Markdown shortcuts consume syntax
in one author transaction. Existing host restrictions and composition guards
apply to the new commands.

When a peer creates another item after a paragraph-to-list conversion, undoing
the conversion projects that peer item beside the restored paragraph with its
original NodeID and public ID. Its content, checked state, unknown properties
and child arrays remain preserved; children become opaque paragraph extensions.
Unsupported fallback identity/metadata collisions are rejected before mutation.
Real platform command/input acceptance and matching JNI/WASM execution remain
required. Non-final empty root-item exit and multi-item collapse are still
unsupported and leave accepted state untouched.

Competing conversions to separate list wrappers keep the full union as schema
recovery; disabling either author's conflicting wrapper allows the other to
remain. Conversions that claim one retained item origin for different roots also
require recovery, with deterministic conflict detection before head routing.
This overlapping-owner case does not claim automatic author-undo repair. Unknown
host fields that collide with newly required `style`, `items` or `code` fields
are rejected atomically rather than overwritten.

Moving an existing baseline item into the converted wrapper is currently an open
undo gap: its original placement cannot also act as the projected paragraph's
placement, so undo rejects without modifying the accepted save. Structural Enter
and move after peer paragraph projection also need a retained projected-placement
contract; only preserved text/metadata and the covered undo/redo paths are claimed
here. Reserved `level` and `variant` metadata collisions are rejected for the
same-content family too; normal changes to an existing heading/callout attribute
remain supported. These qualifications keep ST-98 open.
