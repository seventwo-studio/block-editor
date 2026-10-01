package studio.seventwo.blockeditor

import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test

/** Typed Kotlin consumer proof, separate from the raw 2,934-response JNI transcript. */
class WritingSessionTest {
    private fun normalize(value: Any?): Any? = when (value) {
        is JSONObject -> value.keys().asSequence().associateWith { normalize(value.get(it)) }
        is JSONArray -> (0 until value.length()).map { normalize(value.get(it)) }
        JSONObject.NULL -> null
        else -> value
    }
    private fun blocks(session: WritingSession) = normalize(session.snapshot.getJSONArray("blocks"))
    private fun expected(text: String) = normalize(JSONArray("""[
        {"id":"left","type":"paragraph","content":[{"type":"text","text":"$text","marks":[]}]}
    ]"""))
    private fun error(message: String, operation: () -> Unit) {
        try { operation(); fail("Expected $message") }
        catch (failure: IllegalStateException) { assertEquals(message, failure.message) }
    }

    @Test fun splitRemoteFormattingStablePositionAndReopenedAuthorUndo() {
        val seed = JSONArray("""[{"id":"left","type":"paragraph","content":[{"type":"text","text":"abcd","marks":[]}]}]""")
        val a = WritingSession.create("typed-kotlin", "a", "v3", seed)
        val b = WritingSession.create("typed-kotlin", "b", "v3", seed)
        var reopened: WritingSession? = null
        try {
            val field = WritingAddress("left")
            val position = a.splitParagraph(field, 2, 2, "right")
            b.replaceText(field, 3, 3, "X")
            b.format(field, 2, 3, "bold", JSONObject().put("type", "bold"))
            val left = a.changes(); val right = b.changes()
            a.receive(right); b.receive(left)
            assertEquals(blocks(a), blocks(b))
            assertEquals(normalize(JSONArray("""[
                {"id":"left","type":"paragraph","content":[{"type":"text","text":"ab","marks":[]}]},
                {"id":"right","type":"paragraph","content":[{"type":"text","text":"c","marks":[{"type":"bold"}]},{"type":"text","text":"Xd","marks":[]}]}
            ]""")), blocks(a))
            val resolved = a.resolvePosition(position)
            assertEquals(normalize(a.node(NodeAddress("right")).wire), normalize(resolved.address.export().getJSONObject("identity")))
            assertEquals(listOf("content"), resolved.address.path)
            assertEquals(0, resolved.offset)
            val restored = WritingSession.restore(a.save(), "a"); reopened = restored
            restored.undo()
            assertEquals(normalize(JSONArray("""[
                {"id":"left","type":"paragraph","content":[{"type":"text","text":"ab","marks":[]},{"type":"text","text":"c","marks":[{"type":"bold"}]},{"type":"text","text":"Xd","marks":[]}]}
            ]""")), blocks(restored))
        } finally { reopened?.close(pendingStateRetained = true); a.close(pendingStateRetained = true); b.close(pendingStateRetained = true) }
    }

    @Test fun compositionQueueReentrantReceiveAndProtocolFailureRemainRecoverable() {
        val seed = JSONArray("""[{"id":"left","type":"paragraph","content":[{"type":"text","text":"ab","marks":[]}]}]""")
        val c = WritingSession.create("typed-composition", "c", "v3", seed)
        val d = WritingSession.create("typed-composition", "d", "v3", seed)
        val e = WritingSession.create("typed-composition", "e", "v3", seed)
        try {
            val field = WritingAddress("left")
            d.replaceText(field, 1, 1, "X"); e.replaceText(field, 2, 2, "Z")
            val accepted = normalize(c.save().export())
            val release = c.deferRemoteChanges(); c.receive(d.changes())
            assertEquals(accepted, normalize(c.save().export()))
            assertEquals(0, c.syncState().export().getJSONArray("received").length())
            var nextRelease: (() -> Unit)? = null
            c.onChange = { if (nextRelease == null) { nextRelease = c.deferRemoteChanges(); c.receive(e.changes()) } }
            release()
            assertEquals(1, c.exportDeferredChanges().size)
            checkNotNull(nextRelease).invoke()
            assertEquals(expected("aXbZ"), blocks(c))
            c.setComposing(true)
            error("compositionActive") { c.splitParagraph(field, 1, 1, "blocked") }
            c.setComposing(false)
            val before = normalize(c.save().export())
            val wrong = WritingBatch.restore(d.changes().export().put("epoch", "wrong"))
            val badRelease = c.deferRemoteChanges(); c.receive(wrong)
            error("incompatibleEpoch") { badRelease() }
            assertEquals(before, normalize(c.save().export()))
            val retained = c.exportDeferredChanges()
            assertEquals(1, retained.size); assertEquals("wrong", retained.single().epoch)
            try { c.close(); fail("Pending packets require explicit host retention") } catch (_: IllegalStateException) { }
            c.close(pendingStateRetained = true)
        } finally { c.close(pendingStateRetained = true); d.close(pendingStateRetained = true); e.close(pendingStateRetained = true) }
    }

    @Test fun typedRecoveryRetainsRejectedDeltaAcrossReopenAndClearsAfterCompleteHistory() {
        val seed = JSONArray("""[{"id":"left","type":"paragraph","content":[{"type":"text","text":"ab","marks":[]}]}]""")
        val a = WritingSession.create("typed-gap", "a", "v3", seed)
        val b = WritingSession.create("typed-gap", "b", "v3", seed)
        var reopened: WritingSession? = null
        try {
            val field = WritingAddress("left")
            b.replaceText(field, 1, 1, "X"); val receipt = b.syncState()
            b.replaceText(field, 1, 1, "Y")
            val accepted = a.save(); val delta = b.changes(receipt)
            val recovery = try { a.receive(delta); throw AssertionError("Missing typed writing recovery") }
                catch (failure: WritingRecoveryException) { failure.recovery }
            assertEquals(MergeRecoveryReason.SCHEMA_CONSTRAINT, recovery.reason)
            assertEquals("v3", recovery.batch.epoch)
            assertEquals(3, recovery.batch.export().getInt("version"))
            assertEquals(normalize(accepted.export()), normalize(a.save().export()))
            assertEquals(normalize(recovery.export()), normalize(checkNotNull(a.mergeRecovery()).export()))
            val restored = WritingSession.restore(accepted, "a"); reopened = restored
            val exported = WritingRecovery.restore(recovery.export())
            try { restored.restoreRecovery(exported); fail("Incomplete history must stay rejected") }
            catch (failure: WritingRecoveryException) { assertEquals(normalize(exported.export()), normalize(failure.recovery.export())) }
            assertEquals(normalize(accepted.export()), normalize(restored.save().export()))
            assertEquals(normalize(exported.export()), normalize(checkNotNull(restored.mergeRecovery()).export()))
            restored.receive(b.changes())
            assertEquals(expected("aYXb"), blocks(restored))
            assertEquals(blocks(b), blocks(restored))
            assertNull(restored.mergeRecovery())
        } finally { reopened?.close(pendingStateRetained = true); a.close(pendingStateRetained = true); b.close(pendingStateRetained = true) }
    }
}
