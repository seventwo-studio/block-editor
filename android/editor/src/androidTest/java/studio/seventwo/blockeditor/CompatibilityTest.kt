package studio.seventwo.blockeditor

import androidx.test.platform.app.InstrumentationRegistry
import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.fail
import org.junit.Test

/** Runs the same JSON commands and expected document as Swift and browser WASM. */
class CompatibilityTest {
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
    private fun normalize(value: Any?): Any? = when (value) {
        is JSONObject -> value.keys().asSequence().associateWith { normalize(value.get(it)) }
        is JSONArray -> (0 until value.length()).map { normalize(value.get(it)) }
        JSONObject.NULL -> null
        else -> value
    }
}
