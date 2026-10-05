# Modern editor acceptance fixtures

Reviewed expectation contract for [ST-140](https://linear.app/seventwo/issue/ST-140), 5 October 2026. This supplies reusable inputs and independently authored expected results before ST-122 implementation. It follows the [command](../../modern-editor-command-contract.md), [compatibility](../../modern-editor-compatibility.md) and [visual](../../modern-editor-visual-contract.md) contracts. It does not implement protocol 7 or accept a host/runtime.

The [fixture catalog](fixtures.json) contains **20 representative entries** and the [scenario matrix](scenarios.json) contains **44 scenarios, 106 explicit expected checkpoints and 59 full input/expected documents**. Every scenario names an existing owning Linear issue, input fixture, initial selection/focus/history, action sequence, peer schedule, complete expected document, selection/caret, focus and author Undo/Redo group counts. All 44 runtime statuses remain `pending`.

## Reproduction and comparison

1. Select an `ACC-*` scenario and its initial fixture. Start fresh actors with the catalog's exact document identity/epoch. Bind each initial scoped content ID to its actual stable engine origin once. Reserve the stated new schema IDs as deterministic fixture allocations; do not use them as private wire encodings.
2. Establish `initialState`, execute the actions and any explicitly ordered/held/offline peer schedule. Run every stated delivery permutation and duplicate replay. For UI scenarios use actual native/browser input; model-driven commands alone do not accept focus/composition/touch behavior.
3. At each checkpoint compare the **whole named JSON document**, ignoring object-key order only. Compare scoped IDs, unknown fields, atomic references and code whitespace as supplied. Resolve selection/focus through the initially bound origins; UTF-16 offsets are scalar boundaries. A move changes an origin's materialized path, not its identity. `originBindings` specifies that distinction for list indentation.
4. Compare this author's available Undo/Redo **group counts**, not the peer's history or raw change count. Menus, previews, personal outline/focus and responsive stacking add no group. Reopen, offline rejoin and duplicate delivery must retain the same accepted content/identity/history/receipts as specified. Invalid input rejects before ACK or publication; retained recovery remains separate from accepted state.
5. Store actual results under the owning implementation/acceptance issue with exact source/artifact/runtime, inputs and original receipts/media. Keep expected documents unchanged when the implementation fails. Revise an expected result only through an explicit contract review, never by regenerating it from the failing implementation.

The expected snapshots were authored from the approved contract without executing a modern editor. They are literal files in version control, not golden output captured from an implementation. The action descriptions and host steps are a harness contract; ST-122 and adapter owners must supply the actual runners. Existing baseline tests are reuse evidence, not substitutes for these independent expected results.

Run contract integrity checks from any directory:

```sh
python3 docs/acceptance/modern-editor/verify.py --self-test
```

The checker validates scoped references, UTF-16 scalar boundaries, document/appearance/layout shapes, full snapshot paths, initial state, history counts, host scope, owners and evidence kinds. Six corrupt-input checks verify rejection of a third column, duplicate sibling identity, invalid split, escaping/missing document path, surrogate-interior caret and deleted origin. These are **fixture readiness checks**, not execution of modern commands.

To reproduce the limited existing-engine checks:

```sh
swift build --product editor-bridge
python3 docs/acceptance/modern-editor/check_legacy_inputs.py
```

Eight protocol-6 body inputs admit/save/restore exactly, including the 1,000-block long document, 16-column table, opaque legacy reserved-tag payload and valid 5,001-block legacy document. The original unsupported-inline input and an old-client protocol-7 request reject as expected. The [legacy receipt](legacy-input-checks.json) pins the input/core source hashes. This checks old representation preservation only; title/appearance/columns modern semantics are not executed.

## Coverage and evidence ownership

| Workflow | Scenarios | Primary delivery owners |
| --- | --- | --- |
| Blank input, anchored text, scalar admission, IME and focus | ACC-01–05, ACC-36, ACC-43–44 | ST-122, ST-123, ST-124, ST-125, ST-137 |
| Shared title/appearance, slash picker, formatting, conversion, duplicate/move, list/toggle | ACC-06–13, ACC-34–35, ACC-42 | ST-122, ST-127–132, ST-136 |
| Literal code, local media and delayed/failed provider | ACC-14–15 | ST-133–134 |
| Exactly two columns: creation, cross/within/outside moves, selection, offline child routing, author Undo and resize ties/cancellation | ACC-16–23, ACC-36, ACC-40–41 | ST-122–123, ST-125, ST-131 |
| Rich clipboard, nested rejection, explicit flattened fallback, trailing/empty plain lines | ACC-22, ACC-37–39 | ST-125 |
| Save/reopen, original archives, fresh epoch, unknown content, limits, transport/protocol recovery | ACC-24–27, ACC-32 | ST-141 |
| Read-only/loading/error, light/dark, RTL/large text, narrow stacking, wide tables, long outline, reduced hosts | ACC-28–31, ACC-33 | ST-137–139, ST-142–143; later ST-104 |

Columns retain exact `st140-columns` document identity, stable layout/first-column/second-column identities, the literal split (3000/5000/7000 or concurrent 6000/4000), content origins and first-then-second reading order. Snapshots explicitly cover offline `D` insertion after layout removal, peer text in `A`, author Undo restoration, Undo layout birth retaining peer `D`, and tie-breaking by counter then UTF-8 actor. Additional column slots, direct/indirect nested layouts and general block indent/outdent reject unchanged. Multiple independent non-nested layouts are represented by the root rich-copy fixture; the two-container invariant is per layout.

`columns-rich` combines marked text, nested lists/toggles, local media, literal code and a wide table without network access. Scoped `same` and `child` IDs deliberately repeat in distinct list/toggle containers. Opaque consumer IDs and reference `entityId` values are not freshened as schema IDs. The code fixture includes a tab, empty line, two trailing spaces and trailing newline. Unicode includes combining marks, astral emoji, a skin-tone/ZWJ sequence, CJK, Arabic and Hebrew. Legacy fixtures retain reserved-tag collisions and unsupported inline bytes for archive/read-only refusal.

The [host matrix](hosts.json) preserves seven native families and later React/WASM on **Chromium, WebKit and Firefox separately**. Mac/iPhone/iPad/Android/visionOS remain full authoring; watchOS/tvOS remain reading/text/checklist/reorder while preserving richer accepted documents. Their unavailable creation/conversion/resize controls are explicitly inapplicable; content preservation and permitted editing remain required. Neither simulator availability nor a reduced creation policy removes a committed host from acceptance.

Each scenario names required evidence kinds: `sharedSemantics`, `hostInteraction`, `rendering`, `assistive`, `physicalInput` and/or `physicalPerformance`. Exact modern core/bridge execution, real IME/input, original pixels, actual assistive navigation and hardware timing are different gates. An accessibility tree, computed contrast, simulator video or CI build cannot impersonate physical/assistive acceptance. No performance threshold is invented here; ST-142 retains the measurement and threshold decision.

## Review and open checks

Review corrected an initially malformed entity reference to the existing `entityId/entityType/label` representation, scoped duplicate child IDs correctly, retained stable list-item origin handles across indentation and matched scenario owners to current Linear titles. It specified the space outside a consumed slash query, exact empty/trailing paste lines, independent appearance registers, personal stacking versus shared split, and full clipboard/column routing expectations. Contract integrity passes all 44 scenarios/106 checkpoints and six corruption checks. Eight real legacy admission/save/restore checks and two expected rejections pass; production core sources remain unchanged from the assessed baseline.

ST-140's planning deliverable is ready. New runtime execution remains with ST-122 and its feature owners, preservation with ST-141, input/assistive/performance/native acceptance with ST-124/ST-137/ST-139/ST-142/ST-143 and later browser execution with ST-47/ST-104. Device access remains ST-170. ST-121's recorded prototype revisions still gate ST-122; this independent fixture contract can complete while those revisions stay open. No new planning records, consumers, credentials, package grants, publication or paid services are required.
