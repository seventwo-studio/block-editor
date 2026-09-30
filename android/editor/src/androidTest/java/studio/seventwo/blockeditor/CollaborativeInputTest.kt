package studio.seventwo.blockeditor

import androidx.compose.ui.text.TextRange
import androidx.compose.ui.text.input.TextFieldValue
import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test

class CollaborativeInputTest {
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
            assertEquals(1, a.syncState().getJSONArray("received").length())
            assertEquals("RHello Mira", plainText(a.snapshot.getJSONArray("blocks").getJSONObject(0).getJSONArray("content")))
        } finally { input.close(); a.close(); b.close() }
    }
}
