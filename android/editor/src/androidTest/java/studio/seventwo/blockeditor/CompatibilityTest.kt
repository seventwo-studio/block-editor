package studio.seventwo.blockeditor

import androidx.test.platform.app.InstrumentationRegistry
import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.fail
import org.junit.Test

/** Runs the same JSON commands and expected document as Swift and browser WASM. */
class CompatibilityTest {
    @Test fun stablePositionsFollowRemoteEditsAndUndo() {
        val blocks = JSONArray("""[{"id":"p","type":"paragraph","content":[{"type":"text","text":"A😀BC","marks":[]}]}]""")
        val a = EditorSession.create("positions", "a", blocks)
        val b = EditorSession.create("positions", "b", blocks)
        try {
            val position = a.position("p", 3)
            b.setText("p", "!A😀BC"); a.receive(b.changes())
            assertEquals(4, a.resolvePosition(position))
            b.setText("p", "!ABC"); a.receive(b.changes())
            assertEquals(2, a.resolvePosition(position))
            val restored = EditorSession.restore(a.save(), "a")
            try { assertEquals(2, restored.resolvePosition(JSONObject(position.toString()))) }
            finally { restored.close() }
            b.undo(); a.receive(b.changes())
            assertEquals(4, a.resolvePosition(position))
        } finally { a.close(); b.close() }
    }
    @Test fun concurrentFormattingAndAuthorUndo() {
        val blocks = JSONArray("""[{"id":"p","type":"paragraph","content":[{"type":"text","text":"ABC","marks":[]}]}]""")
        val a = EditorSession.create("marks", "a", blocks)
        val b = EditorSession.create("marks", "b", blocks)
        fun range(start: Int, end: Int) = JSONObject().put("address", JSONObject().put("blockID", "p").put("path", JSONArray().put("content")))
            .put("start", start).put("end", end)
        fun assertContent(session: EditorSession, expected: String) = assertEquals(normalize(JSONArray(expected)),
            normalize(session.snapshot.getJSONArray("blocks").getJSONObject(0).getJSONArray("content")))
        val combined = """[{"type":"text","text":"A","marks":[{"type":"bold"},{"type":"italic"}]},{"type":"text","text":"😀","marks":[{"type":"italic"}]},{"type":"text","text":"BC","marks":[{"type":"bold"},{"type":"italic"}]}]"""
        try {
            a.edit("format", range(0, 3).put("markType", "bold").put("mark", JSONObject().put("type", "bold")))
            b.edit("replaceText", range(1, 1).put("text", "😀"))
            b.edit("format", range(0, 5).put("markType", "italic").put("mark", JSONObject().put("type", "italic")))
            val batch = b.changes()
            val changes = batch.getJSONArray("changes")
            for (index in changes.length() - 1 downTo 0) {
                val change = changes.getJSONObject(index)
                a.receive(JSONObject(batch.toString()).put("changes", JSONArray().put(change).put(change)))
            }
            b.receive(a.changes()); assertContent(b, combined)
            a.undo(); b.receive(a.changes())
            assertContent(b, """[{"type":"text","text":"A😀BC","marks":[{"type":"italic"}]}]""")
            a.redo(); b.receive(a.changes()); assertContent(b, combined)
            b.undo(); a.receive(b.changes())
            assertContent(a, """[{"type":"text","text":"A","marks":[{"type":"bold"}]},{"type":"text","text":"😀","marks":[]},{"type":"text","text":"BC","marks":[{"type":"bold"}]}]""")
        } finally { a.close(); b.close() }
    }
    @Test fun documentMigrationCorpus() {
        val context = InstrumentationRegistry.getInstrumentation().context
        val corpus = JSONObject(context.assets.open("documents.json").bufferedReader().use { it.readText() })
        val valid = corpus.getJSONArray("valid")
        for (index in 0 until valid.length()) {
            val sample = valid.getJSONObject(index)
            val editor = EditorSession.create(sample.getString("name"), "local", sample.getJSONArray("blocks"))
            try {
                val restored = EditorSession.restore(editor.save(), "local")
                try { assertEquals(normalize(sample.getJSONArray("blocks")), normalize(restored.snapshot.getJSONArray("blocks"))) }
                finally { restored.close() }
            } finally { editor.close() }
        }
        val invalid = corpus.getJSONArray("invalid")
        for (index in 0 until invalid.length()) {
            val sample = invalid.getJSONObject(index)
            try {
                EditorSession.create(sample.getString("name"), "local", sample.getJSONArray("blocks")).close()
                fail("Invalid document accepted: ${sample.getString("name")}")
            } catch (_: IllegalStateException) { }
        }
    }
    @Test fun sharedBridgeFixture() {
        val context = InstrumentationRegistry.getInstrumentation().context
        val fixture = JSONObject(context.assets.open("bridge.json").bufferedReader().use { it.readText() })
        val requests = fixture.getJSONArray("requests")
        var result = JSONObject()
        try {
            for (index in 0 until requests.length()) result = NativeEngine.call(requests.getJSONObject(index)).getJSONObject("value")
            assertEquals(normalize(fixture.getJSONObject("expected")), normalize(result))
        } finally {
            NativeEngine.call(JSONObject().put("command", "close").put("session", "fixture"))
        }
    }
    @Test fun sharedStructureFixture() {
        val context = InstrumentationRegistry.getInstrumentation().context
        val fixture = JSONObject(context.assets.open("structure.json").bufferedReader().use { it.readText() })
        val steps = fixture.getJSONArray("steps")
        val captured = mutableMapOf<String, Any>()
        try {
            for (index in 0 until steps.length()) {
                val step = steps.getJSONObject(index)
                val request = JSONObject(step.getJSONObject("request").toString())
                val bindings = step.optJSONObject("bindings")
                bindings?.keys()?.forEach { key -> request.put(key, checkNotNull(captured[bindings.getString(key)])) }
                val value = NativeEngine.call(request).get("value")
                if (step.has("capture")) captured[step.getString("capture")] = value
            }
            assertEquals(normalize(fixture.getJSONObject("expected")), normalize(captured["final"]))
            assertEquals(fixture.getInt("expectedPosition"), (captured["resolvedPosition"] as Number).toInt())
            assertEquals(normalize(fixture.getJSONObject("expectedCutover")), normalize(captured["cutover"]))
            assertEquals(2, (captured["cutoverChanges"] as JSONObject).getInt("version"))
        } finally {
            for (handle in listOf("a", "b", "c", "legacy", "upgraded")) {
                try { NativeEngine.call(JSONObject().put("command", "close").put("session", handle)) } catch (_: Exception) { }
            }
        }
    }
    @Test fun typedNodeApiPreservesRemoteTextThroughUndoAndRestart() {
        val a = EditorSession.create("typed-nodes", "a", collaborationVersion = 2)
        val b = EditorSession.create("typed-nodes", "b", collaborationVersion = 2)
        try {
            val node = a.insertNode(JSONObject("""{"id":"p","type":"paragraph","content":[{"type":"text","text":"local","marks":[]}]}"""), NodeCollection.ROOT)
            b.receive(a.changes()); b.setText(node, "localREMOTE")
            a.undo(); a.receive(b.changes()); b.receive(a.changes())
            val restored = EditorSession.restore(a.save(), "observer")
            try {
                assertEquals(NodeAddress("p"), restored.nodeAddress(node))
                assertEquals(1, restored.nodes(NodeCollection.ROOT).size)
                assertEquals("REMOTE", restored.snapshot.getJSONArray("blocks").getJSONObject(0).getJSONArray("content").getJSONObject(0).getString("text"))
                assertEquals(normalize(a.snapshot.getJSONArray("blocks")), normalize(b.snapshot.getJSONArray("blocks")))
            } finally { restored.close() }
        } finally { a.close(); b.close() }
    }
    private fun normalize(value: Any?): Any? = when (value) {
        is JSONObject -> value.keys().asSequence().associateWith { normalize(value.get(it)) }
        is JSONArray -> (0 until value.length()).map { normalize(value.get(it)) }
        JSONObject.NULL -> null
        else -> value
    }
}
