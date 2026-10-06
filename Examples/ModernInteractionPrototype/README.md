# Native interaction review

Working study for [ST-121](https://linear.app/seventwo/issue/ST-121). The existing protocol-6 shared engine edits body content. Title, viewing preferences and two-column membership/split are isolated local review state; this app cannot save or broadcast a modern document. It uses a bundled fixture and makes no network requests.

Build a real Mac bundle with `./script/build_and_run.sh --prototype --build-only`, then run with `./script/build_and_run.sh --prototype`. The original Run action still launches the original local lab. Generate the test project with `cd Examples/ModernInteractionPrototype && xcodegen generate`. Run scheme `ModernPrototypeMac` on macOS or `ModernPrototypePhone` on a task-owned iOS simulator; both schemes retain original XCTest screenshots and screen recordings. No QuickTime is required.

The UI tests exercise native inputs, clicks/taps and menus rather than driving the model directly. Mac screenshot placement is scoped to this app and activated only by `EDITOR_REVIEW_PRIMARY_WINDOW=1`. `EDITOR_REVIEW_RECEIPT` optionally writes fixture-only action/state receipts to the supplied test path.

See the [original review](../../docs/evidence/modern-editor-prototype-2026-10-05/README.md) and [revision review with unresolved checks](../../docs/evidence/modern-editor-prototype-2026-10-05/revisions/README.md). The revised suite records four passing phone walkthroughs and three failed checks; ST-121 remains open and gates native canvas/input work while shared-core ST-122 proceeds. This is a review app, not a production adapter or an accepted protocol-7 implementation.
