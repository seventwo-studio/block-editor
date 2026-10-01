# Android authoring and host assets

The Kotlin library targets Android API 26 and packages the Swift engine through
JNI. Compose adapters use the same engine commands for local and collaborative
sessions. The existing `BlockEditor(session, modifier, asset)` and read-only/error
callback overloads remain available.

Existing paragraphs, headings, quotes, callouts, code, math, toggle summaries and
children, table cells, and recursive list/checklist text are editable in place.
Nested fields use root IDs plus scoped child IDs rather than array positions.
Checkbox changes use the shared metadata command. Tables scroll horizontally and
cells identify their row and column for accessibility. Read-only recovery keeps
nested content selectable and disables authored changes.

Selecting inline text exposes Bold, Italic, Strike, Code and an inline link editor.
New links accept only http, https and mailto schemes; link application uses stable
selection anchors while remote edits arrive. Image descriptions and existing
captions are editable without replacing image metadata. Ctrl/Cmd-B and
Ctrl/Cmd-I apply the same commands. Existing marks render without changing text or
UTF-16 offsets. Block menus provide reorder and deletion; structural-epoch nested
menus provide scoped movement and list indent/outdent. Engine rejection leaves the
source document intact and exposes an error. Each successful action uses one shared
command. Undo/redo and structural actions wait while an IME composing range is active.

Stable interaction tags identify `editor-text:<rootID>:<path>`,
`editor-actions:<rootID>:<nodepath>`, `editor-check:<rootID>:<itempath>` and
`editor-format:<rootID>:<textpath>:<marktype>`. Paths join field names and scoped IDs
with `/`; they are diagnostic identifiers, not a serialized engine identity.
Accessibility labels identify editable headings, toggle summaries, list/checklist
items and table coordinates. Errors are announced through a polite live region.

## Host-owned images

An additional overload accepts `onAssetRequest(NodeAddress, JSONObject)` and an
optional `onAssetInsertRequest`. The editor supplies a copy of the existing block
and its scoped address. Hosts obtain permissions, resolve/upload assets and mutate
metadata through engine commands. Resolve the origin identity before an async
picker so a remote move cannot redirect its result. The editor never downloads
images or grants permissions itself.

The reference Android demo uses `OpenDocument(image/*)` and takes persistable read
permission for the selected content URI. Insertion emits one image command;
replacement updates the captured origin's source. The preview opens only content
URIs with a retained grant and samples large images. Missing permissions, unsupported
sources and decoding failures remain visible. The demo performs no HTTP downloads
or arbitrary file resolution. Grants and local URIs belong to that device; other
replicas retain the image metadata and need their own asset integration. Interrupted
picker callbacks fail rather than inserting into an unrelated request. Accepted
session persistence continues through the host's existing draft flow.

## Remaining acceptance

ST-46 remains open. AAR compilation is separate from actual IME, permission,
selection, keyboard/touch and TalkBack acceptance owned by ST-103. Paragraph
split/merge, conversion/typing shortcuts, multi-block operations, structured paste
and collection creation/restructuring still require ST-97 through ST-101. These
adapters do not copy arrays or emulate those shared semantics. Private package
publication and clean consumer installation require ST-34/ST-106 evidence.
