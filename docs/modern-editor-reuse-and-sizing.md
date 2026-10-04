# Modern editor reuse, scope and provisional complexity

Reviewed planning map, 5 October 2026. Owner: [ST-118](https://linear.app/seventwo/issue/ST-118). Apply the [approved delivery plan](https://linear.app/seventwo/document/delivery-plan-milestones-dependencies-and-acceptance-01951ee8b64f), [fixed technical decisions](modern-editing-decisions.md), [ST-116 assessment](modern-editor-assessment.md) and [ST-117 compatibility contract](modern-editor-compatibility.md).

Reuse the shared engine and working adapters. Build only the remaining agreed surface, shared metadata/columns and acceptance gaps. No blanket rewrite, duplicate prototype completion or added feature is justified. The existing catalog plus attachments/generic URL previews, exactly two resizable columns, title/appearance/colors, outline/focus and all agreed delivery acceptance remain committed. AI, branded integration catalogs, elaborate decoration, spreadsheet expansion, source-editing mode, general block indentation, additional/nested columns, new platforms, consumer implementation, production services and unrelated refactors remain excluded.

## Evidence and ownership

Engine source is pinned to `da0505771898308da100432638b11b463b4fa952`; documentation/availability review uses `6f4e2de56730cdb7f2be1fa1856e967f892198c9`, with unchanged production editor sources. Assessment `ASSESS-01–25` and compatibility `COMPAT-01–10` are planning reproductions; ST-140 supplies the reviewed implementation fixtures. Reuse keeps exact source, binary, runtime and original acceptance qualifications.

* Core: `Sources/BlockEditorCore/{WritingSession,Structure,WritingProjection,WritingClipboard,WritingMigration,Document,Validation,Bridge}.swift` supplies shared semantics and explicit admission/history boundaries.
* Apple: `Sources/BlockEditorApple` supplies native input, focus/rendered origins, collections and current controls. Compose/JNI: `android/editor/src/main/java/studio/seventwo/blockeditor` supplies parallel native writing and collection integration.
* Browser: `src/swift.ts` and `src/swift-react.tsx` supply the opt-in shared facade; current production TypeScript React is separate. Loader evidence does not establish final modern parity.
* Retained [assessment media and checks](evidence/modern-editor-assessment-2026-10-04/README.md) cover the qualified current baseline. Foundation ST-48/ST-102/ST-103/ST-105 evidence remains reusable only within original coverage. Modern device/assistive/performance passes are still required.
* Every existing issue and the deferred checks are assigned to Luca Silverentand in Linear. Owning layers below identify technical responsibility; they do not invent staff or available capacity.

## Remaining work

Points use Linear's **Estimate Issue Complexity** skill: complexity, uncertainty, scope, regression risk and validation burden, never duration. The lowest defensible value is provisional and may change when contract/fixture review changes the remaining work. A 16-point row is one coherent outcome at the scale's upper bound; decompose if implementation discovery shows it cannot be reviewed coherently. Do not erase acceptance during decomposition.

| Issue | Points | Owning layer | Reuse / qualified baseline | Remaining work | Complexity reason / reproduction |
| --- | --- | --- | --- | --- | --- |
| ST-119 | 4 | Design | 32 annotated references and native system fonts/controls | Native typography, light/dark tokens, contextual hierarchy and columns/stacking | Bounded multi-part visual contract; reuse native fonts/controls; ASSESS-01/16 |
| ST-120 | 8 | Shared contract | ST-117 contract, WritingPosition/Selection, stable NodeID and author history | Versioned metadata/column commands, positions/composition, concurrency and Undo | Cross-layer identity/state/recovery edge cases; ST-117; ASSESS-02/04/11/20 |
| ST-121 | 8 | Prototype | Current isolated reference-host surfaces and assessment documents | Reviewed writing/title/columns/touch/reduced-host transitions | Multiple input/focus states and recorded review; ASSESS-01/17/24/25 |
| ST-140 | 8 | Fixtures | Retained mixed/nested/media fixtures and compatibility corpus | Independent expected document/selection/focus/history corpus | Reusable concurrent/preservation scenarios and qualified evidence matrix; ASSESS-01–25; COMPAT-01–10 |
| ST-122 | 16 | Swift/JNI/ABI | WritingSession, Structure, projection, history, validation and shared bridge | Add shared title/appearance/colors, true two-column collections/split and modern migration | Engine/replay/Undo/schema and three facades; preserve existing semantics; ASSESS-02/11/16/20 |
| ST-123 | 16 | Native adapters | Existing Apple scroll canvas, Compose collections and native inputs | Continuous canvas/title and column creation/resize/stacking/reduced-host preservation | Mixed-content layout/input/identity across native families; ASSESS-01/02/11/24 |
| ST-124 | 16 | Native input | Apple/Compose retained caret, composition holds and deferred peer inputs | IME/caret/selection with title/columns/contextual surface | Real input, composition and deferred-peer regression burden; ASSESS-03/04 |
| ST-125 | 16 | Shared/adapters | Author Undo/Redo, scoped clipboard and accepted/pending save/recovery | Undo/Redo/clipboard/persistence with new metadata/layout and commands | Concurrent peer preservation, paste and history/reopen states; ASSESS-20 |
| ST-126 | 8 | Native selection | WritingSelection and core batch/move/delete/copy operations | Block/range affordances and shared action bar | Nested/column selection identities, async content and focus states; ASSESS-04/05 |
| ST-127 | 8 | Native catalog | Native insertion commands and existing React search/restrictions | Searchable caret menu, complete allowed catalog and column entry | Input/cancel/viewport/focus paths; reuse insertion semantics; ASSESS-06/11 |
| ST-128 | 8 | Shared/adapters | Core conversion, duplicate/move/delete and rendered origin leases | Modern convert/duplicate/delete/move/block-link controls | Stable identity, author Undo and explicit unsupported conversions; ASSESS-08 |
| ST-129 | 8 | Native formatting | Existing rich marks, native format and Markdown commands | Contextual marks/mixed state and equivalent shortcuts | Selection, composition and history grouping; ASSESS-07 |
| ST-130 | 16 | Shared/native structure | Stable list/item/toggle collections, checklist and native controls | List/toggle writing/containment/disclosure inside columns | Several structures with peer/Undo/focus interactions; ASSESS-09/11 |
| ST-131 | 16 | Native reorder | Origin-preserving structural moves and native Move up/down | Pointer/keyboard/touch targets, ranges and within/between-column moves | Preview/cancel, concurrent origins and focus preservation; ASSESS-10/11 |
| ST-132 | 8 | Native/host boundary | Validated link marks, atomic references and host callbacks | Caret [[ suggestions, Link action, cancellation/fallback | Async host resolution and selection/Undo/accessibility states; ASSESS-12 |
| ST-133 | 16 | Shared/adapters/host | Image fields, host callbacks and preserved embed metadata | Attachments/generic previews and recoverable media workflows | New shared content plus upload/cancel/failure/reopen; host-owned assets; ASSESS-13 |
| ST-134 | 4 | Native code | Literal code fields and native code editing | Language/copy controls and narrow/dark literal code | Bounded existing path with whitespace/paste/copy/history edge cases; ASSESS-14 |
| ST-135 | 8 | Shared/native tables | Stable rows/cells, collection commands and existing native grid | Header/structural controls, cell navigation and responsive table | Existing rows/cells reused; keyboard/touch/a11y/history states; ASSESS-15 |
| ST-136 | 8 | Shared/native appearance | Native system appearance, callout colors and current rich marks | Shared presets/colors, mixed/reset controls and focus | Style synchronization and light/dark contrast; local CSS insufficient; ASSESS-16 |
| ST-137 | 16 | Native input/layout | UIKit/Compose input/focus/pending-draft machinery | Keyboard/panels, range actions, resize and reduced/spatial hosts | Several native input/focus/layout states and real interactions; ASSESS-17/24/25 |
| ST-138 | 8 | Native personal state | Existing heading data and host navigation boundaries | Outline/focus/navigation through columns | New bounded surface with heading updates, caret and accessibility; ASSESS-18 |
| ST-139 | 16 | Native accessibility | Current labels/traits/native controls; no complete modern assistive pass | Actual seven-family assistive/keyboard/contrast/large-text/resize checks and fixes | Physical access, integrated semantics and focused regression evidence; ASSESS-19 |
| ST-141 | 16 | Compatibility | Lossless Swift fields, explicit cutover/archive and recovery scaffolding | Modern migration/archives/fresh history, lossless round trips and recovery | Cross-runtime version/identity and failure/restart preservation risk; ASSESS-20; COMPAT-01–10 |
| ST-142 | 16 | Native performance | Retained measurement workloads and harness; no modern physical pass | 1,000-block edit/menu targets on representative physical hosts | Render/input measurements and targeted regression fixes; reuse harness; ASSESS-21 |
| ST-143 | 16 | Native acceptance | Qualified baseline host media and retained foundation/relay results | Complete agreed modern functional/rendered/device/relay checkpoint | Seven-family matrix consumes accessibility/compatibility/performance evidence; ASSESS-01–25 |
| ST-47 | 16 | React/WASM integration | Opt-in Swift React, loader/session cleanup and anchored selection | Final modern UI through shared commands after native acceptance | Lifecycle/composition/metadata/column/collaboration adapter integration; ASSESS-22 |
| ST-104 | 16 | Browser acceptance | Existing three-engine WASM/relay/restart and browser test harness | All three engines' full input/rendered/a11y/compatibility/performance/relay outcomes | Pinned real artifacts, process recovery and retained input/skip qualifications; ASSESS-20/22 |
| ST-34 | 8 | Private publication | Candidate manifests and completed exact exposure recovery | Final matching Swift/AAR/TS/WASM and verified privacy/read access | Multiple routes and privacy boundaries; exact remote approvals remain; ASSESS-23 |
| ST-106 | 8 | Private install | Merged clean-host contract and isolated package export checks | Fresh pinned installs, edits/save/reopen and incompatible-pair rejection | Cross-package dependencies/artifact pairing and denied/positive access; ASSESS-23 |
| ST-144 | 4 | Staged delivery | Host-owned storage/assets/auth and retained recovery contracts | Exercised integration/recovery and named rollout checks/identities | Bounded synthesis; scheduling in ST-177; ST-117; accepted evidence |
| ST-145 | 4 | Product acceptance | Existing delivery checkpoints and fixed scope | Explicit owner acceptance and optional follow-up handoff | Bounded full-evidence review, not automatic on merge; Complete accepted matrix |
| ST-170 | 4 | Validation access | Current Mac/live iPhone metadata and qualified paired iPad record | Confirm physical families/runtime/input/assistive access | Bounded multi-part access inventory; metadata remains partial; Qualified physical inventory |
| ST-118 | 4 | Delivery planning | Completed dated assessment and compatibility contract | Full reuse/gap/owner map and provisional complexity fields | Bounded evidence synthesis and native-field verification; dates in ST-177; ST-116/ST-117 |
| ST-177 | 0 classification; native unset | Scheduling coordination | Existing issue ownership/dependency order and this map | Confirm capacity and set milestone dates | Coordination without an implementation deliverable; team estimate settings reject 0 |

ST-115 reference preservation, ST-116 assessment, ST-117 compatibility planning and ST-168 exposure recovery are complete. They incur no new implementation effort in this map; their historical estimates remain untouched. Source APIs or passing baseline tests are not modern acceptance. New commands still need local/concurrent/offline/author Undo and preservation checks under the reviewed contracts.

## Bounded column impact

* ST-117/ST-120 define metadata, stable layout/container identities, single persisted shared split, migration and shared commands; ST-122 implements that agreed engine/facade contract.
* ST-119/ST-121 settle the visual and interaction target. ST-123 builds side-by-side/stacked native layout and accessible resize; ST-131 handles content moves; ST-137 handles keyboard/panel/touch and reduced/spatial presentation.
* ST-124/ST-125/ST-126 retain composition/caret/selection/history across column changes. ST-130 preserves list/toggle containment; ST-138 follows logical heading order.
* ST-140/ST-141/ST-142/ST-139/ST-143 cover independent expected results, preservation, performance, accessibility and complete native acceptance. ST-47/ST-104 implement/accept subsequent browser parity; ST-106 checks published metadata preservation.

No separate column outcome or duplicate implementation issue is created. Additional/nested layouts and arbitrary general block indentation remain excluded; existing nested documents and literal code remain preserved.

## Delivery sequence and deferred checks

Completed assessment/compatibility → reuse/scope/complexity → ST-119 visual and ST-120 interaction contracts → ST-121 reviewed prototype and ST-140 accepted fixtures → ST-122 shared foundation → native writing/contextual/adaptive work → ST-139/ST-141/ST-142 and ST-143 full native acceptance → ST-47 browser integration → ST-104 full three-engine acceptance → ST-34 private publication/ST-106 clean install → ST-144 staged delivery/ST-145 explicit product acceptance.

Existing native prerequisites remain authoritative. Independent feature lanes can proceed once their own prerequisites pass. Reuse does not remove prototype/fixture, physical, browser, privacy or final owner acceptance gates.

[ST-170](https://linear.app/seventwo/issue/ST-170/confirm-physical-device-access-for-native-editor-acceptance) retains physical device/runtime/input/assistive availability checks and natively blocks ST-139/ST-142/ST-143. The current Mac and live iPhone metadata are known; paired iPad access and Android/Vision Pro/Watch/TV access remain unresolved. Planning and implementation can proceed while that check stays open, as Luca authorized on 5 October.

[ST-177](https://linear.app/seventwo/issue/ST-177/confirm-delivery-capacity-and-set-milestone-dates) retains capacity/calendar confirmation and natively gates ST-144 staged delivery. No available hours, staffing or calendar dates are established by the evidence. Milestone dates therefore remain unset until that check confirms inputs. Points must never be converted into promised dates. This preserves the scheduling deliverable while allowing scope/design/implementation to progress, under Luca's instruction to defer checks rather than halt delivery.

Both checks decompose existing obligations; they add no capability. The physical matrix and responsiveness targets remain unchanged. Private publication/grants/credential actions still require their exact existing approvals; no publication or consumer change occurs in planning.

