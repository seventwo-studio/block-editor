package studio.seventwo.blockeditor

import androidx.test.platform.app.InstrumentationRegistry
import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test

/** Actual typed JNI calls use the independently authored shared literal oracle. */
class WritingPasteSixTest {
    private fun normalize(value: Any?): Any? = when (value) {
        is JSONObject -> value.keys().asSequence().associateWith { normalize(value.get(it)) }
        is JSONArray -> (0 until value.length()).map { normalize(value.get(it)) }
        JSONObject.NULL -> null
        else -> value
    }
    private fun blocks(session: WritingSession) = normalize(session.snapshot.getJSONArray("blocks"))
    private fun error(expected: String, operation: () -> Unit) {
        try { operation(); fail("Expected $expected") }
        catch (failure: IllegalStateException) { assertEquals(expected, failure.message) }
    }

    @Test fun typedV6PasteRetainsBoundaryOwnersAcrossNestedCollectionsAndRemoteHistory() {
        val fixture = JSONObject(InstrumentationRegistry.getInstrumentation().context.assets.open("paste6Commands.json").bufferedReader().use { it.readText() })
        val cases = fixture.getJSONArray("typedCases")
        val expected = fixture.getJSONObject("expectedBlocks")
        for (index in 0 until cases.length()) {
            val sample = cases.getJSONObject(index)
            val actor = sample.getString("actor")
            val document = "typed-${sample.getString("id")}"; val epoch = "six"
            val a = WritingSession.createV6(document, actor, epoch, sample.getJSONArray("blocks"))
            val b = WritingSession.createV6(document, "m", epoch, sample.getJSONArray("blocks"))
            var reopened: WritingSession? = null
            var old: WritingSession? = null
            try {
                fun address(name: String): WritingAddress {
                    val value = sample.getJSONObject(name); val path = value.getJSONArray("path")
                    return WritingAddress(value.getString("blockID"), (0 until path.length()).map { path.getString(it) })
                }
                val start = address("start"); val end = address("end")
                val owner = a.node(NodeAddress(end.blockID, end.path.dropLast(1)))
                val range = WritingTextRange(a.position(start, 1), a.position(end, 4))
                val clipboard = WritingClipboard.restore(sample.getJSONObject("clipboard"))
                a.setComposing(true)
                val held = normalize(a.save().export()); val heldReceipt = normalize(a.syncState().export())
                error("compositionActive") { a.pasteSelection(clipboard, range) }
                assertEquals(held, normalize(a.save().export())); assertEquals(heldReceipt, normalize(a.syncState().export()))
                a.setComposing(false)
                val caret = a.pasteSelection(clipboard, range)
                assertEquals(1, a.changes().export().getJSONArray("changes").length())
                if (sample.getString("kind") == "enter") b.enterListItem(start, 1, 1, "tail")
                else b.replaceText(end, 6, 6, "R")
                val own = a.changes(); val peer = b.changes()
                if (sample.getBoolean("reversedDelivery")) { b.receive(own); a.receive(peer) }
                else { a.receive(peer); b.receive(own) }
                a.receive(peer); b.receive(own)
                val accepted = normalize(expected.getJSONArray(sample.getString("accepted")))
                assertEquals(accepted, blocks(a)); assertEquals(accepted, blocks(b)); assertNull(a.mergeRecovery())
                assertEquals(normalize(owner.wire), normalize(a.node(NodeAddress(end.blockID, end.path.dropLast(1))).wire))
                assertEquals(sample.getInt("caretOffset"), a.resolvePosition(caret).offset)
                val restored = WritingSession.restore(a.save(), actor); reopened = restored
                assertEquals(accepted, blocks(restored))
                restored.undo(); b.receive(restored.changes())
                val undo = normalize(expected.getJSONArray(sample.getString("undo")))
                assertEquals(undo, blocks(restored)); assertEquals(undo, blocks(b))
                restored.redo(); b.receive(restored.changes()); b.receive(restored.changes())
                assertEquals(accepted, blocks(restored)); assertEquals(accepted, blocks(b))
                val five = WritingSession.createV5(document, "old", epoch, sample.getJSONArray("blocks")); old = five
                val before = normalize(five.save().export()); val receipt = normalize(five.syncState().export())
                error("unsupportedVersion(6)") { five.receive(restored.changes()) }
                error("unsupportedVersion(5)") { restored.receive(five.changes()) }
                assertEquals(before, normalize(five.save().export())); assertEquals(receipt, normalize(five.syncState().export()))
                assertEquals(accepted, blocks(restored)); assertNull(five.mergeRecovery()); assertNull(restored.mergeRecovery())
            } finally { a.close(); b.close(); reopened?.close(); old?.close() }
        }
    }
}
