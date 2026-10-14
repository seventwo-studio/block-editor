# Modern surface measurements

ST-142 retains local edit-to-display p95 ≤50 ms and menu response p95 ≤100 ms
for 1,000 mixed blocks on recorded representative hardware. ST-104 applies the
same contract to browser surfaces. Engine, startup and growing-history workloads
in `editor-performance.md` measure different boundaries.

## Workload and method

`benchmarks/modern-surface-1000.json` is an independent fixed input, constructed
from the approved vocabulary and unchanged `columns-rich` acceptance fixture.
It has 860 root blocks and exactly 1,000 schema blocks including nested blocks:
20 column layouts, each with exactly two ordered containers, ten headings,
Unicode/marked/reference text, lists, toggles, code, wide tables, image metadata,
quotes, callouts, dividers and opaque fields. Rows, cells, items and column
containers are counted separately from schema blocks. Image references use the
unresolved host-owned presentation; resolved asset loading remains a separate
required workload. Existing acceptance input/expected snapshots are untouched.

The production Vite surface mounts the actual React editor and matching WASM.
Playwright drives trusted keyboard/pointer events; the timer begins at initiating
keydown or pointerdown. A result requires both accepted shared text and displayed
text, or the displayed insertion menu and search focus, through a second animation
frame. This is a conservative presented-frame proxy with at least one frame
opportunity, including keydown validation. It is separate from pixel/assistive
acceptance and system input on other devices.

Three sequential warmups are excluded before twenty raw samples per operation.
The complete document must match the independently specified appended text;
opening/dismissing menus must preserve the saved history and return focus.
Record artifact/source hashes, production bundle/compiler, browser version,
hardware, viewport, scalable metrics and uncontrolled background/cache behavior.
Run large local timing workloads sequentially. A short, interrupted or profiled
run cannot establish the complete uninstrumented baseline.

Build the production harness, then run it against matching frozen WASM:

```sh
bun x vite build --config vite.modern-performance.config.ts
MODERN_PERFORMANCE_OUTPUT=<new-directory> bun x playwright test \
  --config playwright.modern-performance.config.ts
```

`MODERN_SURFACE_DIAGNOSTIC=1` separately records shared call categories/durations,
console errors and retained input state. Instrumented measurements remain
diagnostic. Incomplete reports and original inputs/results remain available after
failures. A completed harness run alone does not pass the two performance budgets.

## Read ownership

Structural reads reuse a validated placement/order/address view only while their
value state is unchanged. Nested node, placement, deletion, touch and schema-mode
mutations detach that cache; independent value copies retain their own results.
Immutable readers sharing results use a lock. Node addresses remain lookup paths;
commands still capture opaque origins and all mutation/admission stays in Swift.

Captured cohort reads validate causal closure first. The complete admitted cohort
reuses current projection data; one bounded historical cohort supports controls
still showing a previous captured selection. Other cohorts use original replay.
Cache data is ephemeral, absent from saved sessions and never authorizes unknown
or duplicate causal IDs. Peer work, historical selections and author Undo remain
the original checked operations.

React indexes Swift-returned identities and fields within one immutable accepted
document and receipt. It rebuilds after either changes and does not derive origins
from display labels. Contextual reads and the outline traverse actual schema
collections; opaque consumer properties named `rows` or `children` retain their
data without becoming editor nodes. Reused labels after peer deletion resolve to
their new shared identities.

An additive shared batch read supplies checked node kinds, addresses and scalar
destination fields. React compares its schema traversal with these results;
legacy runtimes retain individual checked reads. Snapshot publication shares
only exactly equal JSON subtrees, preserving signed zero, raw Unicode, key order
and opaque own keys. New wrappers still publish lifecycle/history changes. An
identical-valued peer replacement changes its receipt and invalidates origins
even when its document storage is shared.

Writing atom ordering ranks exact encoded origin bytes once per sort. Raw
components prevent Swift's Unicode-normalizing string equality from merging
distinct spellings; equal encoded keys retain their original stable tie order.
Element identity still takes priority over the origin rank. Caret offsets use
the final retained order for their resolved field, including hidden atoms and
joined virtual heads. Visible offsets exclude tombstones; retained offsets keep
their UTF-16 widths so later cuts and historical anchors retain their meaning.

`node scripts/profile-modern-authoring.mjs <new-report>` diagnoses direct actual
WASM calls on the same fixed workload. It verifies two accepted appends, explicit
no-op shortcuts and mark state, and records source/patch, fixture and WASM hashes.
This excludes browser input/rendering and never accepts a surface budget.

Modern baselines may share separately checked scalar-field projections. The
eligible graph must keep placement edges and follow routes within the same
exact wire origin. Edited fields still use the original graph checks; joins,
transfers, aliases and differently spelled canonical equivalents use full
replay. Each snapshot keeps a small immutable field map without parent chains,
and unchanged birth JSON remains exact. Admission, causal closure, resource
bounds and final document validation still run. Direct retained-key membership
avoids building a whole atom set for each caret or paste check.

## Current evidence boundary

The initial production workload exceeded its four-minute limit before producing
samples. Shared read and captured-cohort optimizations plus scoped React bindings
make the surface render and pass the affected functional/preservation cases.
The subsequent full-keydown run recorded sixteen verified input/display samples
at roughly 9.4 seconds each before its deadline. It did not complete the twenty
samples or measure menus. This contradicts the 50 ms target; there is no accepted
input p95 or menu result. Profile and repair the remaining authoring/snapshot path
before repeating the same workload.

The ranked-order and field-offset candidate's direct WASM diagnostic measured
accepted appends at 2,934–2,980 ms, compared with the earlier 3,272–3,514 ms.
No-op shortcut calls measured 142–145 ms. These modest improvements leave the
author replay/projection and complete snapshot paths far above the agreed input
target even before browser rendering. They do not replace the failed production
baseline or establish a complete p95.

The subsequent field-projection and direct-membership candidate measures direct
appends at 1,104–1,131 ms, no-op shortcuts at 25–29 ms and mark state near 1 ms.
That is still above the 50 ms input target before rendering. Its serial probe
records process resident memory as diagnostic data; two appends are not resource
or lifecycle acceptance. Keep the production workload and broader campaigns.

The frozen three-engine production follow-up recorded twenty verified input
samples in each engine. Observed sample p95 is 3,943.8 ms (Chromium), 6,591 ms
(WebKit) and 6,528 ms (Firefox). Each combined run hit its unchanged deadline
during menus, leaving fourteen/seven/zero menu samples and terminal failure.
These input observations contradict the 50 ms target; there is no complete menu
or combined campaign acceptance. Retain raw failures and investigate full
snapshot publication and binding work before another measurement run.

The subsequent exact-snapshot/batch-binding candidate records input sample p95
3,122.5 ms Chromium, 5,047 ms WebKit and 5,279 ms Firefox. Chromium completes
twenty menu samples at p95 1,616.4 ms; WebKit and Firefox reach the same deadline
after fifteen and six menu samples. All targets remain failed. Static JS/WASM
stayed frozen; later engines report an untracked evidence directory created
during the serial run, so preserve that source-clean discrepancy. The qualified
reports and original failures are in
`docs/evidence/modern-snapshot-bindings-2026-10-14`. Further authoring/rendering
repair remains required before repeating this workload.

Capturing table targets only when their cell-action menu opens removes repeated
render-time cohort work. Retain the target and argument shape through peer edits;
successful actions dismiss, and reopening captures updated structure. The clean
final run completes twenty input/menu samples per engine: input p95 is 1,644.1 ms
Chromium, 1,852 ms WebKit and 2,240 ms Firefox; menus are 139.6, 241 and 285 ms.
All targets still fail. Measurement completion is independent of target success,
and explicit budget assertions now fail the test when missed. Complete reports,
matching source/artifact receipts, hardware and the 54-case functional run are in
`docs/evidence/modern-table-controls-2026-10-14`. Remaining authoring/snapshot
and rendering costs need repair against the unchanged targets.

The body-presentation candidate reuses native controls across local menus while
invalidating document/receipt, lifecycle/capability/provider and geometry changes.
Column geometry observes usable page content width and live font metrics rather
than viewport width; stored split/history remain untouched by reflow. The clean
same-fixture run completes every sample: input p95 is 1,598.5 ms Chromium,
1,689 ms WebKit and 2,004 ms Firefox; menu p95 is 42, 57 and 70 ms. All three
menu targets pass on this Mac workload, while all input targets still fail.
Corrected column presentation prevents a pure cache-only comparison with earlier
incorrect-layout timings. Raw reports, exact receipts and qualified functional
checks are in `docs/evidence/modern-body-presentation-2026-10-14`. Shared authoring
and complete snapshot publication remain unresolved; no full acceptance is claimed.

Preserve the failed original evidence, current required CI, full functional,
rendered, accessibility, selection/scroll/media/resource and resized/stacked
workloads, larger-document preservation and physical native campaigns. Physical
access/final-review availability is deferred; these requirements remain open.
