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

/** Use on the UI thread. Storage, transport and presence expiry belong to the host. */
class EditorSession private constructor(private val handle: String, initial: JSONObject) : Closeable {
    var snapshot: JSONObject by mutableStateOf(initial)
        private set
    var onChange: ((JSONObject) -> Unit)? = null
    private var closed = false

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
        snapshot = call(command, args) as JSONObject
        onChange?.invoke(snapshot)
    }
    fun setText(blockID: String, text: String, path: List<String> = listOf("content")) = edit("setText",
        JSONObject().put("address", JSONObject().put("blockID", blockID).put("path", JSONArray(path))).put("text", text))
    fun save(): JSONObject = call("save") as JSONObject
    fun syncState(): JSONObject = call("syncState") as JSONObject
    fun changes(since: JSONObject = JSONObject().put("received", JSONArray())): JSONObject = call("changes", JSONObject().put("since", since)) as JSONObject
    fun receive(batch: JSONObject) = edit("receive", JSONObject().put("batch", batch))
    fun receivePresence(presence: JSONObject): JSONObject = call("presence", JSONObject().put("presence", presence)) as JSONObject
    fun undo() = edit("undo")
    fun redo() = edit("redo")
    override fun close() { if (!closed) { call("close"); closed = true; onChange = null } }
}
