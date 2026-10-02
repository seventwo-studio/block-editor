package studio.seventwo.blockeditor

import android.os.Build
import android.os.Process
import android.util.JsonReader
import android.util.JsonToken
import androidx.test.platform.app.InstrumentationRegistry
import java.io.File
import java.security.MessageDigest
import java.util.zip.ZipFile
import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/** One fresh installed instrumentation process per version/case. No surrogate limits. */
class WritingResourceTest {
    private fun obj(vararg fields: Pair<String, Any>): JSONObject = JSONObject().also { o -> fields.forEach { o.put(it.first, it.second) } }
    private fun array(values: List<Any>) = JSONArray(values)
    private fun text(value: String) = obj("type" to "text", "text" to value, "marks" to JSONArray())
    private fun clone(value: JSONObject) = JSONObject(value.toString())
    private fun clone(value: JSONArray) = JSONArray(value.toString())
    private fun digest(bytes: ByteArray) = MessageDigest.getInstance("SHA-256").digest(bytes).joinToString("") { "%02x".format(it) }
    // Identical canonical token stream for compact fingerprints and complete
    // caller-owned archives. Never make a whole32/64MB serialization String.
    private fun canonical(value: Any, emit: (String) -> Unit) {
        fun quoted(s: String) {
            emit("\""); var start = 0
            fun span(end: Int) { var cursor = start; while (cursor < end) { var next = minOf(cursor + 8192, end); if (next < end && s[next - 1].isHighSurrogate()) next--; emit(s.substring(cursor, next)); cursor = next } }
            for (i in s.indices) {
                val escape = when (s[i]) { '"' -> "\\\""; '\\' -> "\\\\"; '\b' -> "\\b"; '\u000C' -> "\\f"; '\n' -> "\\n"; '\r' -> "\\r"; '\t' -> "\\t"; else -> if (s[i] < ' ') "\\u%04x".format(s[i].code) else null }
                if (escape != null) { span(i); emit(escape); start = i + 1 }
            }
            span(s.length); emit("\"")
        }
        fun write(v: Any?) {
            when (v) {
                null, JSONObject.NULL -> emit("null")
                is JSONObject -> { emit("{"); v.keys().asSequence().sorted().forEachIndexed { i, key -> if (i > 0) emit(","); quoted(key); emit(":"); write(v.get(key)) }; emit("}") }
                is JSONArray -> { emit("["); for (i in 0 until v.length()) { if (i > 0) emit(","); write(v.get(i)) }; emit("]") }
                is String -> quoted(v)
                is Boolean -> emit(v.toString())
                is Number -> { require(v.toDouble().isFinite()); emit(JSONObject.numberToString(v)) }
                else -> error("Non-JSON resource fingerprint")
            }
        }
        write(value)
    }
    private fun fingerprint(value: Any): JSONObject {
        val digest = MessageDigest.getInstance("SHA-256"); var bytes = 0L
        canonical(value) { val encoded = it.toByteArray(Charsets.UTF_8); bytes += encoded.size; digest.update(encoded) }
        return obj("bytes" to bytes, "sha256" to digest.digest().joinToString("") { "%02x".format(it) })
    }
    private class Archive(val file: File, val fingerprint: JSONObject)
    private fun archive(value: Any, file: File): Archive {
        val digest = MessageDigest.getInstance("SHA-256"); var bytes = 0L
        file.outputStream().buffered().use { output ->
            canonical(value) { val encoded = it.toByteArray(Charsets.UTF_8); bytes += encoded.size; digest.update(encoded); output.write(encoded) }
        }
        return Archive(file, obj("bytes" to bytes, "sha256" to digest.digest().joinToString("") { "%02x".format(it) }))
    }
    private fun read(archive: Archive): Any = JsonReader(archive.file.reader(Charsets.UTF_8).buffered()).use { reader ->
        // These are exact, own canonical archives, not external clipboard data.
        // No whole file String or parsed second copy is manufactured.
        fun value(): Any = when (reader.peek()) {
            JsonToken.BEGIN_OBJECT -> JSONObject().also { objectValue -> reader.beginObject(); while (reader.hasNext()) objectValue.put(reader.nextName(), value()); reader.endObject() }
            JsonToken.BEGIN_ARRAY -> JSONArray().also { arrayValue -> reader.beginArray(); while (reader.hasNext()) arrayValue.put(value()); reader.endArray() }
            JsonToken.STRING -> reader.nextString()
            JsonToken.NUMBER -> { val token = reader.nextString(); val integer = token.toLongOrNull(); if (integer == null) token.toDouble().also { require(it.isFinite()) } else if (integer in Int.MIN_VALUE.toLong()..Int.MAX_VALUE.toLong()) integer.toInt() else integer }
            JsonToken.BOOLEAN -> reader.nextBoolean()
            JsonToken.NULL -> { reader.nextNull(); JSONObject.NULL }
            else -> error("Malformed caller-owned archive")
        }
        value().also { check(reader.peek() == JsonToken.END_DOCUMENT) }
    }
    private fun matches(actual: Any, expected: Archive, label: String) = same(fingerprint(actual), expected.fingerprint, label)
    private fun repeated(actual: String, character: Char, size: Int, label: String) {
        assertEquals("$label length", size, actual.length); assertTrue("$label content", actual.all { it == character })
    }
    private fun padded(actual: String, size: Int, label: String) {
        assertEquals("$label length", size / 2 + size % 2, actual.length)
        assertTrue("$label Unicode content", actual.indices.all { actual[it] == if (it < size / 2) 'é' else 'x' })
    }
    private fun bytes(value: Any) = fingerprint(value).getLong("bytes")
    private fun same(actual: Any, expected: Any, label: String) = assertEquals(label, fingerprint(expected).toString(), fingerprint(actual).toString())
    private fun padding(bytes: Int) = "é".repeat(bytes / 2) + if (bytes % 2 == 0) "" else "x"

    @Test fun verifyActualProductionResourceCase() {
        val instrumentation = InstrumentationRegistry.getInstrumentation(); val context = instrumentation.context
        val args = InstrumentationRegistry.getArguments()
        val specBytes = context.assets.open("resources-writing.json").use { it.readBytes() }; val spec = JSONObject(specBytes.toString(Charsets.UTF_8))
        assertEquals(1, spec.getInt("version")); same(spec.getJSONArray("protocols"), array(listOf(4, 5, 6)), "finite resource protocols")
        same(spec.getJSONArray("cases"), array(listOf("document-exact", "document-over", "retained-exact-over", "roots-exact", "roots-over")), "all resource cases")
        same(spec.getJSONObject("limits"), obj("documentBytes" to 32_000_000, "retainedBytes" to 64_000_000, "rootBlocks" to 10_000, "retainedReserveBytes" to 1_024), "production limits")
        val version = checkNotNull(args.getString("resourceVersion")).toInt(); require(version in listOf(4, 5, 6))
        val caseName = checkNotNull(args.getString("resourceCase")); require(caseName in listOf("document-exact", "document-over", "retained-exact-over", "roots-exact", "roots-over"))
        val abi = checkNotNull(args.getString("expectedAbi")); require(abi in listOf("x86_64", "arm64-v8a")); require(abi in Build.SUPPORTED_ABIS)
        val runtime = "android-api${Build.VERSION.SDK_INT}-$abi"
        val commit = checkNotNull(args.getString("sourceCommit")); val tree = checkNotNull(args.getString("sourceTree")); val dirty = checkNotNull(args.getString("sourceDirty"))
        require(commit.matches(Regex("[a-f0-9]{40}")) && tree.matches(Regex("[a-f0-9]{40}")) && dirty in listOf("true", "false"))
        val artifacts = JSONArray()
        // Library qualification is streamed so ELF bytes are not retained in
        // this test frame alongside resource snapshots.
        ZipFile(context.applicationInfo.sourceDir).use { zip ->
            for ((name, role) in listOf("libBlockEditorJNI.so" to "jni", "libBlockEditorBridge.so" to "swift-bridge", "libc++_shared.so" to "cxx-runtime")) {
                val digest = MessageDigest.getInstance("SHA-256"); var count = 0L
                zip.getInputStream(checkNotNull(zip.getEntry("lib/$abi/$name"))).use { input ->
                    val header = ByteArray(20); var cursor = 0
                    while (cursor < header.size) { val next = input.read(header, cursor, header.size - cursor); check(next > 0); cursor += next }
                    val machine = (header[18].toInt() and 255) or ((header[19].toInt() and 255) shl 8); assertEquals(if (abi == "arm64-v8a") 183 else 62, machine)
                    digest.update(header); count += header.size
                    val buffer = ByteArray(64 * 1024)
                    while (true) { val read = input.read(buffer); if (read < 0) break; digest.update(buffer, 0, read); count += read }
                }
                artifacts.put(obj("name" to name, "role" to role, "rawBytes" to count, "sha256" to digest.digest().joinToString("") { "%02x".format(it) }))
            }
        }
        val report = obj("version" to 1, "kind" to "compact-production-resource-proof", "runtime" to runtime, "protocol" to version, "case" to caseName,
            "specSHA256" to digest(specBytes), "source" to obj("commit" to commit, "tree" to tree, "dirty" to (dirty == "true")), "artifacts" to artifacts,
            "boundary" to "Actual installed packaged JNI shared JSON bridge; generated production limits; UI/physical host acceptance excluded",
            "processPID" to Process.myPid(), "complete" to false)
        val file = File(File(context.filesDir, "resource").apply { mkdirs() }, "resource-writing-$runtime-v$version-$caseName.json")
        fun publish() = file.writeText(report.toString(2))
        publish()
        val archiveDirectory = File(context.filesDir, "resource-archives/v$version-$caseName-${Process.myPid()}-${System.nanoTime()}").apply { check(mkdirs()) }
        // Runtime diagnostics, outside cross-runtime canonical proof parity.
        // A failed case retains the complete caller-owned inputs/saves/pending
        // proposals; a completed case releases only its private temporary files.
        report.put("archiveDirectory", archiveDirectory.absolutePath).put("archivesRetained", true)
        var failure: Throwable? = null
        try {
            report.put("proof", runCase(spec, version, caseName, archiveDirectory))
            check(archiveDirectory.deleteRecursively()) { "Failed to clean completed resource archives" }
            report.put("archivesRetained", false).put("complete", true)
        }
        catch (error: Throwable) { failure = error; report.put("error", error.toString()); throw error }
        finally {
            try { publish() } catch (diagnostic: Throwable) {
                val original = failure
                if (original != null) original.addSuppressed(diagnostic) else throw diagnostic
            }
        }
    }
    private fun runCase(spec: JSONObject, version: Int, caseName: String, archiveDirectory: File): JSONObject {
        val base = clone(spec.getJSONArray("baseline")); val owner = obj("baseline" to obj("blockID" to "owner", "path" to JSONArray()))
        val documentID = "packaged-resource-$version-$caseName"; val epoch = "resource-v$version"; val sessions = linkedSetOf<String>()
        fun request(command: String, session: String, fields: JSONObject = JSONObject(), error: String? = null): Any {
            val input = obj("command" to command, "session" to session); fields.keys().forEach { input.put(it, fields.get(it)) }
            val response = try { NativeEngine.call(input) }
            catch (failure: WritingRecoveryException) { obj("ok" to false, "error" to "writingRecoveryRequired", "recovery" to failure.recovery.export()) }
            catch (failure: IllegalStateException) { obj("ok" to false, "error" to checkNotNull(failure.message)) }
            assertEquals("$command status", error == null, response.getBoolean("ok"))
            if (error != null) { assertEquals("$command error", error, response.getString("error")); return response.opt("recovery") ?: JSONObject.NULL }
            if (command in listOf("create", "restore")) sessions.add(session)
            if (command == "close") sessions.remove(session)
            return response.get("value")
        }
        fun create(session: String, actor: String, blocks: JSONArray = base, extra: JSONObject = JSONObject()): JSONObject {
            val fields = obj("documentID" to documentID, "actorID" to actor, "epoch" to epoch, "collaborationVersion" to version, "blocks" to blocks)
            extra.keys().forEach { fields.put(it, extra.get(it)) }; return request("create", session, fields) as JSONObject
        }
        fun field(session: String, name: String, value: String) = request("setNodeField", session, obj("identity" to owner, "path" to array(listOf("consumer", name)), "value" to value))
        fun save(session: String) = request("save", session) as JSONObject
        fun receipt(session: String) = request("syncState", session) as JSONObject
        fun changes(session: String) = request("changes", session) as JSONObject
        fun rich(snapshot: JSONObject) = same(snapshot.getJSONArray("blocks").getJSONObject(0).getJSONArray("content"), base.getJSONObject(0).getJSONArray("content"), "rich Unicode/reference/marks preserved")
        var archiveCounter = 0
        fun store(value: Any, name: String) = archive(value, File(archiveDirectory, "${archiveCounter++}-$name.json"))
        fun saveArchive(session: String) = store(save(session), "$session-save")
        fun batchArchive(session: String) = store(changes(session), "$session-changes")
        fun acceptedUnchanged(session: String, saved: Archive, received: JSONObject) { matches(save(session), saved, "accepted save unchanged"); same(receipt(session), received, "accepted receipt unchanged") }
        fun repair(session: String, actor: String = "a") = request("repairWritingUndo", session, obj("target" to obj("counter" to 1, "actor" to actor)), if (actor == "a") null else "invalidChange")
        fun close(session: String) { request("close", session) }
        var primaryFailure: Throwable? = null
        try {
            if (caseName.startsWith("document-")) {
                val excess = if (caseName == "document-over") 1 else 0
                val payload = (32_000_000 - bytes(base) + excess).toInt()
                val leftSize = payload / 2; val rightSize = payload - leftSize
                fun expectedDocument(): Archive {
                    val expected = clone(base)
                    expected.getJSONObject(0).getJSONObject("consumer").put("left", padding(leftSize)).put("right", padding(rightSize))
                    return store(expected, "literal-document").also { assertEquals(32_000_000L + excess, it.fingerprint.getLong("bytes")) }
                }
                val expected = expectedDocument()
                fun check(value: Any, label: String) {
                    val snapshot = value as JSONObject
                    matches(snapshot.getJSONArray("blocks"), expected, label); rich(snapshot)
                }
                // This helper lifetime owns only one authored padding at a time.
                fun author(session: String, name: String, size: Int) { field(session, name, padding(size)) }
                create("a", "a"); create("b", "b")
                author("a", "left", leftSize); author("b", "right", rightSize)
                val aReceipt = receipt("a"); val bReceipt = receipt("b")
                val aBatch = batchArchive("a"); val bBatch = batchArchive("b")
                if (excess == 0) {
                    check(request("receive", "a", obj("batch" to read(bBatch))), "exact document admitted")
                    // The original authored delta is complete: b already owns
                    // its own edit. Do not manufacture a redundant full union.
                    check(request("receive", "b", obj("batch" to read(aBatch))), "exact union converges")
                    check(request("receive", "a", obj("batch" to read(bBatch))), "duplicate union")
                    val acceptedSave = saveArchive("a"); val acceptedReceipt = receipt("a")
                    close("a"); close("b")
                    request("restore", "r", obj("snapshot" to read(acceptedSave), "actorID" to "a"))
                    fun checkUndo() {
                        val undone = request("undo", "r") as JSONObject
                        val metadata = undone.getJSONArray("blocks").getJSONObject(0).getJSONObject("consumer")
                        assertEquals("", metadata.getString("left")); padded(metadata.getString("right"), rightSize, "peer right after Undo"); rich(undone)
                    }
                    checkUndo(); check(request("redo", "r"), "Redo/reopen")
                    return obj("case" to caseName, "version" to version, "documentBytes" to expected.fingerprint.getLong("bytes"), "accepted" to acceptedSave.fingerprint, "receipt" to acceptedReceipt, "authorUndoPreservesPeer" to true)
                }
                val aSave = saveArchive("a"); val bSave = saveArchive("b")
                val proposal = store(request("receive", "a", obj("batch" to read(bBatch)), "writingRecoveryRequired"), "pending")
                matches(request("receive", "b", obj("batch" to read(aBatch)), "writingRecoveryRequired"), proposal, "both proposals")
                matches(request("receive", "a", obj("batch" to read(bBatch)), "writingRecoveryRequired"), proposal, "duplicate pending")
                fun checkProposal() {
                    val pending = read(proposal) as JSONObject
                    assertEquals("schemaConstraint", pending.getString("reason")); assertEquals(2, pending.getJSONObject("batch").getJSONArray("changes").length())
                }
                checkProposal(); acceptedUnchanged("a", aSave, aReceipt); acceptedUnchanged("b", bSave, bReceipt)
                close("a")
                request("restore", "r", obj("snapshot" to read(aSave), "actorID" to "a"))
                matches(request("restoreRecovery", "r", obj("recovery" to read(proposal)), "writingRecoveryRequired"), proposal, "restart recovery")
                repair("r", "b"); acceptedUnchanged("r", aSave, aReceipt); matches(request("mergeRecovery", "r"), proposal, "failed repair pending")
                fun checkRepair(): Archive {
                    val repaired = repair("r") as JSONObject
                    val metadata = repaired.getJSONArray("blocks").getJSONObject(0).getJSONObject("consumer")
                    assertEquals("", metadata.getString("left")); padded(metadata.getString("right"), rightSize, "repaired peer right"); rich(repaired)
                    assertEquals(JSONObject.NULL, request("mergeRecovery", "r"))
                    return store(repaired.getJSONArray("blocks"), "repaired-document")
                }
                val repaired = checkRepair(); val repairedBatch = batchArchive("r")
                fun reverseRepair() {
                    val batch = read(repairedBatch) as JSONObject; val changes = batch.getJSONArray("changes")
                    assertEquals(3, changes.length())
                    batch.put("changes", array((0 until changes.length()).reversed().map { changes.get(it) }))
                    matches((request("receive", "b", obj("batch" to batch)) as JSONObject).getJSONArray("blocks"), repaired, "reversed repair")
                }
                reverseRepair(); request("receive", "b", obj("batch" to read(repairedBatch)))
                val repairedSave = saveArchive("r"); val repairedReceipt = receipt("r")
                val redo = store(request("redo", "r", error = "writingRecoveryRequired"), "rejected-redo")
                acceptedUnchanged("r", repairedSave, repairedReceipt); close("r"); close("b")
                request("restore", "rr", obj("snapshot" to read(repairedSave), "actorID" to "a"))
                request("restoreRecovery", "rr", obj("recovery" to read(redo)), "writingRecoveryRequired")
                matches((repair("rr") as JSONObject).getJSONArray("blocks"), repaired, "restarted Redo repair")
                assertEquals(5, changes("rr").getJSONArray("changes").length())
                return obj("case" to caseName, "version" to version, "documentBytes" to expected.fingerprint.getLong("bytes"), "acceptedBefore" to aSave.fingerprint, "pending" to proposal.fingerprint, "repaired" to repairedSave.fingerprint, "historyAfterSecondRepair" to 5, "peerMetadataAndRichPreserved" to true)
            }
            if (caseName == "retained-exact-over") {
                create("author", "a"); listOf("one", "two", "three", "four").forEach { field("author", "history", it) }; val template = changes("author"); val sourceChanges = template.getJSONArray("changes")
                same(array((0 until sourceChanges.length()).map { sourceChanges.getJSONObject(it).getJSONObject("id") }), array((1..4).map { obj("counter" to it, "actor" to "a") }), "real authored template IDs")
                close("author")
                fun make(sizes: List<Int>): JSONObject {
                    val result = obj("version" to template.getInt("version"), "documentID" to documentID, "epoch" to epoch, "baseline" to template.getJSONObject("baseline")); val list = JSONArray()
                    for (i in 0 until sourceChanges.length()) {
                        val change = clone(sourceChanges.getJSONObject(i)); val operations = change.getJSONObject("body").getJSONObject("edit").getJSONArray("_0"); assertEquals(1, operations.length())
                        val mutation = operations.getJSONObject(0).getJSONObject("structure").getJSONObject("_0").getJSONObject("setNodeField")
                        same(mutation.getJSONArray("path"), array(listOf("consumer", "history")), "retained operation path"); same(mutation.getJSONObject("identity"), owner, "retained operation owner")
                        mutation.put("value", i.toString().repeat(sizes[i])); list.put(change)
                    }
                    return result.put("changes", list)
                }
                val reserve = 1_024 + bytes(array((0 until sourceChanges.length()).map { sourceChanges.getJSONObject(it).getJSONObject("id") })).toInt()
                val payload = (64_000_000 - reserve - bytes(make(listOf(0, 0, 0, 0)))).toInt(); val quarter = payload / 4
                val sizes = listOf(quarter, quarter, quarter, payload - 3 * quarter)
                // Each complete packet survives on caller-owned disk; only the
                // one graph used by the current bridge operation is materialized.
                val exact = store(make(sizes), "exact-capacity-batch"); val exactBytes = exact.fingerprint.getLong("bytes")
                assertEquals(64_000_000L, exactBytes + reserve)
                create("receiver", "a")
                fun acceptExact(): Archive {
                    val accepted = request("receive", "receiver", obj("batch" to read(exact))) as JSONObject; rich(accepted)
                    repeated(accepted.getJSONArray("blocks").getJSONObject(0).getJSONObject("consumer").getString("history"), '3', sizes[3], "last retained edit")
                    return store(accepted.getJSONArray("blocks"), "accepted-document")
                }
                val acceptedDocument = acceptExact(); val acceptedSave = saveArchive("receiver"); val acceptedReceipt = receipt("receiver")
                assertTrue(acceptedSave.fingerprint.getLong("bytes") <= 64_000_000); close("receiver")
                matches((request("restore", "restarted", obj("snapshot" to read(acceptedSave), "actorID" to "a")) as JSONObject).getJSONArray("blocks"), acceptedDocument, "exact save reopens")
                same(receipt("restarted"), acceptedReceipt, "receipt reopens"); close("restarted")
                create("stopped", "b")
                fun receivePartial() {
                    val batch = read(exact) as JSONObject
                    batch.put("changes", array((0..2).map { batch.getJSONArray("changes").get(it) }))
                    request("receive", "stopped", obj("batch" to batch))
                }
                receivePartial(); val stoppedSave = saveArchive("stopped"); val stoppedReceipt = receipt("stopped")
                val callerArchive = store(make(sizes.take(3) + (sizes[3] + 1)), "caller-owned-rejected-packet")
                assertEquals(64_000_001L, callerArchive.fingerprint.getLong("bytes") + reserve)
                request("receive", "stopped", obj("batch" to read(callerArchive)), "recoveryCapacityExceeded")
                acceptedUnchanged("stopped", stoppedSave, stoppedReceipt); assertEquals(JSONObject.NULL, request("mergeRecovery", "stopped")); close("stopped")
                request("restore", "resumed", obj("snapshot" to read(stoppedSave), "actorID" to "b"))
                request("receive", "resumed", obj("batch" to read(callerArchive)), "recoveryCapacityExceeded"); acceptedUnchanged("resumed", stoppedSave, stoppedReceipt)
                val cutoverEpoch = "cutover-v$version"
                fun cutover() { create("cutover", "b", (request("document", "resumed") as JSONObject).getJSONArray("blocks"), obj("epoch" to cutoverEpoch)) }
                cutover(); close("resumed")
                field("cutover", "left", "after-cutover"); assertEquals(1, receipt("cutover").getJSONArray("received").length())
                request("receive", "cutover", obj("batch" to read(callerArchive)), "differentDocument")
                val cutoverSave = saveArchive("cutover")
                fun staleEpoch() {
                    val saved = read(cutoverSave) as JSONObject
                    val stale = obj("version" to version, "documentID" to documentID, "epoch" to epoch, "baseline" to saved.getJSONObject("baseline"), "changes" to JSONArray())
                    request("receive", "cutover", obj("batch" to stale), "incompatibleEpoch")
                }
                staleEpoch(); val cutoverDocument = store((request("document", "cutover") as JSONObject).getJSONArray("blocks"), "cutover-document"); close("cutover")
                matches((request("restore", "cutover-reopened", obj("snapshot" to read(cutoverSave), "actorID" to "b")) as JSONObject).getJSONArray("blocks"), cutoverDocument, "cutover save")
                return obj("case" to caseName, "version" to version, "retainedBytes" to exactBytes, "reserveBytes" to reserve, "exactCapacityBytes" to 64_000_000, "rejectedCapacityBytes" to 64_000_001, "accepted" to acceptedSave.fingerprint, "callerOwnedRejected" to callerArchive.fingerprint, "stoppedReceipt" to stoppedReceipt, "cutoverEpoch" to cutoverEpoch)
            }
            val roots = if (caseName == "roots-exact") 9_998 else 9_999; val baseline = JSONArray().put(base.getJSONObject(0)); for (i in 1 until roots) baseline.put(obj("id" to "root-$i", "type" to "paragraph", "content" to array(listOf(text("")))))
            create("a", "a", baseline); create("b", "b", baseline); val last = obj("baseline" to obj("blockID" to "root-${roots - 1}", "path" to JSONArray()))
            val ownNode = obj("id" to "A", "type" to "paragraph", "content" to array(listOf(text("author"))))
            val peerNode = obj("id" to "B", "type" to "toggle", "summary" to array(listOf(text("peer 東京😀"))), "children" to array(listOf(obj("id" to "peer-child", "type" to "paragraph", "content" to base.getJSONObject(0).getJSONArray("content"), "consumer" to obj("id" to "peer-opaque")))), "consumer" to obj("id" to "B-opaque"))
            request("insertCollectionNodes", "a", obj("values" to array(listOf(ownNode)), "collection" to obj("field" to "blocks"), "after" to last))
            request("insertCollectionNodes", "b", obj("values" to array(listOf(peerNode)), "collection" to obj("field" to "blocks"), "after" to last))
            val peerAddress = obj("blockID" to "B", "path" to JSONArray()); val childAddress = obj("blockID" to "B", "path" to array(listOf("children", "peer-child")))
            val peerIdentity = request("node", "b", obj("address" to peerAddress)); val childIdentity = request("node", "b", obj("address" to childAddress))
            val aSave = saveArchive("a"); val bSave = saveArchive("b"); val aReceipt = receipt("a"); val bReceipt = receipt("b"); val aBatch = batchArchive("a"); val bBatch = batchArchive("b")
            fun peerIn(snapshot: JSONObject): JSONObject {
                val blocks = snapshot.getJSONArray("blocks"); var peer: JSONObject? = null
                for (i in 0 until blocks.length()) if (blocks.getJSONObject(i).getString("id") == "B") { kotlin.check(peer == null); peer = blocks.getJSONObject(i) }
                return checkNotNull(peer)
            }
            fun check(snapshot: JSONObject) { assertEquals(10_000, snapshot.getJSONArray("blocks").length()); rich(snapshot); same(peerIn(snapshot), peerNode, "peer subtree/metadata") }
            if (roots == 9_998) {
                fun accept(): Archive {
                    val combined = request("receive", "a", obj("batch" to read(bBatch))) as JSONObject; check(combined)
                    return store(combined.getJSONArray("blocks"), "exact-root-document")
                }
                val combined = accept()
                matches((request("receive", "b", obj("batch" to read(aBatch))) as JSONObject).getJSONArray("blocks"), combined, "exact root union")
                request("receive", "a", obj("batch" to read(bBatch)))
                val acceptedSave = saveArchive("a"); close("a"); close("b")
                request("restore", "r", obj("snapshot" to read(acceptedSave), "actorID" to "a"))
                fun checkUndo() {
                    val undone = request("undo", "r") as JSONObject
                    assertEquals(9_999, undone.getJSONArray("blocks").length()); same(peerIn(undone), peerNode, "peer subtree after Undo")
                }
                checkUndo(); matches((request("redo", "r") as JSONObject).getJSONArray("blocks"), combined, "root Redo")
                return obj("case" to caseName, "version" to version, "rootBlocks" to 10_000, "nestedPeerChildren" to 1, "accepted" to acceptedSave.fingerprint, "peerIdentity" to peerIdentity, "childIdentity" to childIdentity, "authorUndoRootBlocks" to 9_999)
            }
            val proposal = store(request("receive", "a", obj("batch" to read(bBatch)), "writingRecoveryRequired"), "root-pending")
            matches(request("receive", "b", obj("batch" to read(aBatch)), "writingRecoveryRequired"), proposal, "root proposals")
            matches(request("receive", "a", obj("batch" to read(bBatch)), "writingRecoveryRequired"), proposal, "root duplicate pending")
            assertEquals("schemaConstraint", (read(proposal) as JSONObject).getString("reason")); acceptedUnchanged("a", aSave, aReceipt); acceptedUnchanged("b", bSave, bReceipt); close("a")
            request("restore", "r", obj("snapshot" to read(aSave), "actorID" to "a")); request("restoreRecovery", "r", obj("recovery" to read(proposal)), "writingRecoveryRequired")
            repair("r", "b"); acceptedUnchanged("r", aSave, aReceipt); matches(request("mergeRecovery", "r"), proposal, "failed root repair")
            fun checkRepair(): Archive {
                val repaired = repair("r") as JSONObject; check(repaired)
                assertTrue((0 until repaired.getJSONArray("blocks").length()).none { repaired.getJSONArray("blocks").getJSONObject(it).getString("id") == "A" })
                return store(repaired.getJSONArray("blocks"), "repaired-root-document")
            }
            val repaired = checkRepair()
            same(request("node", "r", obj("address" to peerAddress)), peerIdentity, "peer origin"); same(request("node", "r", obj("address" to childAddress)), childIdentity, "child origin")
            val repairedBatch = batchArchive("r")
            fun reverseRepair() {
                val batch = read(repairedBatch) as JSONObject; val changes = batch.getJSONArray("changes"); assertEquals(3, changes.length())
                batch.put("changes", array((0 until changes.length()).reversed().map { changes.get(it) }))
                request("receive", "b", obj("batch" to batch))
            }
            reverseRepair(); request("receive", "b", obj("batch" to read(repairedBatch)))
            val repairedSave = saveArchive("r"); val repairedReceipt = receipt("r"); val redo = store(request("redo", "r", error = "writingRecoveryRequired"), "root-rejected-redo")
            acceptedUnchanged("r", repairedSave, repairedReceipt); close("r"); close("b")
            request("restore", "rr", obj("snapshot" to read(repairedSave), "actorID" to "a")); request("restoreRecovery", "rr", obj("recovery" to read(redo)), "writingRecoveryRequired")
            matches((repair("rr") as JSONObject).getJSONArray("blocks"), repaired, "root restarted Redo repair"); assertEquals(5, changes("rr").getJSONArray("changes").length())
            return obj("case" to caseName, "version" to version, "rejectedRootBlocks" to 10_001, "repairedRootBlocks" to 10_000, "pending" to proposal.fingerprint, "repaired" to repairedSave.fingerprint, "peerIdentity" to peerIdentity, "childIdentity" to childIdentity, "historyAfterSecondRepair" to 5)
        } catch (error: Throwable) { primaryFailure = error; throw error }
        finally {
            val failures = mutableListOf<Throwable>()
            sessions.toList().forEach { session ->
                try { request("close", session) } catch (error: Throwable) { failures.add(error) }
            }
            if (failures.isNotEmpty()) {
                val original = primaryFailure
                if (original != null) failures.forEach { original.addSuppressed(it) }
                else { failures.drop(1).forEach { failures[0].addSuppressed(it) }; throw failures[0] }
            }
        }
    }
}
