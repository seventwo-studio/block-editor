package studio.seventwo.blockeditor.demo

import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import org.json.JSONArray
import org.json.JSONObject
import studio.seventwo.blockeditor.EditorSession
import java.io.Closeable
import java.net.HttpURLConnection
import java.net.URL
import java.util.UUID

/** Main-thread session adapter; only HTTP I/O runs in the background. Local demo only. */
class LocalRelayConnection private constructor(
    val session: EditorSession, private val endpoint: String, private val token: String, private val actor: String
) : Closeable {
    var connected = true
        set(value) { field = value; generation++; if (!value) peerCount = 0 }
    private var generation = 0
    private var exchanging = false
    private var revision = 0L
    private var receipt = JSONObject().put("received", JSONArray())
    var peerCount = 0
        private set
    val pending: Int get() = session.changes(receipt).getJSONArray("changes").length()

    companion object {
        suspend fun open(endpoint: String, token: String): LocalRelayConnection {
            val snapshot = request(endpoint, token, null)
            val actor = UUID.randomUUID().toString()
            return LocalRelayConnection(EditorSession.restore(snapshot, actor), endpoint, token, actor)
        }
        private suspend fun request(endpoint: String, token: String, body: String?): JSONObject = withContext(Dispatchers.IO) {
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
                check(code == 200) { "Relay rejected request ($code): $text" }
                JSONObject(text)
            } finally { connection.disconnect() }
        }
    }
    suspend fun exchange() {
        if (!connected || exchanging) return
        exchanging = true
        val started = generation
        try {
            val body = JSONObject().put("actorID", actor).put("batch", session.changes(receipt)).put("state", session.syncState())
                .put("presence", JSONObject().put("actor", actor).put("revision", ++revision)).toString()
            val response = request(endpoint, token, body)
            if (!connected || started != generation) return
            session.receive(response.getJSONObject("batch")); receipt = response.getJSONObject("state")
            val peers = response.getJSONArray("presence")
            peerCount = (0 until peers.length()).count { peers.getJSONObject(it).getString("actor") != actor }
        } finally { exchanging = false }
    }
    override fun close() { connected = false; session.close() }
}
