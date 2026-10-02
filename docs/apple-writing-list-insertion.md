# Apple Writing list insertion

On macOS, iOS/iPadOS and visionOS, list owners expose Add item; schema list
items expose Add nested item. Both
invoke one shared `insertCollectionNodes` command with a fresh schema ID and an
empty rich content field. Todo descendants start unchecked; ordered/unordered
items do not acquire a checked field. Style and insertion order are resolved
from current shared state after composition and held peer delivery drain.

The rendered owner's irreversible lease and permitted list policy are checked
before native finalization and again afterward. A disposed, moved or disabled
control cannot insert into a replacement owner. A failed composition commit
retains its draft and held packets. Availability checks and rendering leave
absent optional children fields untouched and do not compute document-wide
collection ordering; an explicit Add nested item command
creates the collection, and author Undo removes that birth again.

The returned opaque position targets the new empty content field. Where a native
field currently owns focus, the existing focus transfer machinery can adopt the
new field after layout. These creation buttons are omitted on watchOS/tvOS;
their agreed reading/text/checklist/ordering presentation is preserved.
No independent document-array mutation, protocol upgrade, network asset access,
slash command or drag surface is introduced.

Focused component witnesses are parameterized over explicit protocols 4, 5 and
6. They cover AppKit marked input, held peer insertion/style/reparenting, host
policy/read-only/disposal guards, failed composition, retained metadata/rich
reference/Unicode, fresh position/focus and one-author insertion Undo/reopen.
These tests are separate from installed system IME, VoiceOver and device
acceptance.
