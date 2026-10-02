# Shared collection authoring

Protocol 4 writing sessions expose `collectionNodes(in:)` and
`insertCollectionNodes(_:into:after:)` in Swift, with the same `collectionNodes`
and `insertCollectionNodes` commands in Kotlin and TypeScript.

Obtain the owner through `node(at:)`, then address its schema collection:
`rows` on a table, `cells` on a row, `children` on a toggle or list item, and
`items` on a list. Root `blocks` accepts new blocks. Returned NodeIDs identify
origins across moves; consumer IDs remain scoped to their containing array.

Insertion validates every supplied value and supported descendant before
admission, preserves marks, references and unknown metadata, and creates one
author undo transaction for the complete batch. A missing or incorrect owner,
invalid schema, duplicate visible sibling label, disabled authored type, active
composition or resource overflow leaves the accepted state untouched. Existing
content may contain host-disabled types; creating a new nested row, cell or item
requires the corresponding `table` or `list` authoring capability. Restrictions
are local authoring policy and do not replace service authorization.

Use shared `move`/`moveSelection` to reorder a row, cell, item or toggle child;
use `delete`/`deleteSelection` to remove observed nodes. Each preserves origin
identities and uses a shared structural transaction. Applications must commit
composition before invoking a structural command. They should not replace
collection arrays to implement these actions.

The table schema permits rows with different numbers of cells. These commands
do not invent rectangular-grid padding or rewrite column widths. Unknown
collection-like metadata stays opaque. Unsupported destination fields fail
explicitly rather than converting their owner. Save and reopen retain all
accepted changes and author undo history; rejected remote unions retain a
separate recovery proposal.

The independent Swift cases and hand-authored shared collection transcript
cover concurrent rows, scoped cell IDs, remote edits, reordered rows, creation
of absent child collections, remote descendants across undo/redo, checklist
metadata, references and offline reopen. Cross-runtime execution and platform
interaction must be verified against the delivered source before acceptance.
