# Input registrations and host form boundary

Stable native ref callbacks keep unchanged field controls registered during
ordinary React renders. Each session owns its own registration map; departing
cleanup cannot erase an incoming session's same-wire field. Focus, selection
listeners and rendered-body dependencies follow that owner. A one-edit native
registration diagnostic records only one set/delete for the title among three
inputs; body controls remain registered. It is not target/resource acceptance.

All 43 editor action buttons now explicitly use type=button. The original
three-engine host-form test records unintended submit events after Insert and
block selection; its repair records none and retains the complete document.
This preserves application ownership of saving/publication when the editor is
embedded in a form.

The integrated browser suite passed all 66 cases before final map-dependency
refinements. All 24 affected composition/callback/layout/drag/focus/form/identity
checks pass after those refinements. Keep these qualified sources; do not present
them as one final-source full suite. Typechecks and coherent JS/WASM/JNI builds
pass. Unchanged shared binary hashes preserve earlier runtime qualifications.

Overall lint still fails. Baseline had 43 missing-button-type findings; these
are removed, and final hook-dependency finding count equals the baseline after
new map ownership is accounted for. Other findings remain explicit, not passed.

| Browser | Typing p95 | Menu p95 | Result |
| --- | ---: | ---: | --- |
| Chromium | 342.3 ms | 58.4 ms | Input failed; menu passed |
| WebKit | 397 ms | 79 ms | Input failed; menu passed |
| Firefox | 391 ms | 89 ms | Input failed; menu passed |

The frozen unchanged 1,000-block workload completes every twenty sample after
three warmups with the original content/focus/second-frame assertions. All three
combined tests correctly fail the unchanged 50 ms input target; measured menus
meet 100 ms. Remaining shared authoring, snapshot transport/rendering and broader
campaigns stay open. Direct diagnostics do not prove a causal surface speedup.

Current required hosted CI/review, remaining accessibility/lint work, published
native installation, deferred physical checks and explicit final acceptance are
required. Protected main, private 0.2.0 and concurrent Foliostrate work remain
unchanged. [Receipt](receipt.json), [lint summary](lint-summary.json) and
[hashes](hashes.json) retain exact sources, samples and failed originals.
