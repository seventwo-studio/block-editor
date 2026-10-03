# Modern editing decisions

Confirmed 2 October 2026 for [Block Editor — Modern Editing Experience](https://linear.app/seventwo/project/block-editor-modern-editing-experience-7132996e2816).

The [Notion decision record](https://app.notion.com/p/3e9bb04960098144848ed3667bfa01ea) owns product intent. This document records the technical implications of those decisions; the [Linear delivery plan](https://linear.app/seventwo/document/delivery-plan-milestones-dependencies-and-acceptance-01951ee8b64f) and existing issues own delivery and acceptance. These are requirements, not implementation or acceptance evidence.

## Delivery and supported surfaces

All native platforms form the first complete delivery in the reference apps, before consumer integration. Full authoring covers macOS, iPhone/iPad, Android and visionOS. watchOS/tvOS retain reading, text, checklist and reorder editing while preserving richer content. React/WASM parity follows native acceptance in the same project, including Chromium, WebKit and Firefox.

The existing block catalog remains in scope, with file attachments and generic URL previews added. Outline, focus mode, semantic text/background colors and appearance controls remain required outcomes. Their navigation and inspectors are optional in the UI. Hosts continue to own uploads, asset and link resolution, storage, transport, authentication, authorization and publication.

## Shared document and interaction

Use shared document hierarchy and contextual tools with platform-native fonts, controls, input, focus and accessibility conventions. New commands must work in local and collaborative modes, including concurrent editing, offline rejoin, selection preservation and author-specific undo.

The engine owns a plain-text title with concurrent text editing and the same undo history as body edits. Enter in the title moves to the body. The document stores and synchronizes typography and width presets: native sans/serif/monospace, small/default/large text and readable/wide width. Semantic text/background colors use a small palette and are document content. Outline visibility and focus mode remain personal viewing state.

Internal document suggestions use `[[` and an accessible Link action. `@` remains available for mention suggestions when the host supplies them. Suggestions and destinations remain host-resolved.

The shared document representation, persistence and platform interfaces must accommodate the title and appearance settings. Swift, Kotlin/JNI and React/WASM must expose equivalent behavior. Exact schema shapes, protocol versions and visual token values are not selected by this record.

## Migration boundary

For the modern document format, preserve materialized content and identities, archive original documents and sessions, and start a fresh collaboration baseline with empty undo history. Prior operations and undo history remain in the archived originals; they are not translated into the new session's history.

The migration and recovery contracts must distinguish archive preservation from new-session history and prevent incompatible session state from being mixed. The exact migration algorithm and protocol cutover remain implementation-contract work. Existing descriptions of prior formats and implemented migrations remain historical evidence.

## Acceptance and performance

Actual interaction and relevant assistive-technology evidence are required on every supported native platform, including both iPhone and iPad. Missing hardware evidence is a blocker; build or simulator evidence alone does not establish that acceptance.

For 1,000 mixed blocks, local edit-to-display must meet p95 ≤50 ms and menu response p95 ≤100 ms on representative supported hardware. Record fixture, hardware and measurement method with results. Larger valid documents must remain safe and preserve content.

These targets concern the modern editing surface. They do not settle broader engine, growing-history, startup, memory or artifact-size budgets. The existing separate acceptance work remains in place.

## Delivery references

- Platform and migration boundaries: ST-117; scope and delivery lanes: ST-118.
- Visual and command contracts: ST-119 and ST-120; title: ST-123.
- Internal links: ST-132; media/files/previews: ST-133.
- Shared appearance: ST-136; personal outline/focus state: ST-138.
- Accessibility and device evidence: ST-139 and ST-143.
- Preservation/migration: ST-141; responsiveness targets: ST-142.
- Project acceptance, including subsequent browser parity: ST-145.

