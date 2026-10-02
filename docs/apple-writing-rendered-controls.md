# Apple Writing rendered structural controls

Writing block, list-item and table-row controls retain an opaque origin and a
per-render lease. Removing that rendering permanently retires its callbacks.
A document change that moves or deletes the origin retires the token immediately,
including a move/Undo round trip before SwiftUI renders. A new appearance creates
a new token; it does not re-arm the old one. Each callback checks current model
permission, current origin/location and its own lease before committing input,
and checks again after composition and held peer delivery drain.

Move up/down and list indent/outdent use the accepted sibling snapshot to show
availability. An already impossible action returns before native finalization.
A command that was possible before held peers drain rechecks actual shared order
inside the transaction. One cached collection snapshot serves sibling controls;
actual mutation uses shared WritingSession commands. Checkbox, duplicate, delete,
conversion, toggle child insertion and table row/cell insertion share these
leases. List conversion also retains its captured first-item target lease;
reparenting that item cannot convert the new owner through an old menu. Observer
registration/removal is constant work per token, with one document-event sweep.
Watch actions retain their existing visible Button/VStack presentation.

The component regression cases exercise real AppKit marked input and the same
production closures used by the view. They cover disposed and move-away/return
callbacks, fresh controls, permission revocation, blocked movement with held peers,
and post-drain bounds changes across explicit protocols 4, 5 and 6. They do not
establish installed menu, VoiceOver, device or GUI acceptance. Structural rendering
leases do not add slash commands, drag operations or multi-block selection UI.
