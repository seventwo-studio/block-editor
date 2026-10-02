package studio.seventwo.blockeditor

import androidx.compose.ui.text.TextRange
import androidx.compose.ui.text.input.TextFieldValue
import kotlinx.coroutines.CoroutineDispatcher
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import org.json.JSONArray
import org.junit.Assert.*
import org.junit.Test
import java.util.ArrayDeque
import kotlin.coroutines.CoroutineContext

class WritingInputTest {
    private class Dispatcher : CoroutineDispatcher() {
        private val queue = ArrayDeque<Runnable>()
        override fun dispatch(context: CoroutineContext, block: Runnable) { queue.addLast(block) }
        fun drain() { var n = 0; while (queue.isNotEmpty()) { check(++n < 100); queue.removeFirst().run() } }
    }
    private fun seed() = JSONArray("""[{"id":"p","type":"paragraph","host":{"keep":"opaque"},"content":[{"type":"text","text":"A","marks":[{"type":"bold"}]},{"type":"entity-ref","entityType":"person","entityId":"mira","label":"Mira","host":"opaque"},{"type":"text","text":"B","marks":[]}]}]""")
    private fun text(session: WritingSession) = (0 until session.snapshot.getJSONArray("blocks").length()).map {
        plainText(session.snapshot.getJSONArray("blocks").getJSONObject(it).getJSONArray("content"))
    }
    private fun receipt(session: WritingSession) = session.save().export().toString()

    @Test fun scalarDeltaPreservesRichAtomsAndRemoteUndoAfterReopen() {
        assertEquals(Triple(1, 3, "東京"), writingDifference("A😀B", "A東京B"))
        val a = WritingSession.createV4("native-delta", "a", "v4", seed())
        val b = WritingSession.createV4("native-delta", "b", "v4", seed())
        val dispatcher = Dispatcher(); val scope = CoroutineScope(SupervisorJob() + dispatcher)
        var hostChanges = 0; a.onChange = { hostChanges++ }
        val owner = WritingEditorInputs(a, scope, { true }, { fail("No draft expected") }, { throw it })
        val binding = owner.bind(a.node(NodeAddress("p"))); owner.attach(binding); owner.focusChanged(binding, true)
        try {
            binding.update(TextFieldValue("A😀MiraB", TextRange(3)))
            assertEquals(listOf("A😀MiraB"), text(a))
            b.replaceText(b.textAddress(b.node(NodeAddress("p"))), 6, 6, "R")
            a.receive(b.changes())
            assertEquals("A😀MiraBR", binding.input.value.text)
            assertEquals(TextRange(3), binding.input.value.selection)
            assertEquals(2, hostChanges)
            val rich = a.snapshot.getJSONArray("blocks").getJSONObject(0).getJSONArray("content").toString()
            assertTrue(rich.contains("mira")); assertTrue(rich.contains("bold")); assertTrue(rich.contains("opaque"))
            val reopened = WritingSession.restore(a.save(), "a")
            try { reopened.undo(); assertEquals(listOf("AMiraBR"), text(reopened)); reopened.redo(); assertEquals(listOf("A😀MiraBR"), text(reopened)) }
            finally { reopened.close() }
        } finally { owner.close(); scope.cancel(); a.close(); b.close() }
    }

    @Test fun cleanNativeReferenceCaretAndReversedSelectionPreserveAtomsPeerAndHistory() {
        val blocks = JSONArray("""[{"id":"p","type":"paragraph","host":"keep","content":[{"type":"text","text":"Sibling😀","marks":[{"type":"italic"}]},{"type":"entity-ref","entityType":"person","entityId":"peer","label":"Reference","host":"opaque-reference"}]}]""")
        val a = WritingSession.createV4("native-reference-caret", "a", "v4", blocks)
        val b = WritingSession.createV4("native-reference-caret", "b", "v4", blocks)
        val scope = CoroutineScope(SupervisorJob() + Dispatcher())
        val owner = WritingEditorInputs(a, scope, { true }, { fail("No draft expected") }, { throw it })
        val identity = a.node(NodeAddress("p")); val binding = owner.bind(identity)
        owner.attach(binding); owner.focusChanged(binding, true)
        try {
            val accepted = receipt(a)
            binding.update(TextFieldValue("Sibling😀Reference", TextRange(17)))
            assertEquals(TextRange(18), binding.input.value.selection)
            binding.update(TextFieldValue("Sibling😀Reference", TextRange(10)))
            assertEquals(TextRange(9), binding.input.value.selection)
            binding.update(TextFieldValue("Sibling😀Reference", TextRange(17, 10)))
            assertEquals(TextRange(18, 9), binding.input.value.selection)
            assertEquals(accepted, receipt(a)); assertTrue(owner.exportDrafts().isEmpty())
            val copied = a.copyClipboard(WritingSelection(text = listOf(a.selectedText(a.textAddress(identity), 9, 18)))).export().toString()
            assertTrue(copied.contains("entity-ref")); assertTrue(copied.contains("opaque-reference")); assertTrue(copied.contains("Reference"))
            b.replaceText(b.textAddress(b.node(NodeAddress("p"))), 0, 0, "R"); a.receive(b.changes())
            assertEquals(TextRange(19, 10), binding.input.value.selection)
            assertEquals("RSibling😀Reference", binding.input.value.text); assertTrue(owner.exportDrafts().isEmpty())
            binding.update(TextFieldValue("RSibling😀Reference", TextRange(18)))
            assertEquals(TextRange(19), binding.input.value.selection)
            owner.softBreak(binding) { binding.update(TextFieldValue("RSibling😀Reference", TextRange(18))) }
            assertEquals(listOf("RSibling😀Reference\n"), text(a)); assertTrue(owner.exportDrafts().isEmpty())
            assertTrue(a.snapshot.toString().contains("opaque-reference")); assertTrue(a.snapshot.toString().contains("italic"))
            val reopened = WritingSession.restore(a.save(), "a")
            try {
                reopened.undo(); assertEquals(listOf("RSibling😀Reference"), text(reopened))
                reopened.redo(); assertEquals(a.snapshot.toString(), reopened.snapshot.toString())
            } finally { reopened.close() }
        } finally { owner.close(); scope.cancel(); a.close(); b.close() }
    }

    @Test fun outgoingNativeBlurKeepsEmptyTailRedoFocusAndOriginalCaretProvenance() {
        val a = WritingSession.createV4("native-redo-focus", "a", "v4", seed())
        val scope = CoroutineScope(SupervisorJob() + Dispatcher())
        val owner = WritingEditorInputs(a, scope, { true }, { fail("No draft expected") }, { throw it })
        val p = a.node(NodeAddress("p")); val original = owner.bind(p)
        owner.attach(original); owner.focusChanged(original, true)
        try {
            original.update(TextFieldValue("AMiraB", TextRange(6)))
            owner.enter(original, {}, "tail")
            val enter = checkNotNull(owner.focusRequest)
            val tailIdentity = a.node(NodeAddress("tail"))
            val tail = owner.bind(tailIdentity); owner.attach(tail)
            owner.consume(enter, tail); owner.focusChanged(tail, true)
            owner.history({}, false)
            val undo = checkNotNull(owner.focusRequest)
            val head = owner.bind(p); owner.attach(head)
            owner.consume(undo, head); owner.focusChanged(head, true)
            assertEquals(TextRange(6), head.input.value.selection)
            lateinit var outgoing: WritingEditorInputs.Binding
            owner.history({
                // A replacement native source may attach during finalization.
                // Its later blur belongs to that source, not the returned tail.
                outgoing = owner.bind(p); owner.attach(outgoing)
                owner.focusChanged(outgoing, true)
            }, true)
            val redo = checkNotNull(owner.focusRequest)
            assertEquals(writingKey(a.textAddress(tailIdentity)), writingKey(a.resolvePosition(redo.range.start).address))
            assertEquals(0, a.resolvePosition(redo.range.start).offset)
            owner.focusChanged(outgoing, false)
            assertEquals("Outgoing source blur must preserve the returned tail", redo, owner.focusRequest)
            val destination = owner.bind(tailIdentity); owner.attach(destination)
            owner.consume(redo, destination); owner.focusChanged(destination, true)
            assertNull(owner.focusRequest); assertEquals(TextRange(0), destination.input.value.selection)
            assertTrue(owner.exportDrafts().isEmpty())
            val reopened = WritingSession.restore(a.save(), "a")
            try {
                assertEquals(listOf("AMiraB", ""), text(reopened))
                reopened.undo(); assertEquals(listOf("AMiraB"), text(reopened))
                reopened.redo(); assertEquals(a.snapshot.toString(), reopened.snapshot.toString())
            } finally { reopened.close() }
        } finally { owner.close(); scope.cancel(); a.close() }
    }

    @Test fun cleanBlurSelectionKeepsReversedRichRangeAndRebasesHeldPeerBeforeFormat() {
        val a = WritingSession.createV4("native-clean-format", "a", "v4", seed())
        val b = WritingSession.createV4("native-clean-format", "b", "v4", seed())
        val scope = CoroutineScope(SupervisorJob() + Dispatcher())
        val owner = WritingEditorInputs(a, scope, { true }, { fail("No draft expected") }, { throw it })
        val identity = a.node(NodeAddress("p")); val old = owner.bind(identity); owner.attach(old); owner.focusChanged(old, true)
        try {
            old.update(TextFieldValue("AMiraB", TextRange(1, 0)))
            b.replaceText(b.textAddress(b.node(NodeAddress("p"))), 0, 0, "R")
            owner.format(old, {
                old.update(TextFieldValue("AMiraB", TextRange(1))) // exact selection-only native blur
                a.receive(b.changes()) // held by finish until accepted anchors are restored
            }, "italic", org.json.JSONObject().put("type", "italic"))
            assertEquals(listOf("RAMiraB"), text(a))
            val content = a.snapshot.getJSONArray("blocks").getJSONObject(0).getJSONArray("content")
            val copied = a.copyClipboard(WritingSelection(text = listOf(a.selectedText(a.textAddress(identity), 1, 2)))).export().toString()
            assertTrue(copied.contains("italic")); assertTrue(copied.contains("bold"))
            assertTrue(content.toString().contains("mira")); assertTrue(content.toString().contains("opaque"))
            val request = checkNotNull(owner.focusRequest)
            assertEquals(2, a.resolvePosition(request.range.start).offset)
            assertEquals(1, a.resolvePosition(request.range.end).offset)
            assertTrue(a.exportDeferredChanges().isEmpty())
            assertEquals(1, a.changes().export().getJSONArray("changes").let { changes ->
                (0 until changes.length()).count { changes.getJSONObject(it).getJSONObject("id").getString("actor") == "a" }
            })
            val reopened = WritingSession.restore(a.save(), "a")
            try {
                reopened.undo(); assertEquals(listOf("RAMiraB"), text(reopened))
                assertFalse(reopened.snapshot.toString().contains("italic"))
                reopened.redo(); assertEquals(a.snapshot.toString(), reopened.snapshot.toString())
            } finally { reopened.close() }
        } finally { owner.close(); scope.cancel(); a.close(); b.close() }
    }

    @Test fun compositionFinalCorrectionCommitsBeforeSharedEnterAndReturnsOpaqueCaret() {
        val a = WritingSession.createV4("native-enter", "a", "v4", seed())
        val b = WritingSession.createV4("native-enter", "b", "v4", seed())
        val scope = CoroutineScope(SupervisorJob() + Dispatcher())
        val owner = WritingEditorInputs(a, scope, { true }, { fail("No draft expected") }, { throw it })
        val identity = a.node(NodeAddress("p")); val old = owner.bind(identity); owner.attach(old); owner.focusChanged(old, true)
        try {
            old.update(TextFieldValue("A東MiraB", TextRange(2), TextRange(1, 2)))
            b.replaceText(b.textAddress(b.node(NodeAddress("p"))), 6, 6, "R")
            a.receive(b.changes()); assertEquals(listOf("AMiraB"), text(a))
            assertEquals(1, a.exportDeferredChanges().size)
            owner.enter(old, { old.update(TextFieldValue("A東京MiraB", TextRange(3))) }, "tail")
            assertEquals(listOf("A東京", "MiraBR"), text(a))
            val request = checkNotNull(owner.focusRequest)
            assertEquals(0, a.resolvePosition(request.range.start).offset)
            val tail = a.node(NodeAddress("tail")); val fresh = owner.bind(tail); owner.attach(fresh)
            owner.consume(request, fresh); owner.focusChanged(fresh, true)
            assertEquals("MiraBR", fresh.input.value.text); assertEquals(TextRange(0), fresh.input.value.selection)
            val save = receipt(a); old.update(TextFieldValue("stale source")); assertEquals(save, receipt(a))
            val reopened = WritingSession.restore(a.save(), "a")
            try {
                reopened.undo(); assertEquals(listOf("A東京MiraBR"), text(reopened))
                reopened.redo(); assertEquals(listOf("A東京", "MiraBR"), text(reopened))
            } finally { reopened.close() }
            owner.detach(fresh)
        } finally { owner.close(); scope.cancel(); a.close(); b.close() }
    }

    @Test fun rememberedLeaseKeepsMarkedDraftAndAbandonedLeaseDoesNotRevokeCurrent() {
        val a = WritingSession.createV4("native-reservation", "a", "v4", seed())
        val dispatcher = Dispatcher(); val scope = CoroutineScope(SupervisorJob() + dispatcher)
        val retained = mutableListOf<WritingInputDraft>()
        val owner = WritingEditorInputs(a, scope, { true }, { retained.addAll(it) }, { throw it })
        val identity = a.node(NodeAddress("p")); val old = owner.bind(identity); owner.attach(old); owner.focusChanged(old, true)
        try {
            val abandoned = owner.bind(identity); abandoned.onAbandoned(); dispatcher.drain()
            assertTrue(old.current()); assertFalse(abandoned.current())
            old.update(TextFieldValue("A東京MiraB", TextRange(3), TextRange(1, 3)))
            val replacement = owner.bind(identity); replacement.onRemembered(); owner.detach(old); dispatcher.drain()
            assertSame(old.input, replacement.input); assertEquals(TextRange(1, 3), replacement.input.value.composition)
            owner.attach(replacement); owner.focusChanged(replacement, true)
            replacement.update(replacement.input.value.copy(composition = null))
            assertEquals(listOf("A東京MiraB"), text(a)); assertEquals(0, retained.size)
        } finally { owner.close(); scope.cancel(); a.close() }
    }

    @Test fun failedReferenceEditRetainsDraftRemotePacketsAndBlocksCommandUntilCorrected() {
        val a = WritingSession.createV4("native-failed-draft", "a", "v4", seed())
        val b = WritingSession.createV4("native-failed-draft", "b", "v4", seed())
        val scope = CoroutineScope(SupervisorJob() + Dispatcher())
        val retained = mutableListOf<WritingInputDraft>(); val errors = mutableListOf<Exception>()
        var retentionWorks = false
        val owner = WritingEditorInputs(a, scope, { true }, { if (!retentionWorks) error("Disk unavailable"); retained.addAll(it) }, { errors.add(it) })
        val identity = a.node(NodeAddress("p")); val old = owner.bind(identity); owner.attach(old); owner.focusChanged(old, true)
        try {
            old.update(TextFieldValue("AXiraB", TextRange(2), TextRange(1, 2)))
            b.replaceText(b.textAddress(b.node(NodeAddress("p"))), 6, 6, "R"); a.receive(b.changes())
            val accepted = receipt(a)
            try { owner.enter(old, {}, "must-not-exist"); fail("Partial reference must fail atomically") } catch (_: IllegalStateException) { }
            assertEquals(accepted, receipt(a)); assertEquals(listOf("AMiraB"), text(a))
            val draft = checkNotNull(old.input.draft()); assertEquals("AXiraB", draft.text); assertEquals(1, draft.deferred.size)
            assertEquals(accepted, draft.accepted.export().toString())
            try { owner.close(); fail("Failed host retention must keep the draft") } catch (_: IllegalStateException) { }
            assertEquals("AXiraB", old.input.value.text); assertEquals(1, a.exportDeferredChanges().size)
            val fresh = owner.bind(identity); owner.attach(fresh); owner.focusChanged(fresh, true)
            // The user deliberately restores the intact reference; remote packets drain.
            fresh.update(TextFieldValue("AMiraB", TextRange(1)))
            assertEquals(listOf("AMiraBR"), text(a)); assertNull(fresh.input.failedReason)
            assertTrue(a.exportDeferredChanges().isEmpty()); retentionWorks = true
        } finally { retentionWorks = true; owner.close(); scope.cancel(); a.close(); b.close() }
    }

    @Test fun readOnlyAndOlderAttachedLeaseCannotDeliverFinalCorrection() {
        val a = WritingSession.createV4("native-permission", "a", "v4", seed())
        val scope = CoroutineScope(SupervisorJob() + Dispatcher()); var editable = true
        val owner = WritingEditorInputs(a, scope, { editable }, { fail("No draft expected") }, { throw it })
        val identity = a.node(NodeAddress("p")); val old = owner.bind(identity); owner.attach(old); owner.focusChanged(old, true)
        val current = owner.bind(identity); owner.attach(current); owner.focusChanged(current, true)
        try {
            try { WritingEditorInputs(a, scope, { true }, {}, {}); fail("A second surface must not own composition") } catch (_: IllegalStateException) { }
            try { a.close(); fail("The native owner must close first") } catch (_: IllegalStateException) { }
            val before = receipt(a); editable = false
            current.update(TextFieldValue("read-only overwrite")); assertEquals(before, receipt(a))
            try { owner.softBreak(current, {}); fail("Read-only command must fail") } catch (_: IllegalStateException) { }
            editable = true
            current.update(TextFieldValue("A東京MiraB", TextRange(3), TextRange(1, 3)))
            owner.softBreak(current) {
                old.update(TextFieldValue("stale final value"))
                current.update(TextFieldValue("A東京MiraB", TextRange(3)))
            }
            assertEquals(listOf("A東京\nMiraB"), text(a))
            val accepted = receipt(a)
            old.update(TextFieldValue("stale")); current.update(TextFieldValue("revoked")); assertEquals(accepted, receipt(a))
        } finally { owner.close(); scope.cancel(); a.close() }
    }
    @Test fun movedOriginRevokesNativeAddressLeaseBeforeViewDisposal() {
        val blocks = seed().put(org.json.JSONObject("""{"id":"t","type":"toggle","summary":[],"children":[]}"""))
        val a = WritingSession.createV4("native-moved-address", "a", "v4", blocks)
        val b = WritingSession.createV4("native-moved-address", "b", "v4", blocks)
        val scope = CoroutineScope(SupervisorJob() + Dispatcher())
        val owner = WritingEditorInputs(a, scope, { true }, { fail("No draft expected") }, { throw it })
        val p = a.node(NodeAddress("p")); val binding = owner.bind(p); owner.attach(binding); owner.focusChanged(binding, true)
        try {
            binding.update(TextFieldValue("AMiraB", TextRange(1, 5)))
            b.moveSelection(WritingSelection(nodes = listOf(b.node(NodeAddress("p")))), NodeCollection.children(b.node(NodeAddress("t"))))
            a.receive(b.changes())
            val accepted = receipt(a)
            assertFalse("A moved native address is immediately stale before disposal", binding.current())
            binding.update(TextFieldValue("AMiraB", TextRange(5)))
            binding.update(TextFieldValue("stale text", TextRange(5)))
            assertEquals(accepted, receipt(a)); assertEquals(TextRange(1, 5), binding.input.value.selection)
            val nested = a.snapshot.getJSONArray("blocks").getJSONObject(0).getJSONArray("children").getJSONObject(0)
            assertEquals("AMiraB", plainText(nested.getJSONArray("content")))
            assertTrue(nested.getJSONArray("content").toString().contains("mira"))
        } finally { owner.close(); scope.cancel(); a.close(); b.close() }
    }

    @Test fun failedRemoteDrainRetryRebasesCommittedDraftInsteadOfDeletingPeerText() {
        val blocks = seed().put(org.json.JSONObject().put("id", "math").put("type", "math").put("expression", "x".repeat(9_999)))
        val a = WritingSession.createV4("native-drain-recovery", "a", "v4", blocks)
        val b = WritingSession.createV4("native-drain-recovery", "b", "v4", blocks)
        val scope = CoroutineScope(SupervisorJob() + Dispatcher())
        val errors = mutableListOf<Exception>()
        val owner = WritingEditorInputs(a, scope, { true }, { fail("No uncommitted draft after repair") }, { errors.add(it) })
        val p = a.node(NodeAddress("p")); val binding = owner.bind(p); owner.attach(binding); owner.focusChanged(binding, true)
        try {
            val math = WritingAddress("math", listOf("expression"))
            a.replaceText(math, 9_999, 9_999, "A")
            binding.update(TextFieldValue("XAMiraB", TextRange(1), TextRange(0, 1)))
            b.replaceText(math, 9_999, 9_999, "B")
            val peerCaret = b.replaceText(b.textAddress(b.node(NodeAddress("p"))), 6, 6, "R")
            a.receive(b.changes())
            try { owner.softBreak(binding, {}); fail("Pending over-limit remote union must suppress the command") } catch (_: WritingRecoveryException) { }
            assertEquals("XAMiraB", plainText(a.snapshot.getJSONArray("blocks").getJSONObject(0).getJSONArray("content")))
            assertFalse(a.snapshot.getJSONArray("blocks").getJSONObject(0).getJSONArray("content").toString().contains("\\n"))
            val draft = checkNotNull(binding.input.draft())
            assertEquals(MergeRecoveryReason.SCHEMA_CONSTRAINT, checkNotNull(draft.recovery).reason)
            assertEquals(4, draft.recovery!!.batch.export().getJSONArray("changes").length())
            a.repairText(a.node(NodeAddress("math")), "expression", "x".repeat(9_998) + "BA")
            val fresh = owner.bind(p); owner.attach(fresh); owner.focusChanged(fresh, true)
            owner.softBreak(fresh, {})
            assertEquals("X\nAMiraBR", plainText(a.snapshot.getJSONArray("blocks").getJSONObject(0).getJSONArray("content")))
            assertEquals(9, a.resolvePosition(peerCaret).offset)
            assertEquals("x".repeat(9_998) + "BA", a.snapshot.getJSONArray("blocks").getJSONObject(1).getString("expression"))
            val reopened = WritingSession.restore(a.save(), "a")
            try { reopened.undo(); assertEquals("XAMiraBR", plainText(reopened.snapshot.getJSONArray("blocks").getJSONObject(0).getJSONArray("content"))) }
            finally { reopened.close() }
        } finally { owner.close(); scope.cancel(); a.close(); b.close() }
    }

    @Test fun remoteDeleteRetiresFocusedOriginWithoutGuessingOrAcceptingOldCallbacks() {
        val blocks = seed().put(org.json.JSONObject("""{"id":"q","type":"paragraph","content":[{"type":"text","text":"keep"}]}"""))
        val a = WritingSession.createV4("native-deleted-address", "a", "v4", blocks)
        val b = WritingSession.createV4("native-deleted-address", "b", "v4", blocks)
        val scope = CoroutineScope(SupervisorJob() + Dispatcher())
        val owner = WritingEditorInputs(a, scope, { true }, { fail("No draft expected") }, { throw it })
        val binding = owner.bind(a.node(NodeAddress("p"))); owner.attach(binding); owner.focusChanged(binding, true)
        try {
            binding.update(TextFieldValue("AMiraB", TextRange(1, 5)))
            b.deleteSelection(WritingSelection(nodes = listOf(b.node(NodeAddress("p")))))
            a.receive(b.changes())
            assertEquals(listOf("keep"), text(a)); assertNull(owner.focusRequest)
            val accepted = receipt(a)
            assertFalse(binding.current())
            binding.update(TextFieldValue("stale native value", TextRange(0)))
            assertEquals(accepted, receipt(a)); assertEquals(TextRange(1, 5), binding.input.value.selection)
        } finally { owner.close(); scope.cancel(); a.close(); b.close() }
    }

}
