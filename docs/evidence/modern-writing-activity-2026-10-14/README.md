# Writing activity and structurally equivalent read views

`8d6e4e2` retains the checked structural view when scalar projection marks an
already-active birth as touched. Membership still enters the touched set for
future replay. Active births are already visible wherever their placement is
valid; this activity does not change placement arbitration, labels, visibility,
order or addresses. Inactive births still invalidate the view and become visible
through retained peer work. All other mutation invalidation remains unchanged.

Literal expectations verify active/inactive visibility, prior value-copy isolation,
later label changes and moved/undone/reopened columns. Cache data remains absent
from saved histories. No authoring, admission or causal validation is skipped.

| Matching current verification | Result |
| --- | --- |
| Focused read/identity/projection/history | Thirteen cases passed |
| Full native regression | 594 core + 99 Apple + eight other = 701 passed |
| Native C ABI | 968 responses / thirty fixtures passed |
| Typed native consumer | 512 requests / 55 fixtures / 26 commands / twelve groups passed |
| Browser editor/context/preservation/consumer | All 63 passed across three engines |
| Actual JNI/private host/codec | All eighteen passed with normal instrumentation |
| Android HTTP/recovery | Five distinct processes passed with complete documents/readbacks |
| Matching clean JS/declarations/WASM/JNI | Built from the same reviewed source |

The serial direct actual-WASM probe measures accepted appends at 220–269 ms,
compared with 296–318 ms in the preceding probe. No-op shortcuts are 32–35 ms.
These two-call diagnostics exclude browser input/rendering and cannot accept a
p95 or resource campaign. The isolated preceding CPU profile identifies whole
structural preparation/document rendering; inclusive stack durations overlap.

The clean uninstrumented production run completes every twenty input/menu sample
after three excluded warmups in all engines on the unchanged 1,000-schema-block
fixture. Trusted initiating events, accepted/displayed text, menu focus, second
frames and full document/history preservation expectations remain unchanged.

| Browser | Input p95 | Menu p95 | Result |
| --- | ---: | ---: | --- |
| Chromium | 492 ms | 45.7 ms | Input failed; menu passed |
| WebKit | 574 ms | 63 ms | Input failed; menu passed |
| Firefox | 619 ms | 67 ms | Input failed; menu passed |

Targets remain 50/100 ms. All three tests correctly fail input assertions. Menu
passes qualify only this recorded Mac/browser workload. Broader ordinary-edit
authoring and full-document publication costs remain unresolved. Fresh current
required CI/review plus full native/browser/physical/assistive/resource/private
installation and final acceptance remain open. Physical and Luca's final-review
availability stays deferred without a waiver. Private 0.2.0, protected main and
concurrent Foliostrate work are unchanged. [Receipt](receipt.json) and
[hashes](hashes.json) retain exact code, results, artifacts and qualifications.
