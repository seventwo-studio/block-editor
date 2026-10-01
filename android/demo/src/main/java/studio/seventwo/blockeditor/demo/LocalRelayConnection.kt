package studio.seventwo.blockeditor.demo

import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import org.json.JSONArray
import org.json.JSONObject
import studio.seventwo.blockeditor.EditorSession
import studio.seventwo.blockeditor.MergeRecovery
import java.io.Closeable
import java.io.File
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import java.net.HttpURLConnection
import java.net.URL
import java.util.UUID

/** Main-thread session adapter; only HTTP I/O runs in the background. Local demo only. */
class LocalRelayConnection private constructor(
    val session: EditorSession, private val endpoint: String, private var token: String, private val actor: String,
    private val draft: LocalDraft? = null
) : Closeable {
    var saveStatus by mutableStateOf(if (draft == null) "Memory-only session" else "Saved locally")
        private set
    var recovery by mutableStateOf<MergeRecovery?>(session.mergeRecovery())
        private set
    fun refreshRecovery() {
        if (closed) return
        val next = session.mergeRecovery()
        if (next?.export()?.toString() == recovery?.export()?.toString()) return
        recovery = next
        save()
    }
    private fun save() {
        if (draft == null) return
        try { draft.save(endpoint, actor, session); saveStatus = "Saved locally" }
        catch (error: Exception) {
            saveStatus = "Local save failed: ${error.message}" + if (recovery != null) ". Export pending recovery before closing." else ""
        }
    }
    fun exportRecovery(destination: File) {
        checkNotNull(draft) { "No persistent local draft" }.exportRecovery(endpoint, actor, session, destination)
    }
    fun setToken(value: String) { token = value }
    var connected = true
        set(value) { field = value; generation++; if (!value) peerCount = 0 }
    private var generation = 0
    private var closed = false
    private var exchanging = false
    private var revision = 0L
    private var receipt = JSONObject().put("received", JSONArray())
    var peerCount = 0
        private set
    val pending: Int get() = session.changes(receipt).getJSONArray("changes").length()

    companion object {
        suspend fun open(endpoint: String, token: String, file: File? = null): LocalRelayConnection {
            val draft = file?.let { LocalDraft(it) }
            var session: EditorSession? = null
            try {
                val saved = draft?.read(endpoint)
                val (actor, editor) = if (saved != null) checkNotNull(draft).restore(saved) else {
                    val reply = request(endpoint, token, null)
                    check(reply.code == 200) { "Relay rejected request (${reply.code}): ${reply.body}" }
                    val author = UUID.randomUUID().toString()
                    author to EditorSession.restore(reply.body, author)
                }
                session = editor
                draft?.save(endpoint, actor, editor)
                val connection = LocalRelayConnection(editor, endpoint, token, actor, draft)
                connection.connected = saved == null
                editor.onChange = {
                    connection.recovery = editor.mergeRecovery()
                    connection.save()
                }
                return connection
            } catch (error: Exception) { session?.close(); draft?.close(); throw error }
        }
        private data class Reply(val code: Int, val body: JSONObject)
        private suspend fun request(endpoint: String, token: String, body: String?): Reply = withContext(Dispatchers.IO) {
            val connection = URL(endpoint).openConnection() as HttpURLConnection
            try {
                connection.connectTimeout = 10_000; connection.readTimeout = 10_000
                connection.setRequestProperty("X-Local-Token", token)
                if (body != null) {
                    connection.requestMethod = "POST"; connection.doOutput = true
                    connection.setRequestProperty("Content-Type", "application/json")
                    connection.outputStream.use { it.write(body.toByteArray(Charsets.UTF_8)) }
                }
                val code = connection.responseCode
                val text = (if (code == 200) connection.inputStream else connection.errorStream)?.bufferedReader()?.use { it.readText() } ?: ""
                check(code == 200 || code == 409) { "Relay rejected request ($code): $text" }
                Reply(code, JSONObject(text))
            } finally { connection.disconnect() }
        }
    }
    suspend fun exchange() {
        if (closed || !connected || exchanging) return
        exchanging = true
        val started = generation
        try {
            val body = JSONObject().put("actorID", actor).put("batch", session.changes(receipt)).put("state", session.syncState())
                .put("presence", JSONObject().put("actor", actor).put("revision", ++revision)).toString()
            val response = request(endpoint, token, body)
            if (!connected || started != generation) return
            if (response.code == 409) {
                check(response.body.getString("error") == "mergeRecoveryRequired") { "Unsupported relay rejection" }
                session.receive(MergeRecovery.restore(response.body.getJSONObject("recovery")).batch)
                error("The server has not accepted these edits; retry synchronization.")
            }
            session.receive(response.body.getJSONObject("batch")); receipt = response.body.getJSONObject("state")
            val peers = response.body.getJSONArray("presence")
            peerCount = (0 until peers.length()).count { peers.getJSONObject(it).getString("actor") != actor }
        } finally {
            try { refreshRecovery() } finally { exchanging = false }
        }
    }
    override fun close() {
        if (closed) return
        closed = true; connected = false
        try { session.close() } finally { draft?.close() }
    }
}
