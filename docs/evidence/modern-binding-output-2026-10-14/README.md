# Complete trusted binding output and current host callbacks

`0a273ac` constructs checked binding output as `JSONValue` directly rather than
encoding the full trusted Swift array into bytes and decoding it before final
bridge encoding. Every node, address, kind, destination origin and field remains.
Public Codable/API shape is unchanged. Incoming admission/round-trip checks stay
unchanged; unsupported numeric identities fail rather than round. Exact byte
expectations cover raw Unicode, aliases, document/baseline/inserted identities,
empty fields and maximum exact counter/index boundaries.

`f1ede8c` fixes retained inline DOM invoking an old host reference callback.
A ref follows the committed callback and clears on cleanup without rebuilding
a composing native buffer. Pointer/keyboard expectations across three browsers
retain the atomic reference, original document and later committed pending text.

| Matching affected verification | Result |
| --- | --- |
| Native binding/identity/order/projection/history | Ten focused cases passed |
| Native C ABI | 968 responses / thirty fixtures passed |
| Typed native consumer | 512 requests / 55 fixtures / 26 commands / twelve groups passed |
| Focused host-callback browser check | Three passed |
| Integrated browser editor/context/preservation/consumer | All 63 passed |
| Actual matching JNI typed consumer | One complete instrumentation case passed |
| Clean matching JS/declarations/WASM/JNI builds | Passed at f1ede8c |

The isolated instrumented binding read drops from 469.4 ms to 137.8 ms, returning
the same 5,242 nodes and 2,077,866 encoded bytes. The initial probe omits source
commit/clean fields; its WASM hash matches the previous retained reviewed build.
The after probe pins clean current source. Both are diagnostics, not p95,
resource or surface acceptance. CPU inclusive stack durations overlap.

The final uninstrumented production run completes all twenty input/menu samples
after three excluded warmups per operation in every engine on the unchanged
1,000-schema-block fixture. Trusted initiating input, accepted/displayed content,
focused menus, second-frame and whole-document/history checks remain unchanged.

| Browser | Input p95 | Menu p95 | Result |
| --- | ---: | ---: | --- |
| Chromium | 556.1 ms | 42.6 ms | Input failed; menu passed |
| WebKit | 628 ms | 56 ms | Input failed; menu passed |
| Firefox | 678 ms | 67 ms | Input failed; menu passed |

Targets remain 50/100 ms. All three combined tests correctly fail input budgets.
Menu passes qualify only this recorded Mac/browser workload. Prior full 699
native, eighteen JNI and five-process runs remain pinned to the earlier sort-key
source; they do not become current full-suite passes. Fresh complete current-head
CI/review is required. Physical IME/assistive/resource/full platform/private-install
and final acceptance remain open. Physical/final-review availability is deferred.
Private 0.2.0, protected main and concurrent Foliostrate work are unchanged.
[Receipt](receipt.json) and [hashes](hashes.json) retain exact code, results and limits.
