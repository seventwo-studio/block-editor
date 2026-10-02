package studio.seventwo.blockeditor

import android.os.Build
import android.os.Process
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
    // Streaming canonical fingerprint avoids manufacturing extra64MB host buffers
    // merely to measure/hash a packet. Actual JNI requests remain unchanged.
    private fun fingerprint(value: Any): JSONObject {
        val digest = MessageDigest.getInstance("SHA-256"); var bytes = 0L
        fun emit(s: String) { val encoded = s.toByteArray(Charsets.UTF_8); bytes += encoded.size; digest.update(encoded) }
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
        write(value); return obj("bytes" to bytes, "sha256" to digest.digest().joinToString("") { "%02x".format(it) })
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
        ZipFile(context.applicationInfo.sourceDir).use { zip ->
            for ((name, role) in listOf("libBlockEditorJNI.so" to "jni", "libBlockEditorBridge.so" to "swift-bridge", "libc++_shared.so" to "cxx-runtime")) {
                val content = zip.getInputStream(checkNotNull(zip.getEntry("lib/$abi/$name"))).use { it.readBytes() }
                val machine = (content[18].toInt() and 255) or ((content[19].toInt() and 255) shl 8); assertEquals(if (abi == "arm64-v8a") 183 else 62, machine)
                artifacts.put(obj("name" to name, "role" to role, "rawBytes" to content.size, "sha256" to digest(content)))
            }
        }
        val report = obj("version" to 1, "kind" to "compact-production-resource-proof", "runtime" to runtime, "protocol" to version, "case" to caseName,
            "specSHA256" to digest(specBytes), "source" to obj("commit" to commit, "tree" to tree, "dirty" to (dirty == "true")), "artifacts" to artifacts,
            "boundary" to "Actual installed packaged JNI shared JSON bridge; generated production limits; UI/physical host acceptance excluded",
            "processPID" to Process.myPid(), "complete" to false)
        val file = File(File(context.filesDir, "resource").apply { mkdirs() }, "resource-writing-$runtime-v$version-$caseName.json")
        fun publish() = file.writeText(report.toString(2))
        publish()
        var failure: Throwable? = null
        try { report.put("proof", runCase(spec, version, caseName)).put("complete", true) }
        catch (error: Throwable) { failure = error; report.put("error", error.toString()); throw error }
        finally {
            try { publish() } catch (diagnostic: Throwable) {
                val original = failure
                if (original != null) original.addSuppressed(diagnostic) else throw diagnostic
            }
        }
    }
    private fun runCase(spec: JSONObject, version: Int, caseName: String): JSONObject {
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
        fun acceptedUnchanged(session: String, saved: JSONObject, received: JSONObject) { same(save(session), saved, "accepted save unchanged"); same(receipt(session), received, "accepted receipt unchanged") }
        fun repair(session: String, actor: String = "a") = request("repairWritingUndo", session, obj("target" to obj("counter" to 1, "actor" to actor)), if (actor == "a") null else "invalidChange")
        var primaryFailure: Throwable? = null
        try {
            if (caseName.startsWith("document-")) {
                val excess = if (caseName == "document-over") 1 else 0; val payload = (32_000_000 - bytes(base) + excess).toInt()
                val left = padding(payload / 2); val right = padding(payload - payload / 2); val expected = clone(base)
                expected.getJSONObject(0).getJSONObject("consumer").put("left", left).put("right", right); assertEquals(32_000_000L + excess, bytes(expected))
                create("a", "a"); create("b", "b"); field("a", "left", left); field("b", "right", right)
                val aSave = save("a"); val bSave = save("b"); val aReceipt = receipt("a"); val bReceipt = receipt("b"); val aBatch = changes("a"); val bBatch = changes("b")
                if (excess == 0) {
                    val accepted = request("receive", "a", obj("batch" to bBatch)) as JSONObject; same(accepted.getJSONArray("blocks"), expected, "exact document admitted"); rich(accepted)
                    same((request("receive", "b", obj("batch" to changes("a"))) as JSONObject).getJSONArray("blocks"), expected, "exact union converges")
                    same((request("receive", "a", obj("batch" to bBatch)) as JSONObject).getJSONArray("blocks"), expected, "duplicate union")
                    val acceptedSave = save("a"); request("restore", "r", obj("snapshot" to acceptedSave, "actorID" to "a"))
                    val undone = request("undo", "r") as JSONObject; val metadata = undone.getJSONArray("blocks").getJSONObject(0).getJSONObject("consumer")
                    assertEquals("", metadata.getString("left")); assertEquals(right, metadata.getString("right")); rich(undone)
                    same((request("redo", "r") as JSONObject).getJSONArray("blocks"), expected, "Redo/reopen")
                    return obj("case" to caseName, "version" to version, "documentBytes" to bytes(expected), "accepted" to fingerprint(acceptedSave), "receipt" to receipt("a"), "authorUndoPreservesPeer" to true)
                }
                val proposal = request("receive", "a", obj("batch" to bBatch), "writingRecoveryRequired") as JSONObject
                same(request("receive", "b", obj("batch" to aBatch), "writingRecoveryRequired"), proposal, "both proposals")
                same(request("receive", "a", obj("batch" to bBatch), "writingRecoveryRequired"), proposal, "duplicate pending")
                assertEquals("schemaConstraint", proposal.getString("reason")); assertEquals(2, proposal.getJSONObject("batch").getJSONArray("changes").length())
                acceptedUnchanged("a", aSave, aReceipt); acceptedUnchanged("b", bSave, bReceipt)
                request("restore", "r", obj("snapshot" to aSave, "actorID" to "a")); same(request("restoreRecovery", "r", obj("recovery" to proposal), "writingRecoveryRequired"), proposal, "restart recovery")
                repair("r", "b"); acceptedUnchanged("r", aSave, aReceipt); same(request("mergeRecovery", "r"), proposal, "failed repair pending")
                val repaired = repair("r") as JSONObject; val metadata = repaired.getJSONArray("blocks").getJSONObject(0).getJSONObject("consumer")
                assertEquals("", metadata.getString("left")); assertEquals(right, metadata.getString("right")); rich(repaired); assertEquals(JSONObject.NULL, request("mergeRecovery", "r"))
                val repairedBatch = changes("r"); assertEquals(3, repairedBatch.getJSONArray("changes").length())
                val reverse = clone(repairedBatch); reverse.put("changes", array((0 until repairedBatch.getJSONArray("changes").length()).reversed().map { repairedBatch.getJSONArray("changes").get(it) }))
                same((request("receive", "b", obj("batch" to reverse)) as JSONObject).getJSONArray("blocks"), repaired.getJSONArray("blocks"), "reversed repair"); request("receive", "b", obj("batch" to repairedBatch))
                val repairedSave = save("r"); val repairedReceipt = receipt("r"); val redo = request("redo", "r", error = "writingRecoveryRequired")
                acceptedUnchanged("r", repairedSave, repairedReceipt); request("restore", "rr", obj("snapshot" to repairedSave, "actorID" to "a")); request("restoreRecovery", "rr", obj("recovery" to redo), "writingRecoveryRequired")
                same((repair("rr") as JSONObject).getJSONArray("blocks"), repaired.getJSONArray("blocks"), "restarted Redo repair"); assertEquals(5, changes("rr").getJSONArray("changes").length())
                return obj("case" to caseName, "version" to version, "documentBytes" to bytes(expected), "acceptedBefore" to fingerprint(aSave), "pending" to fingerprint(proposal), "repaired" to fingerprint(repairedSave), "historyAfterSecondRepair" to 5, "peerMetadataAndRichPreserved" to true)
            }
            if (caseName == "retained-exact-over") {
                create("author", "a"); listOf("one", "two", "three", "four").forEach { field("author", "history", it) }; val template = changes("author"); val sourceChanges = template.getJSONArray("changes")
                same(array((0 until sourceChanges.length()).map { sourceChanges.getJSONObject(it).getJSONObject("id") }), array((1..4).map { obj("counter" to it, "actor" to "a") }), "real authored template IDs")
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
                val sizes = listOf(quarter, quarter, quarter, payload - 3 * quarter); val exact = make(sizes); val exactBytes = bytes(exact); assertEquals(64_000_000L, exactBytes + reserve)
                create("receiver", "a"); val accepted = request("receive", "receiver", obj("batch" to exact)) as JSONObject; rich(accepted)
                assertEquals("3".repeat(sizes[3]), accepted.getJSONArray("blocks").getJSONObject(0).getJSONObject("consumer").getString("history"))
                val acceptedSave = save("receiver"); val acceptedReceipt = receipt("receiver"); assertTrue(bytes(acceptedSave) <= 64_000_000)
                same((request("restore", "restarted", obj("snapshot" to acceptedSave, "actorID" to "a")) as JSONObject).getJSONArray("blocks"), accepted.getJSONArray("blocks"), "exact save reopens"); same(receipt("restarted"), acceptedReceipt, "receipt reopens")
                create("stopped", "b"); val partial = obj("version" to version, "documentID" to documentID, "epoch" to epoch, "baseline" to template.getJSONObject("baseline"), "changes" to array((0..2).map { exact.getJSONArray("changes").get(it) }))
                request("receive", "stopped", obj("batch" to partial)); val stoppedSave = save("stopped"); val stoppedReceipt = receipt("stopped"); val over = make(sizes.take(3) + (sizes[3] + 1)); assertEquals(64_000_001L, bytes(over) + reserve)
                request("receive", "stopped", obj("batch" to over), "recoveryCapacityExceeded"); acceptedUnchanged("stopped", stoppedSave, stoppedReceipt); assertEquals(JSONObject.NULL, request("mergeRecovery", "stopped"))
                request("restore", "resumed", obj("snapshot" to stoppedSave, "actorID" to "b")); val callerArchive = clone(over)
                request("receive", "resumed", obj("batch" to callerArchive), "recoveryCapacityExceeded"); acceptedUnchanged("resumed", stoppedSave, stoppedReceipt)
                val cutoverEpoch = "cutover-v$version"; create("cutover", "b", (request("document", "resumed") as JSONObject).getJSONArray("blocks"), obj("epoch" to cutoverEpoch))
                field("cutover", "left", "after-cutover"); assertEquals(1, receipt("cutover").getJSONArray("received").length()); request("receive", "cutover", obj("batch" to callerArchive), "differentDocument")
                val cutoverSave = save("cutover"); val stale = obj("version" to version, "documentID" to documentID, "epoch" to epoch, "baseline" to cutoverSave.getJSONObject("baseline"), "changes" to JSONArray())
                request("receive", "cutover", obj("batch" to stale), "incompatibleEpoch")
                same((request("restore", "cutover-reopened", obj("snapshot" to cutoverSave, "actorID" to "b")) as JSONObject).getJSONArray("blocks"), (request("document", "cutover") as JSONObject).getJSONArray("blocks"), "cutover save")
                return obj("case" to caseName, "version" to version, "retainedBytes" to exactBytes, "reserveBytes" to reserve, "exactCapacityBytes" to 64_000_000, "rejectedCapacityBytes" to 64_000_001, "accepted" to fingerprint(acceptedSave), "callerOwnedRejected" to fingerprint(callerArchive), "stoppedReceipt" to stoppedReceipt, "cutoverEpoch" to cutoverEpoch)
            }
            val roots = if (caseName == "roots-exact") 9_998 else 9_999; val baseline = JSONArray().put(base.getJSONObject(0)); for (i in 1 until roots) baseline.put(obj("id" to "root-$i", "type" to "paragraph", "content" to array(listOf(text("")))))
            create("a", "a", baseline); create("b", "b", baseline); val last = obj("baseline" to obj("blockID" to "root-${roots - 1}", "path" to JSONArray()))
            val ownNode = obj("id" to "A", "type" to "paragraph", "content" to array(listOf(text("author"))))
            val peerNode = obj("id" to "B", "type" to "toggle", "summary" to array(listOf(text("peer 東京😀"))), "children" to array(listOf(obj("id" to "peer-child", "type" to "paragraph", "content" to base.getJSONObject(0).getJSONArray("content"), "consumer" to obj("id" to "peer-opaque")))), "consumer" to obj("id" to "B-opaque"))
            request("insertCollectionNodes", "a", obj("values" to array(listOf(ownNode)), "collection" to obj("field" to "blocks"), "after" to last))
            request("insertCollectionNodes", "b", obj("values" to array(listOf(peerNode)), "collection" to obj("field" to "blocks"), "after" to last))
            val peerAddress = obj("blockID" to "B", "path" to JSONArray()); val childAddress = obj("blockID" to "B", "path" to array(listOf("children", "peer-child")))
            val peerIdentity = request("node", "b", obj("address" to peerAddress)); val childIdentity = request("node", "b", obj("address" to childAddress))
            val aSave = save("a"); val bSave = save("b"); val aReceipt = receipt("a"); val bReceipt = receipt("b"); val aBatch = changes("a"); val bBatch = changes("b")
            fun peerIn(snapshot: JSONObject): JSONObject = (0 until snapshot.getJSONArray("blocks").length()).map { snapshot.getJSONArray("blocks").getJSONObject(it) }.single { it.getString("id") == "B" }
            fun check(snapshot: JSONObject) { assertEquals(10_000, snapshot.getJSONArray("blocks").length()); rich(snapshot); same(peerIn(snapshot), peerNode, "peer subtree/metadata") }
            if (roots == 9_998) {
                val combined = request("receive", "a", obj("batch" to bBatch)) as JSONObject; check(combined); same((request("receive", "b", obj("batch" to changes("a"))) as JSONObject).getJSONArray("blocks"), combined.getJSONArray("blocks"), "exact root union"); request("receive", "a", obj("batch" to bBatch))
                val acceptedSave = save("a"); request("restore", "r", obj("snapshot" to acceptedSave, "actorID" to "a")); val undone = request("undo", "r") as JSONObject
                assertEquals(9_999, undone.getJSONArray("blocks").length()); same(peerIn(undone), peerNode, "peer subtree after Undo"); same((request("redo", "r") as JSONObject).getJSONArray("blocks"), combined.getJSONArray("blocks"), "root Redo")
                return obj("case" to caseName, "version" to version, "rootBlocks" to 10_000, "nestedPeerChildren" to 1, "accepted" to fingerprint(acceptedSave), "peerIdentity" to peerIdentity, "childIdentity" to childIdentity, "authorUndoRootBlocks" to 9_999)
            }
            val proposal = request("receive", "a", obj("batch" to bBatch), "writingRecoveryRequired") as JSONObject
            same(request("receive", "b", obj("batch" to aBatch), "writingRecoveryRequired"), proposal, "root proposals"); same(request("receive", "a", obj("batch" to bBatch), "writingRecoveryRequired"), proposal, "root duplicate pending")
            assertEquals("schemaConstraint", proposal.getString("reason")); acceptedUnchanged("a", aSave, aReceipt); acceptedUnchanged("b", bSave, bReceipt)
            request("restore", "r", obj("snapshot" to aSave, "actorID" to "a")); request("restoreRecovery", "r", obj("recovery" to proposal), "writingRecoveryRequired"); repair("r", "b"); acceptedUnchanged("r", aSave, aReceipt); same(request("mergeRecovery", "r"), proposal, "failed root repair")
            val repaired = repair("r") as JSONObject; check(repaired); assertTrue((0 until repaired.getJSONArray("blocks").length()).none { repaired.getJSONArray("blocks").getJSONObject(it).getString("id") == "A" })
            same(request("node", "r", obj("address" to peerAddress)), peerIdentity, "peer origin"); same(request("node", "r", obj("address" to childAddress)), childIdentity, "child origin")
            val batch = changes("r"); assertEquals(3, batch.getJSONArray("changes").length()); val reverse = clone(batch); reverse.put("changes", array((0 until batch.getJSONArray("changes").length()).reversed().map { batch.getJSONArray("changes").get(it) }))
            request("receive", "b", obj("batch" to reverse)); request("receive", "b", obj("batch" to batch)); val repairedSave = save("r"); val repairedReceipt = receipt("r"); val redo = request("redo", "r", error = "writingRecoveryRequired")
            acceptedUnchanged("r", repairedSave, repairedReceipt); request("restore", "rr", obj("snapshot" to repairedSave, "actorID" to "a")); request("restoreRecovery", "rr", obj("recovery" to redo), "writingRecoveryRequired")
            same((repair("rr") as JSONObject).getJSONArray("blocks"), repaired.getJSONArray("blocks"), "root restarted Redo repair"); assertEquals(5, changes("rr").getJSONArray("changes").length())
            return obj("case" to caseName, "version" to version, "rejectedRootBlocks" to 10_001, "repairedRootBlocks" to 10_000, "pending" to fingerprint(proposal), "repaired" to fingerprint(repairedSave), "peerIdentity" to peerIdentity, "childIdentity" to childIdentity, "historyAfterSecondRepair" to 5)
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
