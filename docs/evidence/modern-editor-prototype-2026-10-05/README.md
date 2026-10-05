# ST-121 native interaction review, 5 October 2026

This records the original source at `02c4393`. Two XCTest walkthroughs passed on the Mac running macOS 27.0.1 and on an iPhone simulator running iOS 27: **four tests, zero failures**. The [receipt](receipt.json) pins that source and unmodified exported PNG/MP4 hashes. Movies are XCTest screen recordings of the actual tested app; they are not assembled from screenshots. Simulator evidence is not physical iPhone acceptance. The [current revision review](revisions/README.md) records subsequent changes, four passing phone walkthroughs and three unresolved checks.

| Walkthrough | Actual tested actions | Evidence |
| --- | --- | --- |
| Writing | Direct title edit, native body typing, `/hea` filtering, Escape/dismiss retains query, touch/pointer picker search and heading insertion | [Mac movie](mac-writing-walkthrough.mp4), [iPhone movie](iphone-simulator-writing-walkthrough.mp4) |
| Structure and personal views | Two-block selection, local column creation, moving a block to the second column, removal keeps both texts, outline and focus mode; Mac also operates the split slider with keyboard | [Mac movie](mac-columns-walkthrough.mp4), [iPhone movie](iphone-simulator-columns-walkthrough.mp4) |

The first Mac attempt failed when XCTest captured an app window on a secondary display. A test-only placement flag now places this app on the primary display. Both hosts then exposed a real picker hit-area defect: an accessibility row included a spacer that did not receive clicks/taps. Adding a rectangular content shape fixed the actual behavior; both complete walkthroughs now pass. Failed runs are not counted as acceptance.

## Decisions and revisions

Retain direct title editing, scalar-safe body input through the shared engine, a picker anchored to its invoking block, cancellation that retains typed query text, stable origin selection and explicit first/second reading order. Personal outline/focus controls do not mutate body content. Narrow layout stacks the columns; local membership and split are kept separate from the protocol-6 document.

Reject using screenshot-only evidence for writing behavior, reproducing the engine in a host, and publishing this local review state as a modern document. Protocol-7 transaction grouping, shared title/layout history and concurrent ownership routes remain ST-122 requirements.

**ST-121 stays In Progress.** The original review produced these explicit prototype revisions/checks; their current disposition is recorded in the [revision review](revisions/README.md):

* Quiet the permanent per-block action chrome and validate contextual formatting, conversion, reorder and nested/rich editing with native input.
* Make the narrow outline a panel and expose touch resize while stacked. Add pointer divider dragging and a test that proves the split changes; the current keyboard slider walkthrough alone does not prove a meaningful ratio change.
* Render rich marks on iOS, validate selection/focus retention across tools/moves and follow keyboard-only title-to-body navigation, touch accessory, list/toggle containment and long-document outline jumps.
* Use container membership order for column rendering and review multiple independent layouts, boundary insertion, cancellation and explicit forbidden nesting. The current local study supports one layout around selected roots and is not the final shared model.

These are concrete prototype revisions. ST-140's independent fixture contract is now complete. Following Luca's instruction to keep eligible work moving, ST-121 gates ST-123 native canvas work and downstream input/touch delivery while ST-122 proceeds from the accepted ST-120/ST-140 shared-core contract. Pending checks remain open. Physical-device access/acceptance stays with ST-170/ST-139/ST-142/ST-143. No credentials, package grants, publication or paid services changed.
