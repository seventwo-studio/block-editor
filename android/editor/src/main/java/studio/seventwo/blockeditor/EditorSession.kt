package studio.seventwo.blockeditor

import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import org.json.JSONArray
import org.json.JSONObject
import java.io.Closeable
import java.util.UUID

internal object NativeEngine {
    init { System.loadLibrary("BlockEditorJNI") }
    private external fun callNative(request: ByteArray): ByteArray?
    @Synchronized fun call(request: JSONObject): JSONObject {
        val bytes = checkNotNull(callNative(request.toString().toByteArray(Charsets.UTF_8))) { "Swift engine returned no response" }
        val response = JSONObject(bytes.toString(Charsets.UTF_8))
        if (!response.getBoolean("ok")) {
            if (response.optString("error") == "mergeRecoveryRequired" && response.has("recovery"))
                throw MergeRecoveryException(MergeRecovery(response.getJSONObject("recovery")))
            throw IllegalStateException(response.optString("error", "Editor operation failed"))
        }
        return response
    }
}

enum class PositionAffinity(val wireValue: String) { BEFORE("before"), AFTER("after") }

enum class MergeRecoveryReason { IDENTITY_CONFLICT, SCHEMA_CONSTRAINT }
/** Store separately from save(); this union is not applied history or acknowledged changes. */
class MergeRecovery internal constructor(private val wire: JSONObject) {
    val reason: MergeRecoveryReason = when (wire.getString("reason")) {
        "identityConflict" -> MergeRecoveryReason.IDENTITY_CONFLICT
        "schemaConstraint" -> MergeRecoveryReason.SCHEMA_CONSTRAINT
        else -> throw IllegalStateException("Unsupported recovery reason")
    }
    val batch: JSONObject get() = JSONObject(wire.getJSONObject("batch").toString())
    fun export(): JSONObject = JSONObject(wire.toString())
    companion object { fun restore(value: JSONObject) = MergeRecovery(JSONObject(value.toString())) }
}
class MergeRecoveryException(val recovery: MergeRecovery) : IllegalStateException("Merge recovery required")
sealed class MergeRepair {
    internal abstract fun wire(): JSONObject
    data class Move(val identity: NodeIdentity, val collection: NodeCollection) : MergeRepair() {
        override fun wire() = JSONObject().put("move", JSONObject().put("identity", identity.wire).put("collection", collection.wire))
    }
    data class Wrap(val identity: NodeIdentity, val container: JSONObject, val field: String) : MergeRepair() {
        override fun wire() = JSONObject().put("wrap", JSONObject().put("identity", identity.wire).put("container", container).put("field", field))
    }
    data class Text(val identity: NodeIdentity, val field: String, val text: String) : MergeRepair() {
        override fun wire() = JSONObject().put("text", JSONObject().put("identity", identity.wire).put("field", field).put("text", text))
    }
}

/** An opaque origin identity, obtained from a session rather than a document label. */
class NodeIdentity internal constructor(internal val wire: JSONObject)
data class NodeAddress(val blockID: String, val path: List<String> = emptyList()) {
    internal fun wire() = JSONObject().put("blockID", blockID).put("path", JSONArray(path))
}
class NodeCollection private constructor(internal val wire: JSONObject) {
    companion object {
        val ROOT = NodeCollection(JSONObject().put("field", "blocks"))
        fun children(owner: NodeIdentity) = of(owner, "children")
        fun items(owner: NodeIdentity) = of(owner, "items")
        fun rows(owner: NodeIdentity) = of(owner, "rows")
        fun cells(owner: NodeIdentity) = of(owner, "cells")
        private fun of(owner: NodeIdentity, field: String) = NodeCollection(JSONObject().put("owner", owner.wire).put("field", field))
    }
}

/** Use on the UI thread. Storage, transport and presence expiry belong to the host. */
class EditorSession private constructor(private val handle: String, initial: JSONObject) : Closeable {
    var snapshot: JSONObject by mutableStateOf(initial)
        private set
    var onChange: ((JSONObject) -> Unit)? = null
    private var closed = false
    private val listeners = linkedSetOf<() -> Unit>()
    private val beforeReceive = linkedSetOf<() -> (() -> Unit)?>()
    private var remoteHolds = 0
    private val deferred = mutableListOf<String>()
    private var deferredBytes = 0

    internal fun subscribe(listener: () -> Unit): () -> Unit {
        listeners.add(listener)
        return { listeners.remove(listener); Unit }
    }
    internal fun subscribeBeforeReceive(listener: () -> (() -> Unit)?): () -> Unit {
        beforeReceive.add(listener)
        return { beforeReceive.remove(listener); Unit }
    }
    private fun publish(value: JSONObject) {
        snapshot = value
        listeners.toList().forEach { it() }
        onChange?.invoke(snapshot)
    }
    /** Queued changes are excluded from receipts until every composition hold ends. */
    fun deferRemoteChanges(): () -> Unit {
        check(!closed) { "Editor session is closed" }
        remoteHolds++
        var released = false
        return finish@{
            if (released || closed) return@finish
            released = true
            remoteHolds--
            if (remoteHolds > 0) return@finish
            val batches = deferred.toList()
            deferred.clear(); deferredBytes = 0
            var failure: Exception? = null
            for (batch in batches) {
                try { receive(JSONObject(batch)) } catch (error: Exception) { if (failure == null) failure = error }
            }
            failure?.let { throw it }
        }
    }

    companion object {
        fun create(documentID: String, actorID: String, blocks: JSONArray = JSONArray(), collaborationVersion: Int = 1): EditorSession {
            val handle = UUID.randomUUID().toString()
            val value = NativeEngine.call(JSONObject().put("command", "create").put("session", handle)
                .put("documentID", documentID).put("actorID", actorID).put("blocks", blocks)
                .put("collaborationVersion", collaborationVersion)).getJSONObject("value")
            return EditorSession(handle, value)
        }
        fun restore(snapshot: JSONObject, actorID: String): EditorSession {
            val handle = UUID.randomUUID().toString()
            val value = NativeEngine.call(JSONObject().put("command", "restore").put("session", handle)
                .put("actorID", actorID).put("snapshot", snapshot)).getJSONObject("value")
            return EditorSession(handle, value)
        }
        /** Stop old writers and archive their snapshot first; undo starts fresh. */
        fun cutoverToV2(snapshot: JSONObject, newDocumentID: String, actorID: String): EditorSession {
            val handle = UUID.randomUUID().toString()
            val value = NativeEngine.call(JSONObject().put("command", "cutoverToV2").put("session", handle)
                .put("documentID", newDocumentID).put("actorID", actorID).put("snapshot", snapshot)).getJSONObject("value")
            return EditorSession(handle, value)
        }
    }
    private fun call(command: String, args: JSONObject = JSONObject()): Any {
        check(!closed) { "Editor session is closed" }
        return NativeEngine.call(args.put("command", command).put("session", handle)).get("value")
    }
    fun edit(command: String, args: JSONObject = JSONObject()) {
        publish(call(command, args) as JSONObject)
    }
    fun setText(blockID: String, text: String, path: List<String> = listOf("content")) = edit("setText",
        JSONObject().put("address", JSONObject().put("blockID", blockID).put("path", JSONArray(path))).put("text", text))
    fun node(address: NodeAddress): NodeIdentity = NodeIdentity(call("node", JSONObject().put("address", address.wire())) as JSONObject)
    fun nodeAddress(identity: NodeIdentity): NodeAddress {
        val value = call("nodeAddress", JSONObject().put("identity", identity.wire)) as JSONObject
        val path = value.getJSONArray("path")
        return NodeAddress(value.getString("blockID"), (0 until path.length()).map { path.getString(it) })
    }
    fun nodes(collection: NodeCollection): List<NodeIdentity> {
        val values = call("nodes", JSONObject().put("collection", collection.wire)) as JSONArray
        return (0 until values.length()).map { NodeIdentity(values.getJSONObject(it)) }
    }
    fun insertNode(value: JSONObject, collection: NodeCollection, after: NodeIdentity? = null): NodeIdentity {
        val result = call("insertNode", JSONObject().put("value", value).put("collection", collection.wire)
            .put("after", after?.wire ?: JSONObject.NULL)) as JSONObject
        publish(result.getJSONObject("snapshot"))
        return NodeIdentity(result.getJSONObject("identity"))
    }
    fun moveNode(identity: NodeIdentity, collection: NodeCollection, after: NodeIdentity? = null) = edit("moveNode",
        JSONObject().put("identity", identity.wire).put("collection", collection.wire).put("after", after?.wire ?: JSONObject.NULL))
    fun deleteNode(identity: NodeIdentity) = edit("deleteNode", JSONObject().put("identity", identity.wire))
    fun indent(identity: NodeIdentity) = edit("indent", JSONObject().put("identity", identity.wire))
    fun outdent(identity: NodeIdentity) = edit("outdent", JSONObject().put("identity", identity.wire))
    fun setNodeField(identity: NodeIdentity, path: List<String>, value: Any?) = edit("setNodeField",
        JSONObject().put("identity", identity.wire).put("path", JSONArray(path)).put("value", value ?: JSONObject.NULL))
    fun setText(identity: NodeIdentity, text: String, field: String = "content") = edit("setText",
        JSONObject().put("address", call("textAddress", JSONObject().put("identity", identity.wire).put("field", field))).put("text", text))
    fun save(): JSONObject = call("save") as JSONObject
    fun mergeRecovery(): MergeRecovery? = (call("mergeRecovery") as? JSONObject)?.let { MergeRecovery(it) }
    /** Commit composition first. Restore pending transport state by receiving recovery.batch. */
    fun repairMerge(repairs: List<MergeRepair>) {
        check(remoteHolds == 0) { "Commit composition before repairing a merge" }
        val rollback = beforeReceive.toList().map { it() }
        try { edit("repairMerge", JSONObject().put("repairs", JSONArray(repairs.map { it.wire() }))) }
        catch (error: Exception) { rollback.forEach { try { it?.invoke() } catch (_: Exception) { } }; throw error }
    }
    fun position(blockID: String, offset: Int, path: List<String> = listOf("content"), affinity: PositionAffinity = PositionAffinity.BEFORE): JSONObject =
        call("position", JSONObject().put("address", JSONObject().put("blockID", blockID).put("path", JSONArray(path)))
            .put("offset", offset).put("affinity", affinity.wireValue)) as JSONObject
    fun resolvePosition(position: JSONObject): Int = (call("resolvePosition", JSONObject().put("position", position)) as Number).toInt()
    fun syncState(): JSONObject = call("syncState") as JSONObject
    fun changes(since: JSONObject = JSONObject().put("received", JSONArray())): JSONObject = call("changes", JSONObject().put("since", since)) as JSONObject
    fun receive(batch: JSONObject) {
        check(!closed) { "Editor session is closed" }
        if (remoteHolds > 0) {
            val payload = batch.toString()
            val bytes = payload.toByteArray(Charsets.UTF_8).size
            check(deferred.size < 64 && bytes <= 64_000_000 - deferredBytes) {
                "Pending remote changes exceed the composition buffer; retry after composition ends"
            }
            deferred.add(payload); deferredBytes += bytes
            return
        }
        val rollback = beforeReceive.toList().map { it() }
        val next = try { call("receive", JSONObject().put("batch", batch)) as JSONObject }
        catch (error: Exception) {
            rollback.forEach { try { it?.invoke() } catch (_: Exception) { } }
            throw error
        }
        publish(next)
    }
    fun receivePresence(presence: JSONObject): JSONObject = call("presence", JSONObject().put("presence", presence)) as JSONObject
    fun undo() = edit("undo")
    fun redo() = edit("redo")
    override fun close() { if (!closed) { call("close"); closed = true; onChange = null; listeners.clear(); beforeReceive.clear(); deferred.clear(); deferredBytes = 0 } }
}
