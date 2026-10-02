package studio.seventwo.blockeditor

import android.os.Build
import android.os.SystemClock
import androidx.test.platform.app.InstrumentationRegistry
import java.io.File
import java.security.MessageDigest
import java.util.zip.ZipFile
import kotlin.math.ceil
import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/** Opt-in baseline; ordinary instrumentation uses the short correctness smoke. */
class PerformanceTest {
    private fun normalize(value: Any?): Any? = when (value) {
        is JSONObject -> value.keys().asSequence().associateWith { normalize(value.get(it)) }
        is JSONArray -> (0 until value.length()).map { normalize(value.get(it)) }
        JSONObject.NULL -> null
        else -> value
    }
    private fun obj(vararg pairs: Pair<String, Any>): JSONObject = JSONObject().also { result -> pairs.forEach { result.put(it.first, it.second) } }
    private fun hash(bytes: ByteArray) = MessageDigest.getInstance("SHA-256").digest(bytes).joinToString("") { "%02x".format(it) }
    private fun summary(values: List<Double>): JSONObject {
        val sorted = values.sorted()
        require(sorted.isNotEmpty() && sorted.all { it.isFinite() && it >= 0 })
        fun percentile(p: Double) = sorted[(ceil(p * sorted.size).toInt() - 1).coerceAtLeast(0)]
        return obj("count" to values.size, "totalMs" to values.sum(), "minMs" to sorted.first(), "p50Ms" to percentile(.5),
            "p95Ms" to percentile(.95), "maxMs" to sorted.last(), "samplesMs" to JSONArray(values))
    }

    @Test fun measureVerifiedWorkloads() {
        val instrumentation = InstrumentationRegistry.getInstrumentation()
        val context = instrumentation.context
        val args = InstrumentationRegistry.getArguments()
        val writing = args.getString("performanceWriting") == "true"
        val bytes = context.assets.open(if (writing) "workloads-writing.json" else "workloads.json").use { it.readBytes() }
        val config = JSONObject(bytes.toString(Charsets.UTF_8))
        assertEquals(1, config.getInt("version"))
        val profile = args.getString("performanceProfile", "smoke")
        require(profile in listOf("smoke", "baseline"))
        val all = config.getJSONArray("cases")
        val names = args.getString("performanceCases")?.split(',') ?: if (profile == "smoke") if (writing) listOf("ordinary-v4", "ordinary-v5", "ordinary-v6") else listOf("ordinary-v1", "ordinary-v2")
            else (0 until all.length()).map { all.getJSONObject(it).getString("name") }
        require(names.isNotEmpty() && names.toSet().size == names.size)
        val cases = JSONArray()
        for (name in names) {
            val source = (0 until all.length()).map { all.getJSONObject(it) }.single { it.getString("name") == name }
            cases.put(JSONObject(source.toString()).also { if (profile == "smoke") it.put("editsPerAuthor", 8) })
        }
        val repetitions = args.getString("performanceRepetitions")?.toInt() ?: if (profile == "smoke") 1 else config.getInt("repetitions")
        val warmups = args.getString("performanceWarmups")?.toInt() ?: if (profile == "smoke") 0 else config.getInt("warmups")
        require(repetitions >= 1 && warmups >= 0)
        val output = File(context.filesDir, "performance").apply { mkdirs() }
        val samples = JSONArray()
        val report = obj("version" to 1, "workloadHash" to hash(bytes), "sourceCommit" to args.getString("sourceCommit", "unspecified"),
            "options" to obj("profile" to profile, "cases" to cases, "repetitions" to repetitions, "warmups" to warmups),
            "runtime" to obj("name" to "android-api${Build.VERSION.SDK_INT}-${args.getString("expectedAbi", "unspecified")}",
                "api" to Build.VERSION.SDK_INT, "model" to Build.MODEL, "hardware" to Build.HARDWARE, "fingerprint" to Build.FINGERPRINT,
                "vm" to System.getProperty("java.vm.version", "unknown"), "maxHeapBytes" to Runtime.getRuntime().maxMemory(),
                "supportedAbis" to JSONArray(Build.SUPPORTED_ABIS.toList()), "processors" to Runtime.getRuntime().availableProcessors(),
                "boundary" to "NativeEngine.call; Kotlin JSON/UTF-8, JNI copies and Swift included; rendering excluded"),
            "samples" to samples, "complete" to false)
        report.put("numericBudgets", "unagreed")
        if (writing) {
            val sourceTree = checkNotNull(args.getString("sourceTree"))
            require(sourceTree.matches(Regex("[a-f0-9]{40}")))
            val sourceDirty = checkNotNull(args.getString("sourceDirty"))
            require(sourceDirty in listOf("true", "false"))
            report.put("sourceTree", sourceTree).put("sourceDirty", sourceDirty == "true")
        }
        var maxPssBytes = 0L
        var memorySamples = 0
        fun sampleMemory() {
            if (!writing) return
            maxPssBytes = maxOf(maxPssBytes, android.os.Debug.getPss() * 1024L)
            memorySamples++
            report.put("memory", obj("maximumSampledProcessPssBytes" to maxPssBytes, "samples" to memorySamples,
                "boundary" to "Whole instrumentation process PSS sampled after create/receive/save/restore; not a continuous peak or app-rendering budget"))
        }
        fun publish() = File(output, if (writing) "android-writing.json" else "android.json").writeText(report.toString(2))
        publish()
        try {
            // First access initializes NativeEngine and loads the selected JNI library.
            val firstCall = SystemClock.elapsedRealtimeNanos()
            NativeEngine.call(obj("command" to "create", "session" to "startup", "actorID" to "startup", "documentID" to "startup", "blocks" to JSONArray()).also { if (writing) it.put("collaborationVersion", cases.getJSONObject(0).getInt("version")).put("epoch", "performance-writing-v${cases.getJSONObject(0).getInt("version")}") })
            report.put("initialization", obj("firstJniCallAndEmptySessionMs" to (SystemClock.elapsedRealtimeNanos() - firstCall) / 1e6,
                "diskCaches" to "uncontrolled; fresh instrumentation process, not Activity or disk-cold startup"))
            NativeEngine.call(obj("command" to "close", "session" to "startup"))
            val abi = when (File(context.applicationInfo.nativeLibraryDir).name) {
                "arm64" -> "arm64-v8a"
                "x86_64" -> "x86_64"
                else -> error("Unexpected selected JNI directory: ${context.applicationInfo.nativeLibraryDir}")
            }
            if (args.containsKey("expectedAbi")) assertEquals(args.getString("expectedAbi"), abi)
            report.getJSONObject("runtime").put("jniAbi", abi).put("name", "android-api${Build.VERSION.SDK_INT}-$abi")
            val artifacts = JSONArray()
            ZipFile(context.applicationInfo.sourceDir).use { zip ->
                for (name in listOf("libBlockEditorBridge.so", "libBlockEditorJNI.so", "libc++_shared.so")) {
                    val entry = checkNotNull(zip.getEntry("lib/$abi/$name"))
                    val content = zip.getInputStream(entry).use { it.readBytes() }
                    val machine = (content[18].toInt() and 255) or ((content[19].toInt() and 255) shl 8)
                    assertEquals(if (abi == "arm64-v8a") 183 else 62, machine)
                    artifacts.put(obj("name" to name, "rawBytes" to content.size, "zipBytes" to entry.compressedSize,
                        "sha256" to hash(content), "elfMachine" to machine, "configuration" to "release Swift; static Swift runtime; debug instrumentation/Kotlin host"))
                }
            }
            report.put("artifacts", artifacts)
            publish()
            for (caseIndex in 0 until cases.length()) {
                val workload = cases.getJSONObject(caseIndex)
                for (repeat in -warmups until repetitions) {
                    val sample = runCase(config, workload, repeat, ::sampleMemory)
                    if (repeat >= 0) { samples.put(sample); publish() }
                }
            }
            report.put("complete", true)
        } catch (error: Throwable) { report.put("error", error.toString()); throw error }
        finally { publish() }
    }

    private fun runCase(config: JSONObject, workload: JSONObject, repetition: Int, sampleMemory: () -> Unit): JSONObject {
        val name = workload.getString("name")
        val n = workload.getInt("editsPerAuthor")
        val version = workload.getInt("version")
        val baseline = config.getJSONArray("baseline")
        val sessions = mutableSetOf<String>()
        val timings = mutableMapOf<String, MutableList<Double>>()
        fun handle(role: String) = "perf-$name-$repetition-$role"
        val a = handle("a"); val b = handle("b"); val peer = handle("peer"); val reopened = handle("reopened")
        val address = obj("blockID" to config.getString("textBlockID"), "path" to JSONArray(listOf("content")))
        fun request(phase: String, command: String, session: String, vararg fields: Pair<String, Any>): Any {
            val input = obj("command" to command, "session" to session)
            fields.forEach { input.put(it.first, it.second) }
            val start = SystemClock.elapsedRealtimeNanos()
            val response = NativeEngine.call(input)
            timings.getOrPut(phase) { mutableListOf() }.add((SystemClock.elapsedRealtimeNanos() - start) / 1e6)
            if (command in listOf("create", "restore")) sessions.add(session)
            if (command in listOf("create", "receive", "save", "restore")) sampleMemory()
            return response.get("value")
        }
        fun create(session: String, actor: String) = request("create", "create", session, "actorID" to actor,
            "documentID" to "performance-$name", "blocks" to baseline, "collaborationVersion" to version, *(if (version >= 3) arrayOf("epoch" to "performance-writing-v$version") else emptyArray())) as JSONObject
        fun receive(session: String, batch: JSONObject, phase: String = "rejoin") = request(phase, "receive", session, "batch" to batch) as JSONObject
        fun blocks(value: JSONObject) = value.getJSONArray("blocks")
        fun assertContent(snapshot: JSONObject, aCount: Int, bCount: Int) {
            val actual = blocks(snapshot)
            assertEquals(normalize(JSONArray((1 until baseline.length()).map { baseline.get(it) })), normalize(JSONArray((1 until actual.length()).map { actual.get(it) })))
            val block = actual.getJSONObject(0)
            val identity = JSONObject(block.toString()).also { it.remove("content") }
            val original = JSONObject(baseline.getJSONObject(0).toString()).also { it.remove("content") }
            assertEquals(normalize(original), normalize(identity))
            val content = block.getJSONArray("content")
            val text = (0 until content.length()).joinToString("") {
                val node = content.getJSONObject(it); assertEquals("text", node.getString("type")); node.getString("text")
            }
            val initial = config.getString("initialText")
            assertTrue(text.endsWith(initial))
            val prefix = text.dropLast(initial.length)
            assertTrue(prefix.all { it == 'a' || it == 'b' })
            assertEquals(aCount, prefix.count { it == 'a' }); assertEquals(bCount, prefix.count { it == 'b' })
        }
        fun assertFormatting(snapshot: JSONObject, boldCount: Int, italicCount: Int) {
            val counts = mutableMapOf("bold" to 0, "italic" to 0)
            val content = blocks(snapshot).getJSONObject(0).getJSONArray("content")
            for (index in 0 until content.length()) {
                val node = content.getJSONObject(index)
                val marks = node.optJSONArray("marks") ?: continue
                for ((type, text) in listOf("bold" to "a", "italic" to "b")) {
                    if (!(0 until marks.length()).any { marks.getJSONObject(it).getString("type") == type }) continue
                    assertEquals("Formatting escaped its author's character", text, node.getString("text"))
                    counts[type] = counts.getValue(type) + 1
                }
            }
            assertEquals(mapOf("bold" to boldCount, "italic" to italicCount), counts)
        }
        try {
            assertEquals(normalize(baseline), normalize(blocks(create(a, "a"))))
            create(b, "b")
            repeat(n) {
                for ((session, text) in listOf(a to "a", b to "b")) request("offlineEdit", "replaceText", session,
                    "address" to address, "start" to 0, "end" to 0, "text" to text, "marks" to JSONArray())
            }
            for ((session, type) in listOf(a to "bold", b to "italic")) request("format", "format", session,
                "address" to address, "start" to 0, "end" to 1, "markType" to type, "mark" to obj("type" to type))
            val batchA = request("exchangeExport", "changes", a) as JSONObject
            val batchB = request("exchangeExport", "changes", b) as JSONObject
            assertEquals(n + 1, batchA.getJSONArray("changes").length()); assertEquals(n + 1, batchB.getJSONArray("changes").length())
            fun changes(batch: JSONObject) = batch.getJSONArray("changes").let { array -> (0 until array.length()).map { array.get(it) } }
            fun withChanges(batch: JSONObject, values: List<Any>) = JSONObject(batch.toString()).put("changes", JSONArray(values))
            val reversedB = changes(batchB).reversed()
            val finalA = receive(a, withChanges(batchB, reversedB + reversedB))
            val finalB = receive(b, withChanges(batchA, changes(batchA).reversed()))
            assertEquals(normalize(blocks(finalA)), normalize(blocks(finalB))); assertContent(finalA, n, n)
            assertFormatting(finalA, 1, 1)
            assertEquals(normalize(blocks(finalA)), normalize(blocks(receive(a, batchB, "duplicateReceive"))))
            create(peer, "peer")
            val combined = withChanges(batchA, (changes(batchA) + changes(batchB)).reversed())
            assertEquals(normalize(blocks(finalA)), normalize(blocks(receive(peer, combined, "fullHistoryReceive"))))
            val saved = request("save", "save", a) as JSONObject
            val receipts = request("receipts", "syncState", a) as JSONObject
            if (version >= 3) {
                for (value in listOf(batchA, batchB, saved, receipts)) {
                    assertEquals(version, value.getInt("version")); assertEquals("performance-writing-v$version", value.getString("epoch"))
                    assertEquals("performance-$name", value.getString("documentID"))
                }
                val history = saved.getJSONObject("localHistory")
                assertEquals("a", history.getString("actorID")); history.getJSONArray("undo"); history.getJSONArray("redo")
            }
            assertEquals(n * 2 + 2, saved.getJSONArray("changes").length())
            assertEquals(n * 2 + 2, receipts.getJSONArray("received").length())
            val restored = request("restore", "restore", reopened, "actorID" to "a", "snapshot" to saved) as JSONObject
            assertEquals(normalize(blocks(finalA)), normalize(blocks(restored)))
            assertEquals(normalize(receipts), normalize(request("receipts", "syncState", reopened)))
            val afterFormatUndo = request("undo", "undo", reopened) as JSONObject
            assertFormatting(afterFormatUndo, 0, 1)
            val afterUndo = request("undo", "undo", reopened) as JSONObject
            assertContent(afterUndo, n - 1, n)
            assertFormatting(afterUndo, 0, 1)
            request("redo", "redo", reopened)
            assertEquals(normalize(blocks(finalA)), normalize(blocks(request("redo", "redo", reopened) as JSONObject)))
            return obj("case" to name, "repetition" to repetition, "version" to version, "editsPerAuthor" to n,
                "metrics" to JSONObject().also { result -> timings.forEach { result.put(it.key, summary(it.value)) } },
                "sizes" to obj("baselineBytes" to baseline.toString().toByteArray(Charsets.UTF_8).size,
                    "snapshotBytes" to saved.toString().toByteArray(Charsets.UTF_8).size,
                    "exchangeBytes" to combined.toString().toByteArray(Charsets.UTF_8).size,
                    "changes" to saved.getJSONArray("changes").length(), "receipts" to receipts.getJSONArray("received").length()),
                "finalBlocks" to blocks(finalA))
        } finally { sessions.forEach { NativeEngine.call(obj("command" to "close", "session" to it)) } }
    }
}
