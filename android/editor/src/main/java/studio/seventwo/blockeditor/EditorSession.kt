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
        check(response.getBoolean("ok")) { response.optString("error", "Editor operation failed") }
        return response
    }
}

enum class PositionAffinity(val wireValue: String) { BEFORE("before"), AFTER("after") }

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
        fun create(documentID: String, actorID: String, blocks: JSONArray = JSONArray()): EditorSession {
            val handle = UUID.randomUUID().toString()
            val value = NativeEngine.call(JSONObject().put("command", "create").put("session", handle)
                .put("documentID", documentID).put("actorID", actorID).put("blocks", blocks)).getJSONObject("value")
            return EditorSession(handle, value)
        }
        fun restore(snapshot: JSONObject, actorID: String): EditorSession {
            val handle = UUID.randomUUID().toString()
            val value = NativeEngine.call(JSONObject().put("command", "restore").put("session", handle)
                .put("actorID", actorID).put("snapshot", snapshot)).getJSONObject("value")
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
    fun save(): JSONObject = call("save") as JSONObject
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
