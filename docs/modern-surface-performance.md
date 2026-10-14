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
document. It rebuilds after a new accepted snapshot and does not derive origins
from display labels. Contextual reads and the outline traverse actual schema
collections; opaque consumer properties named `rows` or `children` retain their
data without becoming editor nodes. Reused labels after peer deletion resolve to
their new shared identities.

## Current evidence boundary

The initial production workload exceeded its four-minute limit before producing
samples. Shared read and captured-cohort optimizations plus scoped React bindings
make the surface render and pass the affected functional/preservation cases.
The subsequent full-keydown run recorded sixteen verified input/display samples
at roughly 9.4 seconds each before its deadline. It did not complete the twenty
samples or measure menus. This contradicts the 50 ms target; there is no accepted
input p95 or menu result. Profile and repair the remaining authoring/snapshot path
before repeating the same workload.

Preserve the failed original evidence, current required CI, full functional,
rendered, accessibility, selection/scroll/media/resource and resized/stacked
workloads, larger-document preservation and physical native campaigns. Physical
access/final-review availability is deferred; these requirements remain open.
