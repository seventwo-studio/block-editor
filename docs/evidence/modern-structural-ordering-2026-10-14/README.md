# Shared structural ordering and remaining typing cost

`264d187` decorates structural node/placement items with their encoded keys once
per sort. Existing String comparison, exact UTF8 comparison, canonical owner-key
equality, tier/Element priority and stable ties remain unchanged. Public identity
and placement comparators, admission, causal closure and durable histories retain
their contracts. Keys are ephemeral; no encoded-key dictionary merges differently
spelled Unicode values. Literal independent expectations accompany comparison
against the original public rules.

An isolated first-append V8 profile identifies structural placement preparation
and final document rendering as the dominant original cost. Repeated NodeID JSON
encoding occurs inside sort comparisons. Inclusive sampled stacks overlap and
must not be summed; this is diagnosis, not a performance-budget result. The probe
now supports `MODERN_CPU_PROFILE_OUTPUT` to isolate one append from initialization.

| Matching verification | Result |
| --- | --- |
| Focused identity/ordering/projection/history | Thirteen cases passed |
| Full native regression | 592 core + 99 Apple + eight other = 699 passed |
| Native C ABI | 968 responses / thirty independent fixtures passed |
| Typed native consumer | 512 requests / 55 fixtures / 26 commands / twelve groups passed |
| Browser editor/context/preservation/consumer | All sixty cases passed across three engines |
| Actual JNI consumer/host/codec | All eighteen cases passed after harness repair |
| Android HTTP/recovery | Five independent processes passed, complete document/readback checks |
| Matching clean JS/declarations/WASM/JNI | Built from the same reviewed source |

The first Android command incorrectly names nonexistent `ModernJSONTest`: ten
valid cases complete, but the overall eleven-case run fails. Its original log
remains retained. The corrected command uses `NativeJsonTransportTest` and passes
all eighteen cases with a normal terminal instrumentation result. No expected
acceptance fixture changed. Full current-head required CI/review remains necessary.

The direct serial actual-WASM two-append probe drops from 1,122–1,148 ms to
290–317 ms. Shortcut no-ops remain 26–29 ms. These diagnostics exclude browser
input/rendering; process resident memory from two appends is not resource evidence.

The uninstrumented production run completes twenty input/menu samples per engine
after three excluded warmups on the unchanged 1,000-schema-block workload. Clean
source and matching artifacts are pinned; trusted initiating events, accepted and
displayed content, menu focus, second-frame and complete history/document checks
remain unchanged.

| Browser | Input p95 | Menu p95 | Result |
| --- | ---: | ---: | --- |
| Chromium | 835 ms | 42.6 ms | Input failed; menu passed |
| WebKit | 972 ms | 56 ms | Input failed; menu passed |
| Firefox | 1,036 ms | 70 ms | Input failed; menu passed |

Targets remain 50/100 ms. All three tests correctly fail the input assertion;
measurement completion does not accept typing performance. Menu targets pass only
for this recorded Mac/browser workload. Remaining authoring and snapshot/binding
publication costs need repair. Full native/browser/physical/assistive/resource,
private-install and final-review requirements stay open. Physical availability
and Luca's final review remain deferred, with no waiver. Private 0.2.0, protected
main and concurrent Foliostrate work are unchanged. [Receipt](receipt.json) and
[hashes](hashes.json) retain exact source, results, original failure and qualifications.
