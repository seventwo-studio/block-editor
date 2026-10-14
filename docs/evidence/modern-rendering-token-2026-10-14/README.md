# Shared confirmation of renderer bindings

Source `67c64abcf3ba30a5a64ce4c7cc4ddd9eec2cee58` adds a session-local
shared-engine token for checked renderer bindings. A strong lease retains the
structural read view, preventing allocator reuse from reviving an old token.
Only eligible independent-field replay can confirm unchanged bindings. Unknown
tokens and alias-bearing projections return the complete checked array; same-value
peer replacement gets a new token. Tokens never enter commands or saved history.
TypeScript retains its immutable array only after shared confirmation; advertised
read failures propagate. Existing older-engine fallbacks remain available.

Literal tests cover active scalar writing, foreign/reopened tokens, conversion
aliases, author Undo and same-value peer replacement. The original missing-try
compiler failure is retained in native-focused.log; native-repaired.log passes.

| Matching verification | Result |
| --- | --- |
| Focused native | 14 passed |
| Full native | 595 core + 99 Apple + 8 other = 702 passed |
| Typed snapshot/token unit checks | 4 tests / 24 expectations passed |
| Native ABI | 968 responses / 30 fixtures passed |
| Typed native consumer | 515 requests / 55 fixtures / 26 commands / 12 groups passed |
| Actual three-engine browser suite | 63 passed |
| Actual Android JNI typed consumer | 1 case, normal instrumentation |
| Matching JS/declarations/WASM/JNI builds | Clean source receipts retained |

The actual-WASM diagnostic first reads all 5,242 nodes: 2,077,926 bytes and
397 ms including initial structural-view preparation. After two accepted scalar
appends, the shared engine confirms the cached view with 64-byte responses in
0.20 and 0.16 ms. The consumer retains the exact owned array. These two reads
exclude browser input/rendering and do not establish p95 or resource acceptance.

The frozen serial production run retains the unchanged 1,000-block fixture,
three excluded warmups, twenty input and twenty menu samples per engine,
trusted initiating events, accepted/displayed content, focus and second frames.

| Browser | Typing p95 | Menu p95 | Result |
| --- | ---: | ---: | --- |
| Chromium | 377.9 ms | 45.9 ms | Input failed; menu passed |
| WebKit | 479 ms | 68 ms | Input failed; menu passed |
| Firefox | 459 ms | 84 ms | Input failed; menu passed |

The unchanged targets are 50/100 ms; all three tests correctly exit with input
failures. Broader authoring and complete-document publication still cost too
much. The full native/browser/physical/assistive/resource/private-install and
final acceptance campaigns remain open. Physical checks and Luca's final review
are deferred without a waiver. Current hosted CI/review is still required.
Protected main, private 0.2.0 and concurrent Foliostrate work remain unchanged.
[Receipt](receipt.json) and [hashes](hashes.json) pin the results and artifacts.
