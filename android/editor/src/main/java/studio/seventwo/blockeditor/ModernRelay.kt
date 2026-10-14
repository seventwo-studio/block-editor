package studio.seventwo.blockeditor

import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.withContext
import org.json.JSONArray
import org.json.JSONObject
import java.io.Closeable
import java.lang.ref.WeakReference
import java.net.HttpURLConnection
import java.net.URI
import java.net.URL

/** Stable app-owned service/room identity paired with a confirmed Swift receipt. */
class ModernRelayReceipt private constructor(value: JSONObject) : ModernValue(value) {
    constructor(key: String, receipt: ModernReceipt) : this(modernObject("key" to key, "receipt" to receipt))
    init {
        require(value.keys().asSequence().toSet() == setOf("key", "receipt"))
        require(value.get("key") is String)
        require(key.isNotEmpty() && key.toByteArray(Charsets.UTF_8).size <= 1024)
        require(receipt.export().getInt("version") == 7)
    }
    val key get() = string("key")
    val receipt get() = ModernReceipt.restore(objectValue("receipt"))
    internal fun validate(session: ModernSession) {
        session.changes(receipt) // shared version/scope/causal-identity validation
        val known = session.snapshot.syncState.received.toMutableSet()
        session.deferredChanges().forEach { packet -> packet.export().getJSONArray("changes").let { changes ->
            for (index in 0 until changes.length()) known.add(ModernChangeID.read(changes.getJSONObject(index).getJSONObject("id")))
        } }
        require(known.containsAll(receipt.received)) { "Relay receipt names missing input" }
    }
    internal fun canonical(session: ModernSession): ModernRelayReceipt {
        validate(session)
        // Only normalize after shared numeric admission. The private store's
        // canonical reader must also be able to reopen valid exponent tokens.
        return restore(NativeJsonTransport.decode(NativeJsonTransport.encode(export())))
    }
    companion object { fun restore(value: JSONObject) = ModernRelayReceipt(value) }
}

class ModernRelayRequest(val endpoint: String, val token: String, body: ByteArray? = null) {
    private val data = body?.copyOf()
    val body get() = data?.copyOf()
}
class ModernRelayResponse(val status: Int, bytes: ByteArray) {
    private val data = bytes.copyOf()
    val bytes get() = data.copyOf()
}
class ModernRelayCapacityException(val maxBytes: Int) : IllegalStateException("Relay capacity is $maxBytes bytes; complete local input remains available")
class ModernRelayRetryException : IllegalStateException("Relay has not accepted these changes; explicitly repair retained recovery and retry")
typealias ModernRelayTransport = suspend (ModernRelayRequest) -> ModernRelayResponse

/** Optional protocol-7 reference, confined to the session's creating thread.
 * App authorization, scheduling, files, uploads and rollout stay with the host. */
class ModernAndroidRelay(
    val host: ModernAndroidHost, val endpoint: String, val relayKey: String, token: String,
    private val transport: ModernRelayTransport = Companion::request
) : Closeable {
    private val owner = Thread.currentThread()
    private var token = token
    private var generation = 0L
    private var presenceRevision = 0L
    private var closed = false
    private var requestJob: Job? = null
    private var connectionEnabled by mutableStateOf(token.isNotEmpty())
    val connected get() = connectionEnabled
    var exchanging by mutableStateOf(false)
        private set
    var peers by mutableStateOf<List<ModernPayload>>(emptyList())
        private set
    var lastError by mutableStateOf<String?>(null)
        private set
    var transportCapacityBytes by mutableStateOf<Int?>(null)
        private set
    var resumeDeferred: (() -> Unit)? = null
        private set
    val receipt get() = checkNotNull(host.relayReceipt).receipt
    val pendingChanges: Int get() { assertThread(); val accepted = receipt.received.toSet(); return host.session.snapshot.syncState.received.count { it !in accepted } }
    init {
        validateEndpoint(endpoint)
        check(host.relayOwner?.get() == null) { "A relay is already attached" }
        val existing = host.relayReceipt
        require(existing == null || existing.key == relayKey) { "Different relay identity" }
        val record = existing ?: ModernRelayReceipt(relayKey, ModernReceipt.restore(modernObject("version" to 7,
            "documentID" to host.session.snapshot.syncState.documentID, "epoch" to host.session.snapshot.syncState.epoch, "received" to JSONArray())))
        host.relayReceipt = record.canonical(host.session); host.relayOwner = WeakReference(this)
    }
    private fun assertThread() { check(Thread.currentThread() === owner) { "Modern relay must use its original session thread" } }
    fun setConnected(value: Boolean) { assertThread(); connectionEnabled = value; generation++; requestJob?.cancel(); peers = emptyList() }
    fun setToken(value: String) { assertThread(); token = value; generation++; requestJob?.cancel(); peers = emptyList(); if (value.isEmpty()) connectionEnabled = false }
    override fun close() {
        assertThread(); if (closed) return
        closed = true; connectionEnabled = false; generation++; requestJob?.cancel(); peers = emptyList()
        if (host.relayOwner?.get() === this) host.relayOwner = null
    }
    suspend fun exchange() {
        assertThread(); if (closed || !connected || exchanging || !host.active) return
        exchanging = true; lastError = null
        val connection = generation; val originalHost = host.captureSynchronization()
        fun current() = !closed && connected && generation == connection && originalHost()
        try {
            check(token.isNotEmpty()) { "Relay requires authorization" }
            val saved = host.savedCheckpoint(); if (!current()) return
            val captured = ModernSession.restore(ModernPayload.restore(saved.getJSONObject("accepted")), host.actorID)
            val body = try {
                modernObject("actorID" to host.actorID, "batch" to captured.changes(receipt), "state" to captured.snapshot.syncState,
                    "presence" to modernObject("actor" to host.actorID, "revision" to ++presenceRevision))
            } finally { captured.close() }
            val job = SupervisorJob(currentCoroutineContext()[Job]); requestJob = job
            val response = try { withContext(job) { transport(ModernRelayRequest(endpoint, token, NativeJsonTransport.encode(body))) } }
                finally { job.cancel(); if (requestJob === job) requestJob = null }
            if (!current()) return
            val bytes = response.bytes; require(bytes.size <= 128_000_000)
            val json = withContext(Dispatchers.IO) { NativeJsonTransport.decode(bytes, strict = true) }; if (!current()) return
            if (response.status == 413) {
                require(json.getString("error") == "transportCapacityExceeded")
                val value = json.get("maxBytes") as? Number ?: error("Invalid relay capacity")
                val maximum = java.math.BigDecimal(value.toString()).intValueExact(); require(maximum > 0)
                transportCapacityBytes = maximum; throw ModernRelayCapacityException(maximum)
            }
            if (response.status == 409) {
                require(json.getString("error") == "modernRecoveryRequired")
                try { host.session.receive(ModernRecovery.restore(json.getJSONObject("recovery")).batch) } catch (_: ModernRecoveryException) { }
                host.save(); if (!current()) return
                throw ModernRelayRetryException()
            }
            check(response.status == 200) { "Relay rejected request (${response.status})" }
            val batch = ModernBatch.restore(json.getJSONObject("batch")); val state = ModernReceipt.restore(json.getJSONObject("state"))
            host.session.changes(state)
            val known = host.session.snapshot.syncState.received.toMutableSet()
            (host.session.deferredChanges() + batch).forEach { packet -> packet.export().getJSONArray("changes").let { changes ->
                for (index in 0 until changes.length()) known.add(ModernChangeID.read(changes.getJSONObject(index).getJSONObject("id")))
            } }
            require(known.containsAll(state.received)) { "Relay receipt names missing input" }
            val presence = json.getJSONArray("presence").let { values -> (0 until values.length()).map { ModernPayload.restore(values.getJSONObject(it)) } }
            try { host.session.receive(batch) } catch (failure: ModernRecoveryException) { host.save(); throw failure }
            host.confirmRelay(ModernRelayReceipt(relayKey, state)); if (!current()) return
            transportCapacityBytes = null; peers = presence.filter { it.export().getString("actor") != host.actorID }
        } catch (failure: Throwable) {
            if (!current()) return
            lastError = failure.toString(); throw failure
        } finally { exchanging = false }
    }
    companion object {
        suspend fun open(store: ModernHostStore, documentID: String, actorID: String, endpoint: String, relayKey: String, token: String,
                         policy: ModernPolicy = ModernPolicy(), transport: ModernRelayTransport = ::request): ModernAndroidRelay {
            validateEndpoint(endpoint)
            val saved = store.load()
            if (saved != null) {
                require(saved.getString("documentID") == documentID && saved.getString("actorID") == actorID) { "Different checkpoint owner" }
                val (host, resume) = ModernAndroidHost.restore(saved, store, policy)
                try { return ModernAndroidRelay(host, endpoint, relayKey, token, transport).also { it.resumeDeferred = resume } }
                catch (failure: Throwable) { host.session.close(); throw failure }
            }
            check(token.isNotEmpty()) { "A new remote room requires authorization" }
            val response = transport(ModernRelayRequest(endpoint, token)); check(response.status == 200) { "Relay rejected opening (${response.status})" }
            val bytes = response.bytes; require(bytes.size <= 64_000_000)
            val decoded = withContext(Dispatchers.IO) { NativeJsonTransport.decode(bytes, strict = true) }
            val session = ModernSession.restore(ModernPayload.restore(decoded), actorID, policy)
            try {
                require(session.snapshot.syncState.documentID == documentID) { "Different remote document" }
                val host = ModernAndroidHost(session, actorID, store)
                host.relayReceipt = ModernRelayReceipt(relayKey, session.snapshot.syncState)
                return ModernAndroidRelay(host, endpoint, relayKey, token, transport).also { host.save() }
            } catch (failure: Throwable) { session.close(); throw failure }
        }
        private fun validateEndpoint(endpoint: String) {
            val uri = try { URI(endpoint) } catch (_: Exception) { throw IllegalArgumentException("Invalid relay endpoint") }
            require(uri.rawUserInfo == null && uri.rawQuery == null && uri.rawFragment == null && !uri.host.isNullOrEmpty()) { "Invalid relay endpoint" }
            require(uri.scheme == "https" || (uri.scheme == "http" && uri.host in listOf("127.0.0.1", "localhost", "[::1]", "::1"))) { "Relay requires HTTPS or loopback" }
        }
        private suspend fun request(request: ModernRelayRequest): ModernRelayResponse = withContext(Dispatchers.IO) {
            val connection = URL(request.endpoint).openConnection() as HttpURLConnection
            try {
                connection.instanceFollowRedirects = false; connection.connectTimeout = 15_000; connection.readTimeout = 15_000
                connection.setRequestProperty("X-Local-Token", request.token)
                request.body?.let { body ->
                    connection.requestMethod = "POST"; connection.doOutput = true
                    connection.setRequestProperty("Content-Type", "application/json"); connection.setFixedLengthStreamingMode(body.size)
                    connection.outputStream.use { it.write(body) }
                }
                val status = connection.responseCode
                val bytes = (if (status == 200) connection.inputStream else connection.errorStream)?.use { it.boundedBytes(128_000_000) } ?: ByteArray(0)
                ModernRelayResponse(status, bytes)
            } finally { connection.disconnect() }
        }
    }
}
