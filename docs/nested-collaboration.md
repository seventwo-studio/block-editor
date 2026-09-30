# Nested collaboration protocol

Protocol v2 adds structural commands for root blocks, toggle children, list items,
table rows and table cells. It is an experimental, explicit session option; existing
sessions and the production React entrypoint still use v1. The document JSON schema
does not change. This work advances ST-95 and does not complete native authoring,
browser migration, runtime CI or package acceptance.

## Identity and placement

A document label remains unique within its containing array. Different containers
may reuse the same label. `NodeID` identifies a baseline node by its complete origin
path, or an inserted node by its creation operation and relative descendant path.
Moving it does not change that identity, its document label, or its descendants.
Unknown metadata and unsupported blocks remain preserved.

`NodeAddress` locates a node in the current rendered document. Resolve it to a
`NodeID` before retaining it for an action. `address(of:)` provides the current path
after a move. Text operations and captured selections carry the origin identity,
so an offline edit at an old path still follows the correct node after merging.
Presence may carry the same address but remains ephemeral and host-controlled.

Every collection has its own ordered placement history. New placements are ordered
by Lamport counter and ASCII actor ID; old and undone placements remain anchors.
The highest active placement wins. If concurrent moves form a parent cycle, the
earliest winning move in that cycle falls back to its previous placement, repeating
until the tree is acyclic. A move that would create duplicate sibling labels also
falls back to a previous placement. Document IDs are never rewritten to resolve
these move conflicts. Missing causal owners or anchors defer a placement until
they arrive; an existing node retains its earlier placement meanwhile.

Deleting a node records the descendants the author observed. Concurrently inserted
descendants survive and retain their ancestors as containers. Undoing an insertion
also retains containers required by another active author's descendants or edits,
while hiding text atoms originally introduced by the undone insertion. Remote text
atoms remain visible. Undo/redo changes only the local author's transaction state;
it does not replay a cached copy of an old document over remote edits.

## Session APIs

```swift
let session = try EditorSession(documentID: "document-v2", actorID: "writer",
    document: document, collaborationVersion: 2)
let item = try session.node(at: NodeAddress("list", path: ["items", "item"]))
let text = try session.textAddress(of: item)
try session.indent(item)
try session.setText(at: text, to: "Text still follows the item")
try session.outdent(item)
```

`insertNode`, `moveNode`, `deleteNode` and `setNodeField` cover the four nested
collection kinds. List `indent`/`outdent` use the same move primitive. The ordinary
root `insert`/`move`/`delete` and text APIs dispatch to v2 semantics when that version
is selected. Each command is one author undo transaction. Insertion respects the
host's allowed block types throughout its descendants; permissions still belong
at the service boundary.

The TypeScript/WASM session exposes typed node identities, addresses and collection
operations. Kotlin provides `NodeIdentity`, `NodeAddress`, `NodeCollection`, and
matching session methods. Both wrappers accept an explicit collaboration version.
Adapters still own input events, menus, focus, dragging, paste and accessibility;
this API does not itself deliver their full UI.

The Apple receive holds and read-only preparation callbacks also apply to v2.
During composition, remote changes remain outside receipts and saved history until
the hold is released. An invalid queued batch does not prevent later valid batches
from applying. Low-level Apple text controls capture origin identity before a move
and render marks from the node's current location, even if its old path is reused.
AppKit and UIKit tests cover composition, remote movement, old-path replacement and
remote-preserving author undo. Full SwiftUI identity/focus reconciliation and rich
structural UI workflows remain part of native platform acceptance.

## Cutover and compatibility

v1 and v2 batches cannot be mixed. Receiving a different version fails before the
session changes. `ProtocolMigration.cutoverToV2` (also exposed by the JSON bridge,
TypeScript runtime and Kotlin companion) materializes a reviewed v1 snapshot into
a new document baseline with a different document ID. It preserves content, labels,
formatting, references, nesting and unknown fields. It starts fresh undo history;
old operations are not reinterpreted as v2 commands.

v2 receipt sets include their document ID and protocol version. Receipts from an
old or unbound epoch cause a full resend, so reused author counters after cutover
cannot accidentally acknowledge a new operation. Duplicate delivery is harmless.

The host must stop old writers, reconcile their pending edits, and archive the old
snapshot/history before cutover. Storage, transport, authentication, assets and
publication remain host-owned. A local relay can explicitly start a v2 room with
its own baseline; reopening a saved room preserves its version and rejects an
incompatible configured version. No production backend or public release is implied.

## Evidence and open acceptance

`Fixtures/structure.json` exercises the same command transcript in native Swift,
Android JNI and actual browser WASM: scoped labels, cross-parent text/selection
mapping, table-cell moves, list indentation, concurrent edits, duplicate delivery,
save/reopen, author undo/redo and explicit v1 cutover. Generated Swift histories
exercise eight seeds, three replicas, disconnected editing, partial/reordered
delivery and restart. A local HTTP relay test additionally verifies independent
Swift processes, server restart, acknowledgement and remote-preserving undo.

Swift and the API 35 arm64 JNI execution pass, as do Chromium and WebKit WASM.
Firefox currently fails before execution because its profile folder cannot be
opened. Android API 26/x86 execution and complete native/browser interaction remain
separate acceptance work.

Valid histories can exceed document/depth limits or insert the same sibling label
without a prior placement to fall back to. V2 now exposes a canonical pending union
and explicit move, wrap and text repairs. Accepted saves and receipts remain
unchanged until the whole repaired union is valid. Required-content undo failures
use the same recovery path; concurrent repairs replay as ordinary author changes.
See [merge recovery](merge-recovery.md) for typed APIs, separate proposal persistence,
relay HTTP 409 recovery and capacity exhaustion.

The recovery fixture runs through Swift, JNI and Chromium/WebKit WASM; native tests
also cover depth/root-count thresholds, required fields, atomic references and
oversized-union retention. ST-96 remains open for full host recovery integration,
expanded generated/resource coverage and the cross-runtime threshold matrix.
Large-history performance, protocol review, full structural conflict coverage and
platform acceptance remain open. Do not claim unrestricted convergence or enable
this prototype for production collaboration from the passing fixtures.
