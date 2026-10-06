package studio.seventwo.blockeditor

import android.os.Handler
import android.os.Looper
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import org.json.JSONArray
import org.json.JSONObject
import java.io.Closeable
import java.util.UUID

/** Explicit protocol-7 JNI session. Use it on its creating thread, normally the UI thread.
 * Accepted saves, local input/history, recovery, deferred packets and provider state are separate.
 * No view, OS publication, provider launch or durable storage activation is implicit. */
class ModernSession private constructor(private val handle: String, initial: JSONObject) : Closeable {
    private val owner = Thread.currentThread()
    private var closed = false
    private val listeners = linkedSetOf<() -> Unit>()
    var snapshot: ModernSnapshot by mutableStateOf(ModernSnapshot(initial))
        private set
    /** Report UI observer failures after accepted publication, without failing the committed edit. */
    var onListenerError: (Throwable) -> Unit = { failure -> Handler(Looper.getMainLooper()).post { throw failure } }

    companion object {
        fun create(document: ModernDocument, actorID: String, epoch: String, policy: ModernPolicy = ModernPolicy()): ModernSession {
            val handle = UUID.randomUUID().toString()
            val request = modernObject("command" to "createModern", "session" to handle, "collaborationVersion" to 7,
                "documentID" to document.documentID, "actorID" to actorID, "epoch" to epoch, "document" to document)
            policy.apply(request)
            return ModernSession(handle, NativeEngine.call(request).getJSONObject("value"))
        }
        fun restore(saved: ModernPayload, actorID: String, policy: ModernPolicy = ModernPolicy()): ModernSession {
            val handle = UUID.randomUUID().toString()
            val request = modernObject("command" to "restoreModern", "session" to handle, "snapshot" to saved, "actorID" to actorID)
            policy.apply(request)
            return ModernSession(handle, NativeEngine.call(request).getJSONObject("value"))
        }
        fun fromCutover(archiveID: String, actorID: String, acknowledgments: ModernCutoverAcknowledgments): ModernCutoverResult {
            val handle = UUID.randomUUID().toString()
            val request = modernObject("command" to "cutoverToModern", "session" to handle, "archiveID" to archiveID, "actorID" to actorID,
                "oldWritersStopped" to acknowledgments.oldWritersStopped, "archivePersisted" to acknowledgments.archivePersisted, "resetUndoAcknowledged" to acknowledgments.resetUndoAcknowledged)
            val value = NativeEngine.call(request).getJSONObject("value")
            return ModernCutoverResult(ModernSession(handle, value), ModernPayload.restore(modernObject("originMapping" to value.getJSONArray("originMapping"))))
        }
    }
    private fun assertThread() { check(Thread.currentThread() === owner) { "Modern session must be used on its creating thread" } }
    private fun assertOpen() { assertThread(); check(!closed) { "Modern session is closed" } }
    fun subscribe(listener: () -> Unit): () -> Unit {
        assertOpen(); listeners.add(listener)
        return { assertThread(); listeners.remove(listener); Unit }
    }
    private fun publish(value: JSONObject) {
        snapshot = ModernSnapshot(value)
        listeners.toList().forEach { listener ->
            try { listener() } catch (failure: Throwable) {
                try { onListenerError(failure) } catch (reportFailure: Throwable) { Handler(Looper.getMainLooper()).post { throw reportFailure } }
            }
        }
    }
    private fun call(command: String, args: JSONObject = JSONObject()): Any {
        assertOpen()
        val request = modernObject("command" to command, "session" to handle)
        args.keys().forEach { key -> request.put(key, args.get(key)) }
        try { return NativeEngine.call(request).get("value") }
        catch (failure: ModernRecoveryException) {
            publish(NativeEngine.call(modernObject("command" to "modernSnapshot", "session" to handle)).getJSONObject("value"))
            throw failure
        }
    }
    private fun objectCall(command: String, args: JSONObject = JSONObject()) = call(command, args) as JSONObject
    private fun update(command: String, args: JSONObject = JSONObject()) { publish(objectCall(command, args)) }
    private fun executeRequest(request: JSONObject): ModernResult {
        val scope = snapshot.syncState
        request.put("documentID", scope.documentID).put("epoch", scope.epoch)
        val value = objectCall("modernCommand", modernObject("request" to request))
        val result = ModernResult(value)
        publish(value)
        return result
    }
    fun execute(command: ModernCommand): ModernResult = executeRequest(command.wire())
    /** This override applies only to author commands; history commands restore their stored input. */
    fun execute(command: ModernCommand.Author, historySelection: ModernLocalSelection?): ModernResult =
        executeRequest(command.wire().put("historySelection", historySelection?.export() ?: JSONObject.NULL))
    fun insertionValue(descriptorID: String, id: String, childIDs: List<String> = emptyList()) = ModernPayload.restore(objectCall("modernInsertionValue", modernObject("descriptorID" to descriptorID, "id" to id, "childIDs" to JSONArray(childIDs))))
    fun logicalFields(collapsed: List<ModernNodeID> = emptyList(), includingTitle: Boolean = true): List<ModernField> = (call("modernLogicalFields", modernObject("collapsed" to JSONArray(collapsed.map { it.export() }), "includingTitle" to includingTitle)) as JSONArray).let { array -> (0 until array.length()).map { val field = array.getJSONObject(it); ModernField(ModernNodeID.restore(field.getJSONObject("node")), field.getString("name")) } }
    fun captureTextSpan(start: ModernPosition, end: ModernPosition, collapsed: List<ModernNodeID> = emptyList()): List<ModernTextRange> = (call("modernCaptureTextSpan", modernObject("start" to start, "end" to end, "collapsed" to modernArray(collapsed))) as JSONArray).let { values -> (0 until values.length()).map { ModernTextRange.restore(values.getJSONObject(it)) } }
    fun parentCollection(node: ModernNodeID): ModernCollection = ModernCollection.restore(call("modernParentCollection", modernObject("node" to node)) as JSONObject)
    fun insertionCatalog(query: String = ""): List<ModernInsertionDescriptor> = (call("modernInsertionCatalog", modernObject("query" to query)) as JSONArray).let { values -> (0 until values.length()).map { ModernInsertionDescriptor(values.getJSONObject(it)) } }
    fun availability(name: ModernCommandName) = ModernAvailability(objectCall("modernAvailability", modernObject("name" to name.wireValue)))
    fun captureTableTarget(table: ModernNodeID, row: ModernNodeID? = null, cell: ModernNodeID? = null) = ModernTableTarget(objectCall("modernCaptureTableTarget", modernObject("table" to table).also { value -> row?.let { value.put("row", it.export()) }; cell?.let { value.put("cell", it.export()) } }))
    fun captureCodeTarget(node: ModernNodeID) = ModernCodeTarget(objectCall("modernCaptureCodeTarget", modernObject("node" to node)))
    fun captureMediaTarget(node: ModernNodeID) = ModernMediaTarget(objectCall("modernCaptureMediaTarget", modernObject("node" to node)))
    fun retainAsyncResult(target: ModernAsyncTarget, metadata: ModernPayload, reason: String = "awaitingPersistence") = update("modernRetainAsyncResult", modernObject("target" to target, "metadata" to metadata, "reason" to reason))
    fun capabilities() = ModernCapabilities(objectCall("modernCapabilities"))
    fun save() = ModernPayload.restore(objectCall("modernSave"))
    fun changes(since: ModernReceipt? = null) = ModernBatch.restore(objectCall("modernChanges", JSONObject().also { value -> since?.let { value.put("since", it.export()) } }))
    fun receive(batch: ModernBatch) = update("modernReceive", modernObject("batch" to batch))
    fun recovery(): ModernRecovery? = (call("modernRecovery") as? JSONObject)?.let { ModernRecovery(it) }
    fun restoreRecovery(recovery: ModernRecovery) = update("modernRestoreRecovery", modernObject("recovery" to recovery))
    fun repairUndo(targets: List<ModernChangeID>) = update("modernRepairUndo", modernObject("targets" to JSONArray(targets.map { it.wire() })))
    fun repairRedo(targets: List<ModernChangeID>) = update("modernRepairRedo", modernObject("targets" to JSONArray(targets.map { it.wire() })))
    fun node(blockID: String, path: List<String> = emptyList()) = ModernNodeID.restore(objectCall("modernNode", modernObject("address" to modernObject("blockID" to blockID, "path" to JSONArray(path)))))
    fun nodes(collection: ModernCollection = ModernCollection.Blocks): List<ModernNodeID> = (call("modernNodes", modernObject("collection" to collection.wire())) as JSONArray).let { values -> (0 until values.length()).map { ModernNodeID.restore(values.getJSONObject(it)) } }
    fun field(node: ModernNodeID, name: String = "content"): ModernField { val value = objectCall("modernField", modernObject("node" to node, "name" to name)); return ModernField(ModernNodeID.restore(value.getJSONObject("node")), value.getString("name")) }
    fun text(field: ModernField) = call("modernText", modernObject("field" to field.wire())) as String
    fun position(field: ModernField, offset: Int, affinity: PositionAffinity = PositionAffinity.BEFORE) =
        ModernPosition(objectCall("modernPosition", modernObject("field" to field.wire(), "offset" to offset, "affinity" to affinity.wireValue)))
    fun resolvePosition(position: ModernPosition) = ModernResolvedPosition(objectCall("modernResolvePosition", modernObject("position" to position)))
    fun captureTextRange(field: ModernField, start: Int, end: Int) = ModernTextRange(objectCall("modernCaptureTextRange", modernObject("field" to field.wire(), "start" to start, "end" to end)))
    private fun boundary(command: String, collection: ModernCollection, after: ModernNodeID?) = ModernBoundary(objectCall(command,
        modernObject("collection" to collection.wire()).also { value -> after?.let { value.put("after", it.export()) } }))
    fun captureBoundary(collection: ModernCollection = ModernCollection.Blocks, after: ModernNodeID? = null) = boundary("modernCaptureBoundary", collection, after)
    fun capturePasteBoundary(collection: ModernCollection = ModernCollection.Blocks, after: ModernNodeID? = null) = boundary("modernCapturePasteBoundary", collection, after)
    fun captureListBoundary(collection: ModernCollection.Owned, after: ModernNodeID? = null) = boundary("modernCaptureListBoundary", collection, after)
    fun captureNodes(nodes: List<ModernNodeID>) = ModernNodes(objectCall("modernCaptureNodes", modernObject("nodes" to modernArray(nodes))))
    fun captureListNodes(nodes: List<ModernNodeID>) = ModernNodes(objectCall("modernCaptureListNodes", modernObject("nodes" to modernArray(nodes))))
    fun captureLocalNodes(nodes: List<ModernNodeID>) = ModernNodes(objectCall("modernCaptureLocalNodes", modernObject("nodes" to modernArray(nodes))))
    fun clipboardText(text: String, mode: String = "plain") = ModernClipboard.restore(objectCall("modernClipboard", modernObject("text" to text, "mode" to mode)))
    fun clipboardParts(parts: JSONArray) = ModernClipboard.restore(objectCall("modernClipboard", modernObject("parts" to parts)))
    fun copy(target: ModernDeleteTarget) = ModernClipboard.restore(objectCall("modernCopy", modernObject("target" to target)))
    fun prepareCut(target: ModernDeleteTarget) = ModernCutPreparation(objectCall("modernPrepareCut", modernObject("target" to target)))
    /** Supply the actual OS publication outcome. Preparation itself never deletes content. */
    fun finishCut(preparation: ModernCutPreparation, published: Boolean): ModernResult {
        val value = objectCall("modernFinishCut", modernObject("preparationID" to preparation.preparationID, "documentID" to preparation.documentID, "epoch" to preparation.epoch, "published" to published))
        val result = ModernResult(value); publish(value); return result
    }
    fun cancelCut(preparationID: String) = update("modernCancelCut", modernObject("preparationID" to preparationID))
    fun forgetCut(preparationID: String) = update("modernForgetCut", modernObject("preparationID" to preparationID))
    fun markState(range: ModernTextRange, type: String) = call("modernMarkState", modernObject("range" to range, "type" to type)) as String
    fun markState(ranges: List<ModernTextRange>, type: String) = call("modernMarkState", modernObject("ranges" to JSONArray(ranges.map { it.export() }), "type" to type)) as String
    fun semanticState(target: ModernSemanticTarget, kind: ModernSemanticKind) = ModernSemanticState(objectCall("modernSemanticState", modernObject("target" to target.wire(), "kind" to kind.wireValue)))
    fun beginAsyncBlock(node: ModernNodeID, requestID: String) = ModernAsyncTarget(objectCall("modernBeginAsyncBlock", modernObject("node" to node, "requestID" to requestID)))
    fun asyncRequests(): List<ModernAsyncRecord> = (call("modernAsyncRequests") as JSONArray).let { values -> (0 until values.length()).map { ModernAsyncRecord(values.getJSONObject(it)) } }
    fun exportAsyncRequests() = ModernAsyncArchive.restore(objectCall("modernExportAsyncRequests"))
    fun restoreAsyncRequests(archive: ModernAsyncArchive) = update("modernRestoreAsyncRequests", modernObject("archive" to archive))
    fun cancelAsyncBlock(target: ModernAsyncTarget) = update("modernCancelAsyncBlock", modernObject("target" to target))
    fun forgetAsyncBlock(target: ModernAsyncTarget) = update("modernForgetAsyncBlock", modernObject("target" to target))
    fun failAsyncBlock(target: ModernAsyncTarget, reason: String) = update("modernFailAsyncBlock", modernObject("target" to target, "reason" to reason))
    fun setComposing(active: Boolean) = update("modernComposition", modernObject("active" to active))
    fun setAuthoringPolicy(commands: Set<ModernCommandName>?) = update("modernSetAuthoringPolicy", modernObject("allowedCommands" to commands?.let { JSONArray(it.map { it.wireValue }.sorted()) }))
    fun setContentPolicy(blocks: Set<String>?, marks: Set<String>?) = update("modernSetContentPolicy", modernObject("allowedBlockTypes" to blocks?.let { JSONArray(it.sorted()) }, "allowedMarkTypes" to marks?.let { JSONArray(it.sorted()) }))
    fun setListPolicy(actions: Set<ModernListAction>?) = update("modernSetListPolicy", modernObject("allowedListActions" to actions?.let { JSONArray(it.map { it.wireValue }.sorted()) }))
    fun endTypingGroup() = update("modernEndTypingGroup")
    fun holdRemoteChanges(): () -> Unit {
        val hold = UUID.randomUUID().toString(); update("modernHoldRemote", modernObject("hold" to hold)); var released = false
        return { assertThread(); if (!released && !closed) { released = true; update("modernReleaseRemote", modernObject("hold" to hold)) } }
    }
    fun deferredChanges(): List<ModernBatch> = (call("modernDeferredChanges") as JSONArray).let { values -> (0 until values.length()).map { ModernBatch.restore(values.getJSONObject(it)) } }
    fun restoreDeferredChanges(packets: List<ModernBatch>) = update("modernRestoreDeferredChanges", modernObject("packets" to modernArray(packets)))
    fun retryDeferredChanges() = update("modernRetryDeferredChanges")
    fun setLocalSelection(selection: ModernLocalSelection?) = update("modernSetLocalSelection", modernObject("selection" to selection))
    fun localSelection(): ModernLocalSelection? = (call("modernLocalSelection") as? JSONObject)?.let { ModernLocalSelection.restore(it) }
    fun exportHistorySelection() = ModernHistorySelectionArchive.restore(objectCall("modernExportHistorySelection"))
    fun restoreHistorySelection(archive: ModernHistorySelectionArchive) = update("modernRestoreHistorySelection", modernObject("archive" to archive))
    override fun close() { assertThread(); if (!closed) { call("destroy"); closed = true; listeners.clear() } }
}

class ModernResolvedPosition internal constructor(value: JSONObject) : ModernValue(value) {
    val offset get() = number("offset").toInt()
    val address get() = ModernPayload.restore(objectValue("address"))
}
class ModernSemanticState internal constructor(value: JSONObject) : ModernValue(value)

/** Explicit acknowledgments, obtained from the host's real archival transaction. */
data class ModernCutoverAcknowledgments(val oldWritersStopped: Boolean, val archivePersisted: Boolean, val resetUndoAcknowledged: Boolean) {
    init { require(oldWritersStopped && archivePersisted && resetUndoAcknowledged) }
}
class ModernCutoverResult internal constructor(val session: ModernSession, mapping: ModernPayload) {
    private val mapping = mapping
    val originMapping: List<ModernPayload> get() = mapping.export().getJSONArray("originMapping").let { values -> (0 until values.length()).map { ModernPayload.restore(values.getJSONObject(it)) } }
}
class ModernCutoverPreparation internal constructor(value: JSONObject) : ModernValue(value) {
    val archiveID get() = string("archiveID")
    val status get() = string("status")
    val reason get() = optionalString("reason")
    val document get() = optionalObject("document")?.let { ModernDocument.restore(it) }
}
/** Local staging only. Verify bytes read from actual host storage before cutover. */
class ModernCutover {
    private fun call(command: String, args: JSONObject) = NativeEngine.call(args.put("command", command)).getJSONObject("value")
    fun begin(byteCount: Long) = ModernPayload.restore(call("modernBeginCutoverArchive", modernObject("byteCount" to byteCount)))
    fun append(archiveID: String, offset: Long, base64Bytes: String) = ModernPayload.restore(call("modernAppendCutoverArchive", modernObject("archiveID" to archiveID, "offset" to offset, "bytes" to base64Bytes)))
    fun prepare(archive: ModernCutoverArchive) = ModernCutoverPreparation(call("modernPrepareCutover", modernObject("archive" to archive)))
    fun prepareUploaded(archiveID: String) = ModernCutoverPreparation(call("modernPrepareCutover", modernObject("archiveID" to archiveID)))
    fun bytes(archiveID: String, offset: Long, length: Int) = ModernPayload.restore(call("modernCutoverArchiveBytes", modernObject("archiveID" to archiveID, "offset" to offset, "length" to length)))
    fun verifyReadback(archiveID: String, offset: Long, base64Bytes: String) = ModernPayload.restore(call("modernVerifyCutoverReadback", modernObject("archiveID" to archiveID, "offset" to offset, "bytes" to base64Bytes)))
    fun remapWritingPosition(archiveID: String, position: WritingPosition) = ModernPosition(call("modernRemapCutoverPosition", modernObject("archiveID" to archiveID, "kind" to "writing", "position" to position.export())))
    fun remapTextPosition(archiveID: String, position: ModernLegacyTextPosition) = ModernPosition(call("modernRemapCutoverPosition", modernObject("archiveID" to archiveID, "kind" to "text", "position" to position)))
    fun forget(archiveID: String) { NativeEngine.call(modernObject("command" to "modernForgetCutoverArchive", "archiveID" to archiveID)) }
}

/** Legacy EditorSession.position() remains opaque; explicit restoration selects its remapping kind. */
class ModernLegacyTextPosition private constructor(value: JSONObject) : ModernValue(value) {
    companion object { fun restore(value: JSONObject) = ModernLegacyTextPosition(value) }
}
enum class ModernLegacyDocumentFormat(val wireValue: String) { BLOCK_ARRAY("blockArray"), DOCUMENT_OBJECT("documentObject") }
sealed class ModernCutoverSource {
    internal abstract fun wire(): JSONObject
    data class Document(val format: ModernLegacyDocumentFormat, val base64Bytes: String) : ModernCutoverSource() {
        override fun wire() = modernObject("document" to modernObject("format" to format.wireValue, "bytes" to base64Bytes))
    }
    data class Session(val acceptedSnapshot: String, val reconciledSnapshot: String, val unacknowledged: List<String>, val pendingRecovery: String? = null) : ModernCutoverSource() {
        override fun wire() = modernObject("session" to modernObject("acceptedSnapshot" to acceptedSnapshot, "reconciledSnapshot" to reconciledSnapshot, "unacknowledged" to JSONArray(unacknowledged))
            .also { value -> pendingRecovery?.let { value.put("pendingRecovery", it) } })
    }
}
class ModernCutoverArchive(documentID: String, epoch: String, originals: List<String>, source: ModernCutoverSource) : ModernValue(
    modernObject("version" to 1, "documentID" to documentID, "epoch" to epoch, "originals" to JSONArray(originals), "source" to source.wire()))
