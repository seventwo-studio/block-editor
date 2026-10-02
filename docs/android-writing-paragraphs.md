# Explicit shared-writing paragraphs on Android

`WritingParagraphEditorState` owns one native input surface for one explicit v4
`WritingSession`. `WritingParagraphEditor(state)` renders root paragraphs. The
legacy `BlockEditor(EditorSession)` and its installed-keyboard tests are unchanged.

The host creates/restores the v4 session and retains the state outside conditional
view mounting. For example:

```kotlin
val state = rememberWritingParagraphEditorState(session,
    retainDrafts = { drafts -> persistDrafts(drafts) },
    reportError = { error -> showError(error) })
WritingParagraphEditor(state)
```

Use `state.readOnly` as the live authoring permission. Dispose/close the state
before closing its session. A failed `retainDrafts` callback leaves the state,
composition holds and pending drafts available through `state.pendingDrafts()`;
a host can persist the records and retry `state.close()`. Each record includes
opaque field identity, native text/selection, failure reason, accepted snapshot,
deferred packets and pending recovery. The state never owns transport or storage.
Only one native state can claim a session, so a second surface cannot clear the
first surface's active composition flag.

Native text commits use a minimal Unicode-scalar-safe replacement and UTF-16
selection offsets. Unchanged rich atoms, marks and references remain in shared
history. Atomic-reference edits and scalar-splitting selections are rejected;
the native draft remains visible and exportable. Active composition holds remote
messages. Explicit Enter, soft break, compatible previous-root-paragraph merge
and Undo/Redo revoke the current native lease, finalize its last value, commit
local atoms, drain held peers, then invoke the shared command. Failed native
commit or remote drain suppresses the structural/history command.

Hardware Enter/Shift-Enter and boundary Backspace use the shared commands. The
IME Next action and rendered buttons invoke the same command boundary. Native
plain text insertion, including text pasted by the OS, uses shared replacement;
structured paste and cross-block selection are not implemented by this surface.
Other root block kinds display a placeholder and retain their document data.

A native binding captures both opaque origin and rendered address. A remote move
revokes its callback immediately, before disposal/replacement. Pending remember
reservations keep the original controller across replacement attachment. Only
the immediately current native lease can deliver a synchronous final correction.
Returned shared positions drive destination selection/focus after its controlled
value is installed; a pending handoff blocks additional commands and callbacks
to the old source. Intentional focus departure cancels the handoff. Failed
retention leaves the host-owned state available rather than discarding a draft.

The added controller and owned Compose InputConnection tests are component
acceptance targets. Offline Kotlin compilation is not runtime acceptance.
Installed-keyboard Enter/composition, API26/current architectures, physical ARM64,
TalkBack, focus/keyboard/touch, rich controls, list and collection authoring,
structured paste, host assets and reference integration remain ST97/ST103 work.
No issue completion or full Android editor acceptance follows from this boundary.
