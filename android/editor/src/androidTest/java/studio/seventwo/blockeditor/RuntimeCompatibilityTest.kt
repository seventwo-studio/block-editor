package studio.seventwo.blockeditor

import android.os.Build
import androidx.test.platform.app.InstrumentationRegistry
import java.io.File
import java.security.MessageDigest
import java.util.zip.ZipFile
import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/** Publishes actual packaged-JNI responses for comparison with Swift and WASM. */
class RuntimeCompatibilityTest {
    private fun normalize(value: Any?): Any? = when (value) {
        is JSONObject -> value.keys().asSequence().associateWith { normalize(value.get(it)) }
        is JSONArray -> (0 until value.length()).map { normalize(value.get(it)) }
        JSONObject.NULL -> null
        else -> value
    }

    @Test fun publishSharedRuntimeResponses() {
        val instrumentation = InstrumentationRegistry.getInstrumentation()
        val context = instrumentation.context
        val output = File(context.filesDir, "compatibility").apply { mkdirs() }
        val fixtureHashes = JSONObject()
        val responseFiles = linkedMapOf<String, File>()
        fun writeReport() {
            File(output, "android.json").bufferedWriter().use { writer ->
                writer.append("{\"version\":1,\"fixtureHashes\":").append(fixtureHashes.toString()).append(",\"fixtures\":{")
                responseFiles.entries.forEachIndexed { index, (name, file) ->
                    if (index > 0) writer.append(',')
                    writer.append(JSONObject.quote(name)).append(":{\"responses\":")
                    file.bufferedReader().use { it.copyTo(writer) }
                    writer.append('}')
                }
                writer.append("}}")
            }
        }
        val sessions = mutableSetOf<String>()
        fun call(input: JSONObject): JSONObject {
            val handle = input.optString("session")
            val response = try { NativeEngine.call(input) }
            catch (error: WritingRecoveryException) {
                JSONObject().put("ok", false).put("error", "writingRecoveryRequired").put("recovery", error.recovery.export())
            } catch (error: MergeRecoveryException) {
                JSONObject().put("ok", false).put("error", "mergeRecoveryRequired").put("recovery", error.recovery.export())
            } catch (error: IllegalStateException) {
                JSONObject().put("ok", false).put("error", error.message)
            }
            if (response.getBoolean("ok") && input.getString("command") in listOf("create", "restore", "cutoverToV2", "cutoverToV3")) sessions.add(handle)
            if (response.getBoolean("ok") && input.getString("command") == "close") sessions.remove(handle)
            return response
        }
        for (name in listOf("bridge", "structure", "recovery", "documents", "writing", "blockCommands", "schemaCommands", "roleCommands", "collectionCommands", "exitCommands", "pinCommands", "boundaryCommands", "undoRecoveryCommands")) {
            val bytes = context.assets.open("$name.json").use { it.readBytes() }
            fixtureHashes.put(name, MessageDigest.getInstance("SHA-256").digest(bytes).joinToString("") { "%02x".format(it) })
            val fixture = JSONObject(bytes.toString(Charsets.UTF_8))
            val responseFile = File(output, "$name-responses.json")
            val responseWriter = responseFile.bufferedWriter().apply { append('[') }
            var responseCount = 0
            var lastResponse: JSONObject? = null
            fun record(response: JSONObject) {
                if (responseCount++ > 0) responseWriter.append(',')
                responseWriter.append(response.toString())
                lastResponse = response
            }
            val captured = mutableMapOf<String, Any>()
            fun request(input: JSONObject, expectedError: String? = null): JSONObject {
                val response = call(input)
                record(response)
                assertEquals("$name response ${responseCount - 1}", expectedError == null, response.getBoolean("ok"))
                if (expectedError != null) assertEquals(expectedError, response.getString("error"))
                return response
            }
            try {
                when (name) {
                    "documents" -> {
                        val valid = fixture.getJSONArray("valid")
                        for (index in 0 until valid.length()) {
                            val sample = valid.getJSONObject(index)
                            val session = "corpus-$index"
                            request(JSONObject().put("command", "create").put("session", session).put("documentID", sample.getString("name"))
                                .put("actorID", "local").put("blocks", sample.getJSONArray("blocks")))
                            val saved = request(JSONObject().put("command", "save").put("session", session))
                            val opened = request(JSONObject().put("command", "restore").put("session", "$session-restored")
                                .put("actorID", "local").put("snapshot", saved.get("value")))
                            assertEquals(normalize(sample.getJSONArray("blocks")), normalize(opened.getJSONObject("value").getJSONArray("blocks")))
                            request(JSONObject().put("command", "close").put("session", session))
                            request(JSONObject().put("command", "close").put("session", "$session-restored"))
                        }
                        val invalid = fixture.getJSONArray("invalid")
                        for (index in 0 until invalid.length()) {
                            val sample = invalid.getJSONObject(index)
                            val response = call(JSONObject().put("command", "create").put("session", "invalid-$index")
                                .put("documentID", sample.getString("name")).put("actorID", "local").put("blocks", sample.getJSONArray("blocks")))
                            record(response)
                            assertEquals(false, response.getBoolean("ok"))
                            assertTrue(response.getString("error").isNotEmpty())
                        }
                    }
                    "bridge" -> {
                        val inputs = fixture.getJSONArray("requests")
                        for (index in 0 until inputs.length()) request(inputs.getJSONObject(index))
                        assertEquals(normalize(fixture.get("expected")), normalize(checkNotNull(lastResponse).get("value")))
                    }
                    else -> {
                        val steps = fixture.getJSONArray("steps")
                        for (index in 0 until steps.length()) {
                            val step = steps.getJSONObject(index)
                            val input = JSONObject(step.getJSONObject("request").toString())
                            val bindings = step.optJSONObject("bindings")
                            bindings?.keys()?.forEach { key ->
                                val binding = bindings.get(key)
                                val path = if (binding is JSONArray) (0 until binding.length()).map { binding.getString(it) } else listOf(binding as String)
                                var value = checkNotNull(captured[path.first()])
                                path.drop(1).forEach { value = (value as JSONObject).get(it) }
                                input.put(key, value)
                            }
                            val response = request(input, if (step.has("error")) step.getString("error") else null)
                            if (step.has("capture")) captured[step.getString("capture")] = response.get(if (step.has("error")) "recovery" else "value")
                        }
                        val pairs = fixture.optJSONArray("equal")
                        if (pairs != null) for (index in 0 until pairs.length()) {
                            val pair = pairs.getJSONArray(index)
                            assertEquals(normalize(checkNotNull(captured[pair.getString(0)])), normalize(checkNotNull(captured[pair.getString(1)])))
                        }
                        val expectedBlocks = fixture.optJSONObject("expectedBlocks")
                        expectedBlocks?.keys()?.forEach { capture ->
                            val actual = checkNotNull(captured[capture]) as JSONObject
                            assertEquals("$name $capture preserved document", normalize(expectedBlocks.get(capture)), normalize(actual.getJSONArray("blocks")))
                        }
                        if (name == "structure") {
                            assertEquals(normalize(fixture.get("expected")), normalize(captured["final"]))
                            assertEquals(fixture.getInt("expectedPosition"), (captured["resolvedPosition"] as Number).toInt())
                            assertEquals(normalize(fixture.get("expectedCutover")), normalize(captured["cutover"]))
                            assertEquals(2, (captured["cutoverChanges"] as JSONObject).getInt("version"))
                        } else if (name == "recovery") {
                            assertEquals(JSONObject.NULL, captured["cleared"])
                            assertEquals("identityConflict", (captured["proposalA"] as JSONObject).getString("reason"))
                            assertEquals(2, (captured["proposalA"] as JSONObject).getJSONObject("batch").getJSONArray("changes").length())
                            assertEquals(normalize(fixture.get("expected")), normalize(captured["finalA"]))
                            assertEquals(normalize(fixture.get("expectedAfterUndo")), normalize(captured["afterUndo"]))
                        }
                        fixture.optJSONObject("expectedValues")?.let { expected ->
                            expected.keys().forEach { capture ->
                                assertEquals("$name $capture value", normalize(expected.get(capture)), normalize(checkNotNull(captured[capture])))
                            }
                        }
                    }
                }
            } finally {
                try {
                    responseWriter.append(']')
                    responseWriter.close()
                    responseFiles[name] = responseFile
                    writeReport()
                } finally {
                    for (handle in sessions.toList()) call(JSONObject().put("command", "close").put("session", handle))
                }
            }
        }
        val application = instrumentation.targetContext.applicationInfo
        val selectedAbi = when (File(application.nativeLibraryDir).name) {
            "arm64" -> "arm64-v8a"
            "x86_64" -> "x86_64"
            else -> error("Unexpected selected native library directory: ${application.nativeLibraryDir}")
        }
        // Modern APKs load page-aligned native libraries directly from the APK.
        val header = ZipFile(application.sourceDir).use { apk ->
            apk.getInputStream(checkNotNull(apk.getEntry("lib/$selectedAbi/libBlockEditorJNI.so"))).use { stream ->
                ByteArray(20).also { assertEquals(20, stream.read(it)) }
            }
        }
        assertEquals(2, header[4].toInt()) // ELF64, little endian.
        assertEquals(1, header[5].toInt())
        val machine = (header[18].toInt() and 255) or ((header[19].toInt() and 255) shl 8)
        val abi = when (machine) { 183 -> "arm64-v8a"; 62 -> "x86_64"; else -> error("Unexpected loaded JNI machine: $machine") }
        assertEquals(selectedAbi, abi)
        val expectedAbi = InstrumentationRegistry.getArguments().getString("expectedAbi")
        if (expectedAbi != null) assertEquals("Packaged JNI ABI", expectedAbi, abi)
        File(output, "environment.json").writeText(JSONObject().put("api", Build.VERSION.SDK_INT).put("fingerprint", Build.FINGERPRINT)
            .put("systemAbis", JSONArray(Build.SUPPORTED_ABIS.toList())).put("jniAbi", abi).put("jniELFMachine", machine)
            .put("nativeLibraryDir", application.nativeLibraryDir).toString(2))
    }
}
