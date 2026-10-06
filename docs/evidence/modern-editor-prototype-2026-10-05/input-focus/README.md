# Prototype input and focus fixes, 5 October 2026

This delivers the three previously failed phone input flows and fixes the long-outline jump exposed during the follow-up. Native inputs receive changing projected values and an owned focus request so SwiftUI refreshes their representables. A request retains its intended range independently of outgoing callbacks. UIKit commits only after the outermost native edit finishes, including replacement/composition callbacks; intercepted slash Return cannot commit the outgoing query again. Narrow outline navigation runs after its sheet finishes dismissing.

The complete text, caret, order and containment assertions remain. The value helper uses one native snapshot for its final assertion and diagnostic, with String and attributed-string representations supported. No partial text was substituted for an expected complete value.

| Native walkthrough | Pinned observation | Original recording |
| --- | --- | --- |
| Column focus, order and containment | Attempt 3 passed: continued typing after creation/reorder/flattening, logical order and list/toggle containment | [Column flow](attempt-3-media/44848632-A636-433D-8DDB-86148F095F8A.mp4) |
| Title-to-body and slash Return | Attempt 3 passed: complete body prefix, Return accepts heading and complete new-field input | [Keyboard flow](attempt-3-media/911A2922-769D-4735-A503-B2F51177ED6F.mp4) |
| Multiple layouts and empty-column input | Attempt 3 passed: independent layouts, nesting rejection and complete `Fresh writing` input | [Empty-column flow](attempt-3-media/0D14826B-D6A4-4594-9B8F-E8465B537D25.mp4) |
| Formatting, conversion, nested input and long outline | Attempt 4 failed the closing-heading hit check; attempt 5 passes after the narrow sheet-dismissal fix | [Final outline flow](attempt-5-media/D0C3C0E1-B2A2-4B82-94EC-83CD0AD2DCCC.mp4) |
| Block range/personal views; rich fields/literal code; direct title/picker | All three passed in attempt 4 on the same source as attempt 3 | Original native outcome logs retained |

The [receipt](receipt.json) pins every attempt's source, logs, completed result summaries and all 14 unmodified native PNG/MP4 exports from attempts 3 and 5. Original exporter manifests also list UI snapshots/events that are not copied into this media index. Attempts 1, 2 and 4 logged every selected outcome but their failed-run coordinators stalled during finalization; only the owned completed coordinators were stopped. Their exit 143 and incomplete result bundles remain explicit, and their logs are not described as completed successful runs.

Seven walkthroughs have passing observations across attempts 3–5. This is **not one seven-test run on final source**: the final source was checked only on the previously failed navigation path. The earlier failed [revision receipt](../revisions/README.md) remains unchanged. Body uses the unchanged protocol-6 source at `da0505771898308da100432638b11b463b4fa952`; title and column state remain local prototype state. This does not implement or accept the modern protocol-7 host.

Luca's accepted implementation/finishing split moves ST-121 and broad native acceptance to the finishing project after ST-144. ST-121 no longer gates ST-123 or downstream implementation. Revised Mac automation remains open in ST-143; earlier Mac recordings retain their original source qualification. Device, assistive, preservation and performance campaigns remain with their finishing owners. No QuickTime recording, publication or consumer rollout occurred here.
