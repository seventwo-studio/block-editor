# Body presentation, usable geometry and completed menu targets

`2d54388` retains the rendered body/native controls across local menu, focus and
formatting updates. Accepted document/receipt, relevant capabilities/composition,
provider target/status/reason, selection/collapse/split, width/font metrics and
host callback changes invalidate it. Authoring/admission/history remain in Swift.
Identical-valued peer replacements still invalidate their opaque origins.

Column presentation now observes the page content box rather than the whole
viewport. Readable/wide gutters and live text metrics determine available width;
responsive stacking never writes the stored split. Appearance controls have
clear exact labels: Font, Text size and Page width.

Focused actual three-engine checks preserve an uncommitted synthetic composition
buffer through local menus, publish its later commit, update composition-disabled
media/provider status and reflow columns after page/text changes without authoring
the split. Initial exact-label lookup failed in all engines; repaired labels and
tests pass all six. The readonly-property fixture typecheck failure is retained.

The integrated run passes 57 of 60 cases and fails three pointer setups. Correct
stacking moves the slider below the viewport; the original setup uses offscreen
coordinates. `b4c6981` scrolls it into view before deriving pointer coordinates.
All nine affected lifecycle/layout/drag checks then pass, including unchanged
preview cancellation and saved-history expectations. These are sixty qualified
checks across the failed run and affected rerun, not one successful full suite.
Fresh required CI remains necessary; existing expected fixture JSON is unchanged.

The clean frozen production run completes twenty input and menu samples after
three excluded warmups per operation in all engines on the same independent
1,000-schema-block fixture. Trusted initiating input, accepted/displayed content,
focused menus, second-frame verification and whole-document/history checks remain.

| Browser | Input p95 | Menu p95 | Target result |
| --- | ---: | ---: | --- |
| Chromium | 1,598.5 ms | 42 ms | Input failed; menu passed |
| WebKit | 1,689 ms | 57 ms | Input failed; menu passed |
| Firefox | 2,004 ms | 70 ms | Input failed; menu passed |

The unchanged targets are 50/100 ms. All three tests fail the input assertion;
measurement completion and target success remain separate. Menu targets pass
only for this recorded Mac/browser workload. Corrected responsive presentation
means earlier incorrect-layout timings are not a cache-only comparison. Matching
clean JS/WASM source receipts, production hashes, raw samples and captures are
retained. Hardware is Mac16,9 / Apple M4 Max / 14 logical CPUs / 36 GiB /
macOS 27.0.1, as in the preceding same-host run.

This does not accept physical IME, assistive, native performance, resolved-media,
resource, resized/stacked timing or the full finishing matrix. Shared authoring
and complete snapshot publication remain slow. Original label/pointer failures
stay retained; no merge/private release/final acceptance occurred. Physical and
Luca's final-review requirements remain deferred. [Receipt](receipt.json) and
[hashes](hashes.json) pin the exact results and qualifications.
