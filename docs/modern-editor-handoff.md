# Modern editor integration candidate

This is the P-ST-85 implementation candidate being prepared in cumulative PR #70.
The proposed private package version is **0.2.0**. A version number in source is
not proof of publication or consumer access. ST-34 and ST-144 remain open until
private artifacts, approved Foliostrate access and the actual handoff are verified.

## Contract

Use document format `seventwo.block-editor.document`, formatVersion **1** and
collaboration protocol **7** explicitly. Keep opaque fields and admitted content
when a host cannot author or render it. Use the checked modern session, never the
legacy JavaScript operation model, for a modern editor. Legacy exports remain.

The application owns authorization, uploads, reference resolution, autosave,
publication, navigation and rollout. The editor has no production collaboration
service, implicit provider calls, credential management or application routing.
Deactivate outgoing host adapters before mounting another document. Captured
targets name retained identities; do not regenerate them from display indices.

## React and WASM

The package exposes `swift/modern`, `swift/modern/react`, `swift/modern/host`,
`swift/modern.css` and `swift/modern.wasm`. Import `SwiftEditorRuntime` from `swift`,
supply the matching WASM bytes, then call `runtime.createModern` or
`runtime.restoreModern`. Render `SwiftModernBlockEditor` with that session and an
application-owned `ModernBrowserHost`. `SwiftModernEditorSurface` provides
loading, retry and incompatibility presentation for initial documents.

Run `bun run build:wasm` and `bun run demo:dev`, then open the reference
integration at `/block-editor/modern.html` with the existing
demo server. `demo/modern-main.tsx` demonstrates local Help
writing, paired reopen, explicit Save and internal Help suggestions. No backend
is required. Supply real navigation, asset insertion and access-filtered
suggestions from Foliostrate. `[[` invokes internal suggestions; `@` is reserved
for optional application mentions.

Supply read-only state and allowed author commands separately from peer
admission. Host restrictions never remove existing blocks or marks. Clipboard
and provider failures retain their original destination. An unsupported rich
paste requires an explicit plain-text choice.

## Apple and Android

Apple: create `ModernEditorModel(session:)` and render `ModernBlockEditorView`.
Use `ModernHostStore` and one `ModernPersistenceController` per local pair. Pass
that controller to `ModernProviderController`; the application explicitly starts
providers and retries retained results. Reopening restores inert provider records.
Use `ModernReducedEditorView` on watchOS/tvOS while retaining the same full document.
`ModernEditorDemoView(storageURL:)` is the runnable Apple reference. Launch
EditorLab with `EDITOR_LAB_MODERN=1` to select it; its legacy routes remain available.
Restore `pendingInputs` and `retainedClipboard` into the model before saving again.

Android: create `ModernSession`, `ModernAndroidHost` and
`rememberModernBlockEditorState`, then render `ModernBlockEditor`. Store pairs in
an existing app-private directory through `ModernHostStore`. Keep JNI calls on
the creating UI thread; the storage adapter moves only immutable bytes to IO.
The typed Kotlin table/media/catalog APIs match Swift and TypeScript.
Launch the demo with the Boolean intent extra `modern=true` to use its paired
local Help reference. It keeps providers and failed input inert after reopen.

## Migration and recovery

Quiesce legacy writers first. Preserve the exact original document/session,
rejected/unacknowledged packets and local drafts in `ModernCutoverArchive`.
Prepare the modern candidate, persist and read back that archive, then create
the fresh protocol-7 session with explicit history-reset acknowledgment.
Save accepted history, selection/history, provider records, recovery, held
packets and drafts together before atomically replacing the active pointer.

`ModernActivationStore` retains immutable archives, candidate checkpoints and
the previous activation revision. Explicit rollback requires quiesced writers.
Apple, Android and browser activation stage and read back immutable originals
and the paired candidate before switching one checked pointer. Keep later saves
on the active epoch’s live paired checkpoint; immutable activation data remains
available for rollback. A failed preactivation
write leaves the current pointer unchanged. A post-rename durability error is
uncertain publication; read actual storage before retrying. Never replace an
unreadable or incompatible pair with an empty document.

## Candidate preparation and approval

Build JavaScript declarations and actual WASM from one clean, committed source.
Run `node scripts/modern-package-provenance.mjs` before the isolated package check.
The resulting package includes versioned source/tree and artifact SHA-256
identities in `modern-provenance.json`. The matching Swift source and Kotlin/JNI
delivery must reference that same reviewed commit and record binary hashes in
their runtime provenance. Pin exact artifact versions and hashes in Foliostrate.

Publish only after the existing concrete remote-action approvals, reviews and
required CI. Never overwrite an existing version. Preserve private visibility,
the $0 Packages cap, Stop usage and current credential boundaries. Verify the
approved consumer install/read path after publication and record the actual
handoff in ST-144. A merge alone does not satisfy these external outcomes.

The separate finishing project retains physical-device, comprehensive
accessibility/performance and final product acceptance. Those checks are not
silently reported as passed by an implementation build.
