# Apple authoring controls

`BlockEditorView` and `EditorModel` are reusable library interfaces. Hosts retain
the session, own storage and transport, provide the asset renderer, and set
`EditorSession.allowedBlockTypes` before model creation. For live policy changes,
set `EditorModel.allowedBlockTypes`; it refreshes native menus and updates session
validation together. Asset source strings never initiate a fetch.
Disabling the editor preserves native text selection while disabling mutations.

The native insert menu creates paragraphs, headings, quotes, callouts, lists,
checklists, code, toggles, tables and dividers through shared `insert` commands.
It omits types excluded by the host; the session also checks policy when the
command runs. Paragraph remains the engine's fallback type. Image and embed
creation require host-owned asset and URL workflows. Unknown and richer existing
blocks remain in the document, including on watchOS and tvOS.

Block context actions offer both ordering directions and deletion. V2 actions
capture origin identity before committing composition, follow its current parent,
and use shared node operations. Nested list items offer indentation and outdent.
Legacy V1 retains root ordering and omits nested structural actions. Selection tools offer bold, italic, strikethrough,
code and removal of an individual mark type; stable position anchors map through
queued remote changes before applying formatting. Each operation uses shared
author history. Command-B and Command-I toggle selected bold and italic through
the shared command adapter. They wait during composition and cannot edit disabled
native controls.

These controls are an incremental surface. They do not establish continuous
writing acceptance. Slash replacement/conversion, paragraph split/merge, boundary
navigation, structured paste, dragging with insertion targets, cross-block
selection, rich table/list structure commands, link editing, and actual system
input/accessibility remain tracked by ST-45 and its native prerequisites. A
cross-parent move through the full SwiftUI hierarchy still needs focus/composition
acceptance; isolated controller tests do not prove this behavior.

## Runtime acceptance

Deployment remains OS 26 for every family. Inventory on 1 October 2026 used Xcode
27.0 (27A266a). This table records availability separately from interaction results.

| Family | Minimum OS 26 | Available current runtime | New-control interaction |
| --- | --- | --- | --- |
| macOS | Runtime unavailable | macOS 27.0.1 (26A434) | Open |
| iOS | Runtime unavailable | Simulator 27.0 (24A434) | Open |
| iPadOS | Runtime unavailable | Simulator 27.0 (24A434) | Open |
| visionOS | Runtime unavailable | Runtime unavailable | Open |
| watchOS | Runtime unavailable | Simulator 27.0 (24R362) | Open |
| tvOS | Runtime unavailable | Simulator 27.0 (24J360) | Open |

Existing PR #30/#31 input, recovery and relay evidence remains recorded in Linear.
It does not establish acceptance of the new controls or real system IME and
VoiceOver. ST-102 records device/runtime, exact source, workflow and evidence for
each family; absent runtimes stay open.
