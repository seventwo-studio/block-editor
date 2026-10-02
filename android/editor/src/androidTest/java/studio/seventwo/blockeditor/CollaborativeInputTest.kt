package studio.seventwo.blockeditor

import androidx.compose.ui.text.TextRange
import androidx.compose.ui.text.input.TextFieldValue
import kotlinx.coroutines.CoroutineDispatcher
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.cancel
import kotlinx.coroutines.SupervisorJob
import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test
import kotlin.coroutines.CoroutineContext
import java.util.ArrayDeque

class CollaborativeInputTest {
    private class LeaseDispatcher : CoroutineDispatcher() {
        private val queued = ArrayDeque<Runnable>()
        override fun dispatch(context: CoroutineContext, block: Runnable) { queued.addLast(block) }
        fun drain() {
            var count = 0
            while (queued.isNotEmpty()) {
                check(++count <= 100) { "Input retirement did not finish" }
                queued.removeFirst().run()
            }
        }
    }

    @Test fun rememberedReplacementReservationKeepsDraftAndRemoteHoldUntilNativeAttach() {
        val a = EditorSession.create("reserved-native-attach", "a", blocks)
        val b = EditorSession.create("reserved-native-attach", "b", blocks)
        val dispatcher = LeaseDispatcher(); val scope = CoroutineScope(SupervisorJob() + dispatcher)
        val owner = EditorInputs(a, scope) { throw it }
        val old = owner.bind("p", null, NodeAddress("p", listOf("content")))
        owner.attach(old); owner.focusChanged(old, true)
        try {
            old.update(TextFieldValue("漢Hello Mira", TextRange(1), TextRange(0, 1)))
            b.setText("p", "RHello Mira"); a.receive(b.changes())
            val accepted = a.save().toString()
            // Compose remembers the replacement before its DisposableEffect can
            // attach at the next layout. Old disposal/yield may happen first.
            val replacement = owner.bind("p", null, NodeAddress("p", listOf("content")))
            replacement.onRemembered(); owner.detach(old); dispatcher.drain()
            assertSame(old.input, replacement.input)
            assertEquals("漢Hello Mira", replacement.input.value.text)
            assertEquals(TextRange(0, 1), replacement.input.value.composition)
            assertEquals(accepted, a.save().toString())
            assertEquals(0, a.syncState().getJSONArray("received").length())
            owner.attach(replacement); owner.focusChanged(replacement, true)
            assertTrue(replacement.current()); assertFalse(old.current())
            old.update(TextFieldValue("stale retired callback"))
            assertEquals("漢Hello Mira", replacement.input.value.text)
            replacement.update(replacement.input.value.copy(composition = null))
            assertEquals("R漢Hello Mira", replacement.input.value.text)
            val rich = a.snapshot.getJSONArray("blocks").getJSONObject(0).getJSONArray("content").toString()
            assertTrue(rich.contains("mira")); assertTrue(rich.contains("bold"))
            assertEquals(2, a.changes().getJSONArray("changes").length())
            a.undo(); assertEquals("RHello Mira", replacement.input.value.text)
            replacement.onForgotten(); owner.detach(replacement); dispatcher.drain()
        } finally { owner.close(); scope.cancel(); a.close(); b.close() }
    }

    @Test fun abandonedRememberReservationKeepsCurrentLeaseAndDoesNotLeakController() {
        val a = EditorSession.create("abandoned-native-attach", "a", blocks)
        val dispatcher = LeaseDispatcher(); val scope = CoroutineScope(SupervisorJob() + dispatcher)
        val owner = EditorInputs(a, scope) { throw it }
        val current = owner.bind("p", null, NodeAddress("p", listOf("content")))
        owner.attach(current)
        try {
            val abandoned = owner.bind("p", null, NodeAddress("p", listOf("content")))
            assertTrue("An unapplied remember must not revoke the rendered native lease", current.current())
            abandoned.onAbandoned(); dispatcher.drain()
            assertTrue(current.current()); assertFalse(abandoned.current())
            current.update(TextFieldValue("XHello Mira", TextRange(1)))
            assertEquals("XHello Mira", current.input.value.text)
            val accepted = a.save().toString()
            abandoned.update(TextFieldValue("abandoned callback"))
            assertEquals(accepted, a.save().toString())
            try { owner.attach(abandoned); fail("An abandoned remember must not attach") }
            catch (_: IllegalStateException) { }
            owner.detach(current); current.onForgotten(); dispatcher.drain()
            // With no applied or pending lease, the old controller is retired.
            val fresh = owner.bind("p", null, NodeAddress("p", listOf("content")))
            assertNotSame(current.input, fresh.input)
            fresh.onAbandoned(); dispatcher.drain()
            val afterAbandon = owner.bind("p", null, NodeAddress("p", listOf("content")))
            assertNotSame(fresh.input, afterAbandon.input)
            owner.attach(afterAbandon); assertTrue(afterAbandon.current())
            afterAbandon.onForgotten(); dispatcher.drain()
            assertEquals(accepted, a.save().toString())
        } finally { owner.close(); scope.cancel(); a.close() }
    }

    @Test fun pendingBindingsCannotReactivateOlderGenerationOrClosedOwner() {
        val a = EditorSession.create("pending-native-generation", "a", blocks)
        val dispatcher = LeaseDispatcher(); val scope = CoroutineScope(SupervisorJob() + dispatcher)
        val owner = EditorInputs(a, scope) { throw it }
        try {
            val first = owner.bind("p", null, NodeAddress("p", listOf("content")))
            val second = owner.bind("p", null, NodeAddress("p", listOf("content")))
            owner.attach(second); owner.attach(first)
            assertTrue(second.current()); assertFalse(first.current())
            val accepted = a.save().toString()
            first.update(TextFieldValue("stale older pending lease"))
            assertEquals(accepted, a.save().toString())
            val pending = owner.bind("p", null, NodeAddress("p", listOf("content")))
            assertTrue(second.current())
            owner.close()
            assertFalse(second.current()); assertFalse(pending.current())
            try { owner.attach(pending); fail("A closed owner cannot attach a reserved controller") }
            catch (_: IllegalStateException) { }
            pending.onAbandoned(); first.onForgotten(); second.onForgotten(); dispatcher.drain()
            second.update(TextFieldValue("closed attached callback")); pending.update(TextFieldValue("closed pending callback"))
            assertEquals(accepted, a.save().toString())
            try { owner.bind("p", null, NodeAddress("p", listOf("content"))); fail("Closed owner cannot bind") }
            catch (_: IllegalStateException) { }
        } finally { owner.close(); scope.cancel(); a.close() }
    }

    private val blocks = JSONArray("""[{"id":"p","type":"paragraph","content":[{"type":"text","text":"Hello ","marks":[{"type":"bold"}]},{"type":"mention","entityId":"mira","entityType":"user","label":"Mira"}]}]""")
    @Test fun compositionDefersRemoteApplyAndUndoPreservesRemoteText() {
        val a = EditorSession.create("input", "a", blocks)
        val b = EditorSession.create("input", "b", blocks)
        val input = CollaborativeTextInput(a, "p") { throw it }
        try {
            input.update(TextFieldValue("漢Hello Mira", TextRange(1), TextRange(0, 1)))
            b.setText("p", "RHello Mira")
            a.receive(b.changes())
            assertEquals(0, a.syncState().getJSONArray("received").length())
            assertEquals("漢Hello Mira", input.value.text)
            input.update(input.value.copy(composition = null))
            assertEquals("R漢Hello Mira", input.value.text)
            assertEquals(TextRange(2), input.value.selection)
            val nodes = a.snapshot.getJSONArray("blocks").getJSONObject(0).getJSONArray("content")
            assertTrue(nodes.toString().contains("\"entityId\":\"mira\""))
            assertTrue(nodes.toString().contains("bold"))
            a.undo()
            assertEquals("RHello Mira", input.value.text)
            b.receive(a.changes(b.syncState()))
            assertEquals(a.snapshot.getJSONArray("blocks").toString(), b.snapshot.getJSONArray("blocks").toString())
        } finally { input.close(); a.close(); b.close() }
    }
    @Test fun backwardSelectionTracksRemoteChangesAndRejectedBatches() {
        val a = EditorSession.create("selection", "a", blocks)
        val b = EditorSession.create("selection", "b", blocks)
        val input = CollaborativeTextInput(a, "p") { throw it }
        try {
            input.update(input.value.copy(selection = TextRange(10, 6)))
            try { a.receive(JSONObject(b.changes().toString()).put("version", 99)); fail("Expected rejection") }
            catch (_: IllegalStateException) { }
            input.update(input.value.copy(selection = TextRange(5, 0)))
            b.setText("p", "RHello Mira"); a.receive(b.changes())
            b.setText("p", "SRHello Mira"); a.receive(b.changes())
            assertEquals(TextRange(7, 2), input.value.selection)
        } finally { input.close(); a.close(); b.close() }
    }
    @Test fun nestedHoldsCloneMessagesAndDrainAfterInvalidBatch() {
        val a = EditorSession.create("queue", "a", blocks)
        val b = EditorSession.create("queue", "b", blocks)
        try {
            val first = a.deferRemoteChanges(); val second = a.deferRemoteChanges()
            b.setText("p", "RHello Mira")
            val batch = b.changes()
            a.receive(JSONObject(batch.toString()).put("version", 99)); a.receive(batch)
            batch.put("changes", JSONArray())
            first(); assertEquals(0, a.syncState().getJSONArray("received").length())
            try { second(); fail("Expected rejection") } catch (_: IllegalStateException) { }
            second()
            assertEquals(1, a.syncState().getJSONArray("received").length())
            assertEquals("RHello Mira", plainText(a.snapshot.getJSONArray("blocks").getJSONObject(0).getJSONArray("content")))
        } finally { a.close(); b.close() }
    }
    @Test fun disposingComposingInputReleasesSession() {
        val a = EditorSession.create("dispose", "a", blocks)
        val b = EditorSession.create("dispose", "b", blocks)
        val input = CollaborativeTextInput(a, "p") { throw it }
        try {
            input.update(TextFieldValue("漢Hello Mira", TextRange(1), TextRange(0, 1)))
            b.setText("p", "RHello Mira"); a.receive(b.changes())
            input.close()
            input.update(TextFieldValue("late callback"))
            assertEquals(1, a.syncState().getJSONArray("received").length())
            assertEquals("RHello Mira", plainText(a.snapshot.getJSONArray("blocks").getJSONObject(0).getJSONArray("content")))
        } finally { input.close(); a.close(); b.close() }
    }
    @Test fun finalChangedNativeValueRetainsDraftAndRemoteHoldBeforeHistory() {
        val a = EditorSession.create("native-final-draft", "a", blocks)
        val b = EditorSession.create("native-final-draft", "b", blocks)
        val input = CollaborativeTextInput(a, "p") { throw it }
        try {
            val accepted = a.save().toString()
            input.update(input.value.copy(composition = TextRange(0, 1)))
            b.setText("p", "RHello Mira"); a.receive(b.changes())
            try {
                input.finishUnchangedComposition {
                    // A synchronous final native correction is a real draft;
                    // no history action may run over or discard it.
                    input.update(TextFieldValue("XHello Mira", TextRange(1)))
                }
                fail("Changed final native text must require explicit commit")
            } catch (_: IllegalStateException) { }
            assertEquals(accepted, a.save().toString())
            assertEquals("XHello Mira", input.value.text)
            assertTrue(input.requiresCommit)
            assertEquals(0, a.syncState().getJSONArray("received").length())
            input.update(input.value.copy(composition = null))
            assertEquals("RXHello Mira", input.value.text)
            val rich = a.snapshot.getJSONArray("blocks").getJSONObject(0).getJSONArray("content").toString()
            assertTrue(rich.contains("mira")); assertTrue(rich.contains("bold"))
            a.undo()
            assertEquals("RHello Mira", input.value.text)
        } finally { input.close(); a.close(); b.close() }
    }

    @Test fun failedRemoteDrainSuppressesHistoryWithoutFabricatingAnEdit() {
        val a = EditorSession.create("native-final-drain", "a", blocks)
        val b = EditorSession.create("native-final-drain", "b", blocks)
        val input = CollaborativeTextInput(a, "p") { throw it }
        try {
            input.update(input.value.copy(composition = TextRange(0, 1)))
            b.setText("p", "RHello Mira")
            a.receive(JSONObject(b.changes().toString()).put("version", 99))
            a.receive(b.changes())
            var historyRan = false
            try {
                input.finishUnchangedComposition { }
                historyRan = true; a.undo()
                fail("Rejected held batch must reach the history owner")
            } catch (_: IllegalStateException) { }
            assertFalse(historyRan)
            assertFalse(input.requiresCommit)
            assertEquals("RHello Mira", input.value.text)
            assertEquals(1, a.syncState().getJSONArray("received").length())
            assertEquals(1, a.changes().getJSONArray("changes").length())
            assertFalse(a.snapshot.getBoolean("canUndo"))
            val rich = a.snapshot.getJSONArray("blocks").getJSONObject(0).getJSONArray("content").toString()
            assertTrue(rich.contains("mira")); assertTrue(rich.contains("bold"))
        } finally { input.close(); a.close(); b.close() }
    }

    @Test fun historyOwnerRejectsMultipleAndChangedDraftsBeforeNativeRevocation() {
        val a = EditorSession.create("history-owner", "a", JSONArray("""[{"id":"p","type":"paragraph","content":[{"type":"text","text":"P","marks":[]}]},{"id":"q","type":"paragraph","content":[{"type":"text","text":"Q","marks":[]}]}]"""))
        val owner = EditorInputs(a, CoroutineScope(SupervisorJob())) { throw it }
        val p = owner.bind("p", null, NodeAddress("p", listOf("content")))
        val q = owner.bind("q", null, NodeAddress("q", listOf("content")))
        owner.attach(p); owner.attach(q); owner.focusChanged(p, true)
        try {
            val accepted = a.save().toString()
            p.update(p.input.value.copy(composition = TextRange(0, 1)))
            q.update(q.input.value.copy(composition = TextRange(0, 1)))
            var revoked = false; var acted = false
            assertFalse(owner.canPerformHistory())
            try { owner.performHistory({ revoked = true }) { acted = true }; fail("Multiple drafts must block history") }
            catch (_: IllegalStateException) { }
            assertFalse(revoked); assertFalse(acted); assertEquals(accepted, a.save().toString())
            q.update(q.input.value.copy(composition = null))
            p.update(TextFieldValue("draftP", TextRange(5), TextRange(0, 5)))
            assertFalse(owner.canPerformHistory())
            try { owner.performHistory({ revoked = true }) { acted = true }; fail("Changed draft must block history") }
            catch (_: IllegalStateException) { }
            assertFalse(revoked); assertFalse(acted); assertEquals(accepted, a.save().toString())
            assertEquals("draftP", p.input.value.text)
            owner.close()
            assertFalse(owner.canPerformHistory())
            try { owner.performHistory({ revoked = true }) { acted = true }; fail("Disposed input owner must reject retained history") }
            catch (_: IllegalStateException) { }
            assertFalse(revoked); assertFalse(acted); assertEquals(accepted, a.save().toString())
        } finally { owner.close(); a.close() }
    }

    @Test fun onlyImmediatelyCurrentLeaseCanDeliverFinalNativeValue() {
        val blocks = JSONArray("""[{"id":"p","type":"paragraph","content":[{"type":"text","text":"P","marks":[]}]}]""")
        val a = EditorSession.create("final-native-lease", "a", blocks)
        val b = EditorSession.create("final-native-lease", "b", blocks)
        val owner = EditorInputs(a, CoroutineScope(SupervisorJob())) { throw it }
        val old = owner.bind("p", null, NodeAddress("p", listOf("content")))
        owner.attach(old)
        val current = owner.bind("p", null, NodeAddress("p", listOf("content")))
        owner.attach(current); owner.focusChanged(current, true)
        try {
            val accepted = a.save().toString()
            current.update(current.input.value.copy(composition = TextRange(0, 1)))
            b.setText("p", "BP"); a.receive(b.changes())
            var acted = false
            try {
                owner.performHistory({
                    old.update(TextFieldValue("stale old lease"))
                    assertEquals("Older attached generation must stay revoked during native finish", "P", current.input.value.text)
                    current.update(TextFieldValue("XP", TextRange(1)))
                    assertEquals("Immediately current native correction must be retained", "XP", current.input.value.text)
                }) { acted = true }
                fail("Final changed native value must block history")
            } catch (_: IllegalStateException) { }
            assertFalse(acted); assertEquals(accepted, a.save().toString())
            assertEquals(0, a.syncState().getJSONArray("received").length())
            assertTrue(current.input.requiresCommit)
            current.update(TextFieldValue("late current lease"))
            old.update(TextFieldValue("late old lease"))
            assertEquals("XP", current.input.value.text)
            val fresh = owner.bind("p", null, NodeAddress("p", listOf("content")))
            owner.attach(fresh); owner.focusChanged(fresh, true)
            fresh.update(fresh.input.value.copy(composition = null))
            assertEquals("BXP", fresh.input.value.text)
            // Receipts include accepted local history as well as drained peers.
            val received = a.syncState().getJSONArray("received")
            val identities = (0 until received.length()).map { index ->
                val id = received.getJSONObject(index)
                id.getLong("counter") to id.getString("actor")
            }
            assertEquals(setOf(1L to "a", 1L to "b"), identities.toSet())
            assertEquals("No duplicate accepted receipts", identities.size, identities.toSet().size)
        } finally { owner.close(); a.close(); b.close() }
    }

}
