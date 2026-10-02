package studio.seventwo.blockeditor

import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import org.json.JSONArray
import org.json.JSONObject
import java.io.Closeable
import java.util.UUID

/** Stable origin fields and atom keys stay opaque to the host. */
data class WritingBlockTarget(val type: String, val level: Int? = null, val style: String? = null, val variant: String? = null) {
    internal fun wire() = JSONObject().put("type", type).also { value ->
        level?.let { value.put("level", it) }; style?.let { value.put("style", it) }; variant?.let { value.put("variant", it) }
    }
}
class WritingPosition internal constructor(value: JSONObject) {
    internal val wire = NativeJsonTransport.copy(value)
    val documentID: String get() = wire.getString("documentID")
    val epoch: String get() = wire.getString("epoch")
    fun export(): JSONObject = NativeJsonTransport.copy(wire)
    companion object { fun restore(value: JSONObject) = WritingPosition(value) }
}
class WritingAddress internal constructor(value: JSONObject) {
    internal val wire = NativeJsonTransport.copy(value)
    constructor(blockID: String, path: List<String> = listOf("content")) : this(JSONObject().put("blockID", blockID).put("path", JSONArray(path)))
    val blockID: String get() = wire.getString("blockID")
    val path: List<String> get() = wire.getJSONArray("path").let { values -> (0 until values.length()).map { values.getString(it) } }
    fun export(): JSONObject = NativeJsonTransport.copy(wire)
}
class WritingTextRange internal constructor(value: JSONObject) {
    /** A shared range can span different nested fields in the same epoch. */
    constructor(start: WritingPosition, end: WritingPosition) : this(JSONObject().put("start", start.export()).put("end", end.export()))
    internal val wire = NativeJsonTransport.copy(value)
    val start: WritingPosition get() = WritingPosition(wire.getJSONObject("start"))
    val end: WritingPosition get() = WritingPosition(wire.getJSONObject("end"))
}
class WritingSelection(val nodes: List<NodeIdentity> = emptyList(), val text: List<WritingTextRange> = emptyList()) {
    internal fun wire() = JSONObject().put("nodes", JSONArray(nodes.map { it.wire }))
        .put("text", JSONArray(text.map { it.wire }))
    companion object {
        internal fun restore(value: JSONObject): WritingSelection {
            val nodes = value.getJSONArray("nodes"); val text = value.getJSONArray("text")
            return WritingSelection((0 until nodes.length()).map { NodeIdentity(nodes.getJSONObject(it)) },
                (0 until text.length()).map { WritingTextRange(text.getJSONObject(it)) })
        }
    }
}
class WritingCopy internal constructor(value: JSONObject) {
    private val wire = NativeJsonTransport.copy(value)
    fun export(): JSONObject = NativeJsonTransport.copy(wire)
}
/** Inert ordered clipboard data. Core paste validates imported payloads. */
class WritingClipboard private constructor(value: JSONObject) {
    internal val wire = NativeJsonTransport.copy(value)
    fun export(): JSONObject = NativeJsonTransport.copy(wire)
    companion object { fun restore(value: JSONObject) = WritingClipboard(value) }
}
data class WritingPastePolicy(val allowedBlockTypes: Set<String>? = null, val allowedMarkTypes: Set<String>? = null, val allowAssetMetadata: Boolean = false) {
    internal fun wire() = JSONObject().put("allowAssetMetadata", allowAssetMetadata).also { value ->
        allowedBlockTypes?.let { value.put("allowedBlockTypes", JSONArray(it.sorted())) }
        allowedMarkTypes?.let { value.put("allowedMarkTypes", JSONArray(it.sorted())) }
    }
}
class WritingImportResult internal constructor(value: JSONObject) {
    val clipboard = WritingClipboard.restore(value.getJSONObject("clipboard"))
    private fun strings(value: JSONObject, key: String): Set<String>? = value.optJSONArray(key)?.let { array ->
        (0 until array.length()).map { array.getString(it) }.toSet()
    }
    private val policy = value.getJSONObject("effectivePastePolicy")
    val effectivePastePolicy = WritingPastePolicy(strings(policy, "allowedBlockTypes"), strings(policy, "allowedMarkTypes"), policy.getBoolean("allowAssetMetadata"))
    val suggestedHostBlockTypes = strings(value, "suggestedHostBlockTypes")
}
data class ResolvedWritingPosition(val address: WritingAddress, val offset: Int)
class WritingBatch private constructor(value: JSONObject) {
    internal val wire = NativeJsonTransport.copy(value)
    init { require(wire.getInt("version") in setOf(3, 4, 5, 6) && wire.getString("epoch").isNotEmpty()) }
    val documentID: String get() = wire.getString("documentID")
    val epoch: String get() = wire.getString("epoch")
    fun export(): JSONObject = NativeJsonTransport.copy(wire)
    companion object { fun restore(value: JSONObject) = WritingBatch(value) }
}
class WritingReceipt internal constructor(value: JSONObject) {
    internal val wire = NativeJsonTransport.copy(value)
    fun export(): JSONObject = NativeJsonTransport.copy(wire)
}
class WritingRecovery internal constructor(value: JSONObject) {
    private val wire = NativeJsonTransport.copy(value)
    val reason: MergeRecoveryReason = when (wire.getString("reason")) {
        "identityConflict" -> MergeRecoveryReason.IDENTITY_CONFLICT
        "schemaConstraint" -> MergeRecoveryReason.SCHEMA_CONSTRAINT
        else -> throw IllegalArgumentException("Unknown writing recovery reason")
    }
    val batch: WritingBatch get() = WritingBatch.restore(wire.getJSONObject("batch"))
    fun export(): JSONObject = NativeJsonTransport.copy(wire)
    companion object { fun restore(value: JSONObject) = WritingRecovery(value) }
}
class WritingRecoveryException(val recovery: WritingRecovery) : IllegalStateException("Writing recovery required")

/** Explicit writing session for separately created v3/v4/v5 epochs; legacy EditorSession creation and restore are unchanged. */
class WritingSession private constructor(private val handle: String, initial: JSONObject) : Closeable {
    var snapshot: JSONObject by mutableStateOf(initial)
        private set
    var onChange: ((JSONObject) -> Unit)? = null
    var onWillReceive: (() -> (() -> Unit)?)? = null
    private var closed = false
    private var nativeInputOwner: Any? = null
    internal fun acquireNativeInputOwner(owner: Any) {
        check(!closed && nativeInputOwner == null) { "One native input owner per writing session" }
        nativeInputOwner = owner
    }
    internal fun releaseNativeInputOwner(owner: Any) {
        check(nativeInputOwner === owner); nativeInputOwner = null
    }
    private val listeners = linkedSetOf<() -> Unit>()
    private val beforeReceive = linkedSetOf<() -> (() -> Unit)?>()
    internal fun subscribe(listener: () -> Unit): () -> Unit {
        check(!closed); listeners.add(listener); return { listeners.remove(listener); Unit }
    }
    internal fun subscribeBeforeReceive(listener: () -> (() -> Unit)?): () -> Unit {
        check(!closed); beforeReceive.add(listener); return { beforeReceive.remove(listener); Unit }
    }
    private var holds = 0
    private var draining = false
    private var reservedCount = 0
    private var reservedBytes = 0
    private val deferred = mutableListOf<String>()
    companion object {
        fun create(documentID: String, actorID: String, epoch: String, blocks: JSONArray = JSONArray()): WritingSession {
            val handle = UUID.randomUUID().toString()
            val result = NativeEngine.call(JSONObject().put("command", "create").put("session", handle)
                .put("documentID", documentID).put("actorID", actorID).put("epoch", epoch)
                .put("collaborationVersion", 3).put("blocks", blocks)).getJSONObject("value")
            return WritingSession(handle, result)
        }
        /** Explicit isolated schema-conversion epoch; never mix v3 writers. */
        fun createV4(documentID: String, actorID: String, epoch: String, blocks: JSONArray = JSONArray()): WritingSession {
            val handle = UUID.randomUUID().toString()
            val result = NativeEngine.call(JSONObject().put("command", "create").put("session", handle)
                .put("documentID", documentID).put("actorID", actorID).put("epoch", epoch)
                .put("collaborationVersion", 4).put("blocks", blocks)).getJSONObject("value")
            return WritingSession(handle, result)
        }
        /** Explicit epoch reserved for structured splice. Archive old writers first; never mix v3/v4 writers. */
        fun createV5(documentID: String, actorID: String, epoch: String, blocks: JSONArray = JSONArray()): WritingSession {
            val handle = UUID.randomUUID().toString()
            val result = NativeEngine.call(JSONObject().put("command", "create").put("session", handle)
                .put("documentID", documentID).put("actorID", actorID).put("epoch", epoch)
                .put("collaborationVersion", 5).put("blocks", blocks)).getJSONObject("value")
            return WritingSession(handle, result)
        }
        /** Explicit retained-endpoint splice epoch; archive and stop old writers first. */
        fun createV6(documentID: String, actorID: String, epoch: String, blocks: JSONArray = JSONArray()): WritingSession {
            val handle = UUID.randomUUID().toString()
            val result = NativeEngine.call(JSONObject().put("command", "create").put("session", handle)
                .put("documentID", documentID).put("actorID", actorID).put("epoch", epoch)
                .put("collaborationVersion", 6).put("blocks", blocks)).getJSONObject("value")
            return WritingSession(handle, result)
        }
        fun restore(snapshot: WritingBatch, actorID: String): WritingSession {
            val handle = UUID.randomUUID().toString()
            return WritingSession(handle, NativeEngine.call(JSONObject().put("command", "restore").put("session", handle)
                .put("snapshot", snapshot.wire).put("actorID", actorID)).getJSONObject("value"))
        }
        /** Archive JSON uses base64 snapshot bytes; activation requires explicit host acknowledgments. */
        fun cutoverToV3(archive: JSONObject, actorID: String, oldWritersStopped: Boolean, archivePersisted: Boolean, resetUndoAcknowledged: Boolean): WritingSession {
            val handle = UUID.randomUUID().toString()
            return WritingSession(handle, NativeEngine.call(JSONObject().put("command", "cutoverToV3").put("session", handle)
                .put("archive", archive).put("actorID", actorID).put("oldWritersStopped", oldWritersStopped)
                .put("archivePersisted", archivePersisted).put("resetUndoAcknowledged", resetUndoAcknowledged)).getJSONObject("value"))
        }
    }
    private fun call(command: String, args: JSONObject = JSONObject()): Any {
        check(!closed) { "Writing session is closed" }
        return NativeEngine.call(args.put("command", command).put("session", handle)).get("value")
    }
    private fun publish(value: JSONObject) { snapshot = value; listeners.toList().forEach { it() }; onChange?.invoke(value) }
    private fun command(name: String, args: JSONObject): WritingPosition {
        val result = call(name, args) as JSONObject
        publish(result.getJSONObject("snapshot"))
        return WritingPosition(result.getJSONObject("position"))
    }
    private fun range(address: WritingAddress, start: Int, end: Int) = JSONObject().put("address", address.wire).put("start", start).put("end", end)
    fun node(address: NodeAddress): NodeIdentity = NodeIdentity(call("node", JSONObject().put("address", address.wire())) as JSONObject)
    fun nodeAddress(identity: NodeIdentity): NodeAddress {
        val value = call("nodeAddress", JSONObject().put("identity", identity.wire)) as JSONObject
        val path = value.getJSONArray("path")
        return NodeAddress(value.getString("blockID"), (0 until path.length()).map { path.getString(it) })
    }
    fun textAddress(identity: NodeIdentity, field: String = "content") = WritingAddress(call("textAddress", JSONObject().put("identity", identity.wire).put("field", field)) as JSONObject)
    fun position(address: WritingAddress, offset: Int, affinity: PositionAffinity = PositionAffinity.BEFORE) =
        WritingPosition(call("position", JSONObject().put("address", address.wire).put("offset", offset).put("affinity", affinity.wireValue)) as JSONObject)
    fun resolvePosition(position: WritingPosition): ResolvedWritingPosition {
        val result = call("resolvePosition", JSONObject().put("position", position.wire)) as JSONObject
        return ResolvedWritingPosition(WritingAddress(result.getJSONObject("address")), result.getInt("offset"))
    }
    fun setComposing(active: Boolean) { call("composition", JSONObject().put("active", active)) }
    fun replaceText(address: WritingAddress, start: Int, end: Int, text: String, marks: JSONArray? = null): WritingPosition =
        command("replaceText", range(address, start, end).put("text", text).also { if (marks != null) it.put("marks", marks) })
    fun softBreak(address: WritingAddress, start: Int, end: Int): WritingPosition = command("softBreak", range(address, start, end))
    fun splitParagraph(address: WritingAddress, start: Int, end: Int, newBlockID: String): WritingPosition = command("splitParagraph", range(address, start, end).put("newBlockID", newBlockID))
    fun selectedText(address: WritingAddress, start: Int, end: Int) = WritingTextRange(call("selectedText", range(address, start, end)) as JSONObject)
    fun selection(anchor: WritingPosition, focus: WritingPosition) = WritingSelection.restore(call("writingSelection", JSONObject().put("anchor", anchor.wire).put("focus", focus.wire)) as JSONObject)
    fun copySelection(selection: WritingSelection) = WritingCopy(call("copySelection", JSONObject().put("selection", selection.wire())) as JSONObject)
    fun copyClipboard(selection: WritingSelection) = WritingClipboard.restore(call("copyClipboard", JSONObject().put("selection", selection.wire())) as JSONObject)
    fun clipboardText(text: String, format: String = "inline") = WritingClipboard.restore(call("clipboardText", JSONObject().put("text", text).put("format", format)) as JSONObject)
    fun normalizeForImport(clipboard: WritingClipboard, policy: WritingPastePolicy = WritingPastePolicy()) =
        WritingImportResult(call("normalizeForImport", JSONObject().put("clipboard", clipboard.wire).put("policy", policy.wire())) as JSONObject)
    fun pasteInline(clipboard: WritingClipboard, range: WritingTextRange, policy: WritingPastePolicy = WritingPastePolicy()): WritingPosition {
        check(holds == 0) { "Commit composition before pasting" }
        return command("pasteInline", JSONObject().put("clipboard", clipboard.wire).put("range", range.wire).put("policy", policy.wire()))
    }
    fun pasteSelection(clipboard: WritingClipboard, range: WritingTextRange, policy: WritingPastePolicy = WritingPastePolicy()): WritingPosition {
        check(holds == 0) { "Commit composition before pasting" }
        return command("pasteSelection", JSONObject().put("clipboard", clipboard.wire).put("range", range.wire).put("policy", policy.wire()))
    }
    fun pasteBlocks(clipboard: WritingClipboard, range: WritingTextRange, policy: WritingPastePolicy = WritingPastePolicy()): WritingPosition {
        check(holds == 0) { "Commit composition before pasting" }
        return command("pasteBlocks", JSONObject().put("clipboard", clipboard.wire).put("range", range.wire).put("policy", policy.wire()))
    }
    fun pasteCollection(clipboard: WritingClipboard, collection: NodeCollection, after: NodeIdentity? = null, policy: WritingPastePolicy = WritingPastePolicy()): WritingSelection {
        check(holds == 0) { "Commit composition before pasting" }
        val result = call("pasteCollection", JSONObject().put("clipboard", clipboard.wire).put("collection", collection.wire)
            .put("after", after?.wire ?: JSONObject.NULL).put("policy", policy.wire())) as JSONObject
        publish(result.getJSONObject("snapshot"))
        return WritingSelection.restore(result.getJSONObject("selection"))
    }
    fun deleteSelection(selection: WritingSelection): WritingSelection {
        val result = call("deleteSelection", JSONObject().put("selection", selection.wire())) as JSONObject
        publish(result.getJSONObject("snapshot")); return WritingSelection.restore(result.getJSONObject("selection"))
    }
    fun moveSelection(selection: WritingSelection, collection: NodeCollection, after: NodeIdentity? = null) = batch("moveSelection", selection, collection, after)
    fun duplicateSelection(selection: WritingSelection, collection: NodeCollection, after: NodeIdentity? = null) = batch("duplicateSelection", selection, collection, after)
    private fun batch(name: String, selection: WritingSelection, collection: NodeCollection, after: NodeIdentity?): WritingSelection {
        val result = call(name, JSONObject().put("selection", selection.wire()).put("collection", collection.wire)
            .put("after", after?.wire ?: JSONObject.NULL)) as JSONObject
        publish(result.getJSONObject("snapshot")); return WritingSelection.restore(result.getJSONObject("selection"))
    }
    fun mergeParagraphs(left: NodeIdentity, right: NodeIdentity): WritingPosition = command("mergeParagraphs", JSONObject().put("left", left.wire).put("right", right.wire))
    fun collectionNodes(collection: NodeCollection): List<NodeIdentity> {
        val result = call("collectionNodes", JSONObject().put("collection", collection.wire)) as JSONArray
        return (0 until result.length()).map { NodeIdentity(result.getJSONObject(it)) }
    }
    fun insertCollectionNodes(values: JSONArray, collection: NodeCollection, after: NodeIdentity? = null): WritingSelection {
        val result = call("insertCollectionNodes", JSONObject().put("values", values).put("collection", collection.wire)
            .put("after", after?.wire ?: JSONObject.NULL)) as JSONObject
        publish(result.getJSONObject("snapshot")); return WritingSelection.restore(result.getJSONObject("selection"))
    }
    /** Scalar metadata only; the shared engine rejects text, identities and collection replacement. */
    fun setNodeField(identity: NodeIdentity, path: List<String>, value: Any?) {
        publish(call("setNodeField", JSONObject().put("identity", identity.wire).put("path", JSONArray(path))
            .put("value", value ?: JSONObject.NULL)) as JSONObject)
    }
    fun setAllowedBlockTypes(types: Set<String>?) { publish(call("allowedBlockTypes", JSONObject().put("types", types?.let { JSONArray(it.toList()) } ?: JSONObject.NULL)) as JSONObject) }
    fun convertBlock(address: WritingAddress, offset: Int, target: WritingBlockTarget): WritingPosition = command("convertBlock", JSONObject().put("address", address.wire).put("offset", offset).put("target", target.wire()))
    fun markdownShortcut(address: WritingAddress, offset: Int): WritingPosition = command("markdownShortcut", JSONObject().put("address", address.wire).put("offset", offset))
    fun enterListItem(address: WritingAddress, start: Int, end: Int, newItemID: String): WritingPosition = command("enterListItem", range(address, start, end).put("newItemID", newItemID))
    fun format(address: WritingAddress, start: Int, end: Int, markType: String, mark: JSONObject?) {
        publish(call("format", range(address, start, end).put("markType", markType).put("mark", mark ?: JSONObject.NULL)) as JSONObject)
    }
    fun undo() { publish(call("undo") as JSONObject) }
    fun redo() { publish(call("redo") as JSONObject) }
    fun save(): WritingBatch = WritingBatch.restore(call("save") as JSONObject)
    fun syncState() = WritingReceipt(call("syncState") as JSONObject)
    fun changes(since: WritingReceipt? = null): WritingBatch = WritingBatch.restore(call("changes", JSONObject().also { if (since != null) it.put("since", since.wire) }) as JSONObject)
    fun mergeRecovery(): WritingRecovery? = (call("mergeRecovery") as? JSONObject)?.let { WritingRecovery(it) }
    fun restoreRecovery(recovery: WritingRecovery) { publish(call("restoreRecovery", JSONObject().put("recovery", recovery.export())) as JSONObject) }
    fun repairUndo(counter: Long, actor: String) {
        check(holds == 0) { "Commit composition before repairing writing" }
        publish(call("repairWritingUndo", JSONObject().put("target", JSONObject().put("counter", counter).put("actor", actor))) as JSONObject)
    }
    fun repairRedo(counter: Long, actor: String) {
        check(holds == 0) { "Commit composition before repairing writing" }
        publish(call("repairWritingRedo", JSONObject().put("target", JSONObject().put("counter", counter).put("actor", actor))) as JSONObject)
    }
    fun repairText(identity: NodeIdentity, field: String, text: String) {
        check(holds == 0) { "Commit composition before repairing writing" }
        publish(call("repairWritingText", JSONObject().put("identity", identity.wire).put("field", field).put("text", text)) as JSONObject)
    }
    fun exportDeferredChanges(): List<WritingBatch> = deferred.map { WritingBatch.restore(JSONObject(it)) }
    fun deferRemoteChanges(): () -> Unit {
        check(!closed); holds++; var released = false
        return finish@{ if (released || closed) return@finish; released = true; if (--holds == 0) retryDeferredChanges() }
    }
    fun retryDeferredChanges() {
        check(!closed && holds == 0 && !draining)
        val pending = deferred.toList(); deferred.clear()
        draining = true; reservedCount = pending.size; reservedBytes = pending.sumOf { it.toByteArray(Charsets.UTF_8).size }
        val failed = mutableListOf<String>(); var failure: Exception? = null
        try {
            for (packet in pending) {
                var retained = false
                try { receive(WritingBatch.restore(JSONObject(packet))) } catch (error: Exception) {
                    if (error !is WritingRecoveryException) { failed.add(packet); retained = true }
                    if (failure == null) failure = error
                }
                if (!retained) { reservedCount--; reservedBytes -= packet.toByteArray(Charsets.UTF_8).size }
            }
            deferred.addAll(0, failed)
        } finally { draining = false; reservedCount = 0; reservedBytes = 0 }
        if (failure != null && (failed.isNotEmpty() || mergeRecovery() != null)) throw failure
    }
    fun receive(batch: WritingBatch) {
        check(!closed)
        if (holds > 0) {
            val packet = batch.wire.toString()
            val bytes = packet.toByteArray(Charsets.UTF_8).size
            check(deferred.size + reservedCount < 64 && bytes + reservedBytes + deferred.sumOf { it.toByteArray(Charsets.UTF_8).size } <= 64_000_000)
            deferred.add(packet); return
        }
        val cleanup = mutableListOf<() -> Unit>()
        val result = try {
            onWillReceive?.invoke()?.let { cleanup.add(it) }
            beforeReceive.toList().forEach { it()?.let { rollback -> cleanup.add(rollback) } }
            call("receive", JSONObject().put("batch", batch.wire)) as JSONObject
        } catch (error: Exception) {
            cleanup.asReversed().forEach { try { it() } catch (_: Exception) { } }; throw error
        }
        publish(result)
    }
    override fun close() = close(pendingStateRetained = false)
    fun close(pendingStateRetained: Boolean) {
        if (!closed) { check(nativeInputOwner == null) { "Dispose the native writing input owner before closing its session" }; check(!draining && (deferred.isEmpty() || pendingStateRetained)) { "Retain deferred changes before closing" }; call("close"); closed = true; listeners.clear(); beforeReceive.clear(); onChange = null; onWillReceive = null }
    }
}
