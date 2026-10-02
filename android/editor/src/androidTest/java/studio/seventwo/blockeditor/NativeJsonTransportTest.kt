package studio.seventwo.blockeditor

import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertSame
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test

class NativeJsonTransportTest {
    private fun normalized(value: Any?): Any? = when (value) {
        is JSONObject -> value.keys().asSequence().associateWith { normalized(value.get(it)) }
        is JSONArray -> (0 until value.length()).map { normalized(value.get(it)) }
        JSONObject.NULL -> null
        else -> value
    }

    @Test fun preservesNumbersStringsNullAndContainerOrder() {
        val source = JSONObject("""{"int":2147483647,"long":2147483648,"precise":9007199254740993,"max":9223372036854775807,"min":-9223372036854775808,"fraction":1.25,"exponent":1e3,"zero":-0.0,"quoted":"9007199254740993","null":null,"array":[null,true,false,{},[],""],"unicode":"東京😀é"}""")
        source.put("escapes", "\"\\/\b\u000C\n\r\t\u0000\u001F\u2028\u2029")
        val oldEncoded = checkNotNull(source.toString()).toByteArray(Charsets.UTF_8)
        val expected = JSONObject(oldEncoded.toString(Charsets.UTF_8))
        val decoded = NativeJsonTransport.decode(NativeJsonTransport.encode(source))
        assertEquals(normalized(expected), normalized(decoded))
        assertEquals(expected.keys().asSequence().toList(), decoded.keys().asSequence().toList())
        for (key in listOf("int", "long", "precise", "max", "min", "fraction", "exponent", "zero"))
            assertEquals(key, expected.get(key).javaClass, decoded.get(key).javaClass)
        assertEquals(9007199254740993L, decoded.getLong("precise"))
        assertEquals("9007199254740993", decoded.getString("quoted"))
        assertSame(JSONObject.NULL, decoded.get("null"))
        assertEquals("\"\\/\b\u000C\n\r\t\u0000\u001F\u2028\u2029", decoded.getString("escapes"))
    }

    @Test fun streamsWithoutCallingWholeContainerToStringAtLegalEnvelopeDepth() {
        val root = object : JSONObject() {
            override fun toString(): String = error("Whole request serialization is forbidden")
        }
        var current: JSONObject = root
        repeat(52) {
            val child = JSONObject()
            current.put("child", JSONArray().put(child))
            current = child
        }
        // Cross several encoder-buffer boundaries, including a surrogate pair.
        val text = "a".repeat(8191) + "😀東京" + "é".repeat(400_000)
        current.put("opaque", text).put("empty", JSONObject()).put("array", JSONArray())
        val decoded = NativeJsonTransport.decode(NativeJsonTransport.encode(root))
        var leaf = decoded
        repeat(52) { leaf = leaf.getJSONArray("child").getJSONObject(0) }
        assertEquals(text, leaf.getString("opaque"))
        assertEquals(0, leaf.getJSONObject("empty").length())
        assertEquals(0, leaf.getJSONArray("array").length())
    }

    @Test fun defensiveCopiesIsolateEveryContainerAndFreezeMutableNumbers() {
        class MutableNumber(var value: Int) : Number() {
            override fun toString() = value.toString()
            override fun toByte() = value.toByte()
            override fun toShort() = value.toShort()
            override fun toInt() = value
            override fun toLong() = value.toLong()
            override fun toFloat() = value.toFloat()
            override fun toDouble() = value.toDouble()
        }
        val mutable = MutableNumber(7)
        val text = "opaque 東京😀"
        val shared = JSONObject().put("text", text).put("number", mutable).put("null", JSONObject.NULL)
        val source = JSONObject().put("left", shared).put("right", shared).put("array", JSONArray().put(shared))
        val expected = JSONObject(source.toString())
        val copied = NativeJsonTransport.copy(source)
        assertEquals(normalized(expected), normalized(copied))
        assertSame(text, copied.getJSONObject("left").get("text"))
        mutable.value = 99
        shared.put("text", "changed")
        copied.getJSONObject("left").put("text", "left only")
        copied.getJSONArray("array").getJSONObject(0).put("new", true)
        assertEquals(text, copied.getJSONObject("right").getString("text"))
        assertEquals(7, copied.getJSONObject("right").getInt("number"))
        assertFalse(shared.has("new"))
        assertFalse(copied.getJSONObject("right").has("new"))
        assertSame(JSONObject.NULL, copied.getJSONObject("right").get("null"))

        val batchSource = JSONObject().put("version", 6).put("epoch", "e").put("documentID", "d")
            .put("changes", JSONArray().put(JSONObject().put("opaque", shared)))
        val batch = WritingBatch.restore(batchSource)
        batchSource.getJSONArray("changes").getJSONObject(0).put("bad", true)
        val exported = batch.export()
        exported.getJSONArray("changes").getJSONObject(0).put("export mutation", true)
        assertFalse(batch.export().getJSONArray("changes").getJSONObject(0).has("bad"))
        assertFalse(batch.export().getJSONArray("changes").getJSONObject(0).has("export mutation"))
        val recoverySource = JSONObject().put("reason", "schemaConstraint").put("batch", batchSource)
        val writingRecovery = WritingRecovery.restore(recoverySource)
        val mergeRecovery = MergeRecovery.restore(recoverySource)
        recoverySource.getJSONObject("batch").put("external", true)
        writingRecovery.export().getJSONObject("batch").put("export", true)
        mergeRecovery.export().getJSONObject("batch").put("export", true)
        for (recovery in listOf(writingRecovery.export(), mergeRecovery.export())) {
            assertFalse(recovery.getJSONObject("batch").has("external"))
            assertFalse(recovery.getJSONObject("batch").has("export"))
        }
    }

    @Test fun readerRejectsInvalidResponsesAndDoesNotSubstituteStringsOrNull() {
        for (invalid in listOf("[]", "{}{}", "{\"x\":", "{\"x\":undefined}", "{'x':1}")) {
            try {
                NativeJsonTransport.decode(invalid.toByteArray(Charsets.UTF_8))
                fail("Expected invalid response: $invalid")
            } catch (_: Exception) { }
        }
        val value = NativeJsonTransport.decode("{\"number\":1e3,\"string\":\"1e3\",\"null\":null,\"word\":\"null\"}".toByteArray())
        assertTrue(value.get("number") is Double)
        assertTrue(value.get("string") is String)
        assertEquals("null", value.getString("word"))
        assertSame(JSONObject.NULL, value.get("null"))
    }

    @Test fun packagedJniPreservesRichOpaquePayloadAcrossEverySupportedEpoch() {
        for (version in 1..6) {
            val session = "json-transport-$version"
            val rich = JSONArray().put(JSONObject().put("type", "text").put("text", "東京😀")
                .put("marks", JSONArray().put(JSONObject().put("type", "bold"))))
            val opaque = JSONObject().put("counter", 2147483648L).put("quoted", "2147483648")
                .put("null", JSONObject.NULL).put("array", JSONArray().put(false).put(JSONObject()))
            val blocks = JSONArray().put(JSONObject().put("id", "p").put("type", "paragraph")
                .put("content", rich).put("consumer", opaque))
            try {
                val response = NativeEngine.call(JSONObject().put("command", "create").put("session", session)
                    .put("documentID", "transport-$version").put("actorID", "a")
                    .put("epoch", "json-v$version").put("collaborationVersion", version).put("blocks", blocks))
                assertEquals(normalized(blocks), normalized(response.getJSONObject("value").getJSONArray("blocks")))
            } finally {
                NativeEngine.call(JSONObject().put("command", "close").put("session", session))
            }
        }
    }
}
