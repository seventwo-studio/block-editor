# Modern editor cumulative implementation review

Review snapshot for P-ST-85, PR #70, proposed candidate 0.2.0. This accounts for
all 20 deliverables in the accepted batch. “Review candidate” means implementation
is ready for review; it does not claim that every platform campaign, current-head
CI or external outcome has passed. Source remains one integration branch, with
logical commits. Completed ST-115–ST-120 and ST-168 are reused.

Shared Swift owns mutations, validation, causal identities and author history.
Apple, Compose and React own interaction/presentation. Format 1, protocol 7,
legacy entrypoints, opaque metadata and admitted content remain explicit. Host
restrictions do not rewrite existing content. Two columns retain 1000–9000 split
values, default 5000; resizing previews and metric-based stacking are local.

## Issue-by-issue accounting

| Issue | Relevant code and reviewed behavior | Evidence and outstanding limitation |
| --- | --- | --- |
| ST-122 | Core `ModernSession`, `ModernCommandTargets`, `ModernTableCommands`, `ModernAsyncCommands`; Apple `ModernHostStore`/`ModernProviderController`/`ModernActivationStore`; browser `swift-modern-host`; Android `ModernHost`/`ModernActivationStore`. Captured targets, availability, checked table/media commands, paired storage, retained provider results, explicit retry and archived activation/rollback. | Table, provider/activation, host persistence, typed ABI and broad Core/Apple fixtures pass locally. Restored provider requests remain inert. Current-head runtime CI is required; restored pending requests may require explicit host restart/cancel. |
| ST-123 | `ModernBlockEditorView`, Compose `ModernBlockEditor`, React `swift-modern-react`; empty native/browser inputs. Editable title/body, empty typing, states, approved presets and exactly two responsive columns with one committed split action. | iOS title/body/reopen, browser title-to-body/code/table/columns/reopen and shared column fixtures. Hardware and final visual acceptance remain in finishing. |
| ST-124 | Apple `ModernTextInput`/`ModernInputController`, Compose `ModernInput`, React `ModernInput`; Core `ModernNavigation`. IME buffers, Unicode/atomic references, boundary navigation, directed spans, retained rejected input and original-window focus leases. | Shared/native input fixtures, iOS menu dismissal and Android Undo/native-buffer/reopen; browser DOM selection/formatting. Native cross-field spans use boundary/extension controls; a continuous OS drag across independently hosted text fields is not claimed. Dictation/autocorrect/device IME campaigns remain open. |
| ST-125 | `ModernHistorySelection`, `ModernClipboard`, `ModernCut`, `ModernPaste`; native/browser/Android clipboard and retained-draft adapters. Author history, typing grouping, directed selection restore, rich/internal/plain clipboard and explicit fallback. | Broad history/clipboard and 19 paste fixtures, typed JNI peer edits/Undo/reopen, browser formatting Undo and retained media reopen. A session export must be paired with history selection/provider/recovery/draft archives. |
| ST-126 | Captured `ModernNodeSelection`; all three contextual surfaces. Single/range selection fills, counts, cancellation and compatible move/peer/column identity preservation. | Shared selection/column/history fixtures and platform source review. Full pointer/touch range interaction campaigns are deferred; review candidate is not their acceptance. |
| ST-127 | `ModernInteractionCatalog`, `captureInsertionBoundary`, platform slash/touch pickers. One searchable vocabulary and Two columns; query cancellation, descriptions, keyboard selection and viewport fitting. | Browser slash/cancel/code/table/columns smoke and shared table-cell/list insertion/query/Undo fixtures. macOS popovers anchor to the captured field rather than exact pixel caret geometry. |
| ST-128 | `ModernBlockCommands`, `ModernDuplication`, `ModernStructureReplay`; platform contextual range conversion/duplicate/move/delete and host copy-link. Atomic lossless conversion validates all plans before one author action. | Independent range-conversion and broad structure/opaque duplication fixtures. Copy-link/navigation needs the embedding application's callback. |
| ST-129 | `ModernInlineCommands`, `ModernTypingShortcuts`, `ModernNavigation`; captured native Format panel, Compose formatting menu and browser selection-anchored panel. Current/mixed marks, lossless shared shortcuts and selection-safe commands. | Shared mark/shortcut/multi-field fixtures and browser selected-Unicode/Undo smoke. Native panel placement is field anchored on Mac and a sheet on touch; exact caret-pixel placement and platform text-service campaigns are not claimed. |
| ST-130 | `ModernListStructure`, `ModernListEnter`, `ModernSplitMerge`; platform list/checklist/toggle/quote/callout renderers and empty-container targets. Safe collapse moves focused content to its summary. | Shared hierarchy/split/list/history fixtures; source review of disclosure/checklist/empty insertion. Physical touch and assistive acceptance remain in finishing. |
| ST-131 | Captured move commands, Apple local drop delegate, Compose drag frames and browser handle-only drag. Local previews, before/after indicators, edge scrolling, cancel/no mutation, ordered ranges and keyboard/touch movement. | Shared ordered-move/cycle/column fixtures and platform implementation review. Comprehensive drag and assistive input campaigns remain open. |
| ST-132 | Shared `setLink`/reference paste, host `suggestLinks`/navigation, platform `[[` and Link panels. Captured queries, permission/unavailable states, cancellation and readable references; `@` reserved. | Shared link/reference/atomic-input fixtures and platform source review. Actual Foliostrate access-filtered resolver/navigation is a consumer responsibility. |
| ST-133 | Checked media properties/providers; platform media presentation and reference app-private asset stores. Replacement/removal/captions/aspect resize, plain-link versus preview, error/offline/read-only and durable original requests. | Provider save-failure/document-switch fixtures, asset-reference regression and browser valid image/caption/reopen in Chromium/WebKit. Reference storage is local; production uploads and authorization belong to Foliostrate. |
| ST-134 | `ModernCodeProperties`, literal platform code inputs, local copy/language controls and wrapping/scroll confinement. Paragraph/list shortcuts excluded. | Shared literal Unicode/Tab/language/Undo fixtures, iOS code persistence and browser code/language/reopen smoke. No syntax-highlighting or new language execution scope. |
| ST-135 | `ModernTableCommands`, typed Swift/TS/Kotlin table API, platform cell/row/column/header controls, navigation and table-only scroll. | Four table fixtures cover structure, headers, malformed/stale targets, Undo/reopen; browser table-cell editing and catalog insertion pass. No spreadsheet features or resize mutation. |
| ST-136 | Shared appearance/semantic commands and platform preset/palette controls. Sans/serif/mono, size/width, current/mixed/reset ink/background; local layout does not overwrite split. | Shared appearance/peer/semantic fixtures and source review. Comprehensive contrast/large-text visual acceptance remains finishing work. |
| ST-137 | Compact Insert/Format/Link/Undo/More on native, Compose and React; sheets/popovers, 44-point browser targets, native IME/safe-area/bring-into-view, local movement/resize. | Actual Android native Undo/history/reopen and iOS Format cancellation/input/reopen; browser narrow stacking/media persistence. Physical keyboard/safe-area/composition campaigns remain open. |
| ST-138 | Shared logical navigation fields and platform outline/reveal/focus state. Column headings follow document order; optional panels remain personal and host navigation is injected. | Shared logical-span/navigation fixtures and source review. Active-section polish and comprehensive long-document navigation acceptance remain review/finishing work. |
| ST-47 | Typed modern WASM/React entrypoints, loading/retry/incompatibility, host recovery/policies/callbacks, `demo/modern-main.tsx` runnable local Help example; legacy exports retained. | Actual WASM typed consumer, TypeScript/consumer/demo checks, Chromium/WebKit integrated smoke and isolated installed-package execution. Local Firefox launch failed before assertions; required remote three-engine checks remain mandatory. |
| ST-34 | Version 0.2.0 exports/declarations/WASM, clean-source/runtime/artifact provenance, isolated package installation and release preparation. Swift/Kotlin source delivery retained. | Local package install passed with matching earlier candidate receipts. Final artifact rebuild/pins, required CI/reviews, concrete private publication and approved consumer read access remain outstanding. Keep In Progress. |
| ST-144 | `docs/modern-editor-handoff.md`, runnable Apple/Android/React references, host contracts, migration/rollback/recovery and explicit Foliostrate Help API limitations. | Foliostrate's current strict legacy Help schema cannot consume richer modern envelopes. Versioned API/public-renderer adoption belongs to ST-9/ST-111; preserve full checkpoints rather than strip content. Actual pinned private handoff/access remains outstanding. Keep In Progress. |

## Verification and delivery boundaries

[Integrated evidence](evidence/modern-integrated-2026-10-06/README.md) preserves
original failed runs and corrected results with their qualifications. Required
current-head CI and available code/security reviews remain separate from local
fixtures and smoke. Missing, stale or pending feedback is not a passing review.

PR #69's fix is preserved as `8987fa6d` with stable patch ID
`dc764ec5578e2134e41a54f0aba4e0525d26d33a`. Its original evidence remains, and
#69 was closed as superseded only after preservation and push verification.
PR #70 targets main and remains the single cumulative implementation PR.

No package publication or merge is implied by this review. Preserve private
visibility, the $0 Packages cap, Stop usage, credential boundaries, required
checks/reviews and GitHub Verified protected-branch delivery. Do not overwrite
an existing version. ST-34/ST-144 stay open until their external outcomes are
delivered. Separate physical-device, accessibility/performance and final product
acceptance work remains intact.
