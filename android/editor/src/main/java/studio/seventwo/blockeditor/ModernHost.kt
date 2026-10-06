package studio.seventwo.blockeditor

import android.content.ClipData
import android.content.ClipDescription
import android.content.ClipboardManager
import android.system.Os
import android.system.OsConstants
import android.util.AtomicFile
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext
import org.json.JSONArray
import org.json.JSONObject
import java.io.ByteArrayOutputStream
import java.io.InputStream
import java.io.File
import java.io.RandomAccessFile
import java.util.UUID

internal fun InputStream.boundedBytes(limit: Int): ByteArray {
    val result = ByteArrayOutputStream(); val buffer = ByteArray(65536)
    while (true) { val count = read(buffer); if (count < 0) break; require(count <= limit - result.size()) { "Host checkpoint capacity exceeded" }; result.write(buffer, 0, count) }
    return result.toByteArray()
}
/** App-private paired storage. No JNI call runs on the IO dispatcher. */
class ModernHostStore(private val file: File) {
    private fun read(): JSONObject? {
        val atomic = AtomicFile(file)
        if (!file.exists() && !File(file.path + ".bak").exists()) return null
        val bytes = atomic.openRead().use { input -> input.boundedBytes(384_000_000) }
        require(bytes.size <= 384_000_000) { "Host checkpoint capacity exceeded" }
        val encoded = bytes.toString(Charsets.UTF_8); val value = JSONObject(encoded)
        require(value.toString() == encoded && value.getInt("version") == 1) { "Invalid host checkpoint" }
        return value
    }
    private fun <T> locked(action: () -> T): T = RandomAccessFile(File(file.parentFile, ".${file.name}.lock"), "rw").use { lock ->
        lock.channel.lock().use { action() }
    }
    suspend fun load(): JSONObject? = withContext(Dispatchers.IO) { locked { read() } }
    suspend fun save(pair: JSONObject, expectedRevision: String?): String = withContext(Dispatchers.IO) {
        val bytes = pair.toString().toByteArray(Charsets.UTF_8)
        require(bytes.size <= 384_000_000)
        locked {
            check(read()?.getString("revision") == expectedRevision) { "Host checkpoint revision conflict" }
            val atomic = AtomicFile(file); val output = atomic.startWrite()
            try { output.write(bytes); atomic.finishWrite(output) } catch (failure: Throwable) { atomic.failWrite(output); throw failure }
            Os.chmod(file.path, 384) // 0600, including a newly created checkpoint
            val directory = Os.open(file.parentFile!!.path, OsConstants.O_RDONLY, 0)
            try { Os.fsync(directory) } finally { Os.close(directory) }
            check(atomic.openRead().use { it.boundedBytes(384_000_000) }.contentEquals(bytes)) { "Host checkpoint readback mismatch" }
            pair.getString("revision")
        }
    }
}

class ModernAndroidHost(val session: ModernSession, val actorID: String, private val store: ModernHostStore, loadedRevision: String? = null) {
    var active = true
        private set
    var readOnly by mutableStateOf(false)
    var drafts by mutableStateOf<List<JSONObject>>(emptyList())
    var retainedClipboard by mutableStateOf<List<JSONObject>>(emptyList())
    var providerRecords by mutableStateOf(session.asyncRequests())
        private set
    private var generation = 0L
    private val runningProviders = mutableSetOf<String>()
    private val unsavedProviders = mutableMapOf<String, ModernPayload>()
    private var revision = loadedRevision
    private val saves = Mutex()
    fun setActive(value: Boolean) { if (active != value) { active = value; generation++ } }
    fun checkpoint(): JSONObject = modernObject("version" to 1, "revision" to UUID.randomUUID().toString(), "actorID" to actorID,
        "documentID" to session.snapshot.syncState.documentID, "epoch" to session.snapshot.syncState.epoch,
        "accepted" to session.save(), "historySelection" to session.exportHistorySelection(), "providers" to session.exportAsyncRequests(),
        "recovery" to session.recovery(), "deferred" to JSONArray(session.deferredChanges().map { it.export() }),
        "drafts" to JSONArray(drafts), "clipboard" to JSONArray(retainedClipboard))
    suspend fun save() = saves.withLock {
        val pair = checkpoint()
        try { revision = store.save(pair, revision) }
        catch (failure: Throwable) {
            // AtomicFile may already have renamed the proposed revision. Never
            // assume rollback after a directory-sync/readback failure.
            if (store.load()?.optString("revision") == pair.getString("revision")) revision = pair.getString("revision")
            throw failure
        }
    }
    suspend fun runProvider(node: ModernNodeID, provider: suspend (ModernAsyncTarget) -> ModernPayload): ModernAsyncTarget {
        check(active && !readOnly)
        require(runningProviders.size < 8 && session.exportAsyncRequests().export().toString().length + (runningProviders.size + 1) * 2_000_000 < 16_000_000) { "Provider result capacity unavailable" }
        val capturedGeneration = generation
        val target = session.beginAsyncBlock(node, UUID.randomUUID().toString())
        runningProviders.add(target.requestID); providerRecords = session.asyncRequests()
        try {
            save()
            if (!active || readOnly || capturedGeneration != generation || session.asyncRequests().none { it.target.requestID == target.requestID && it.status == "pending" }) return target
            val metadata = provider(target)
            unsavedProviders[target.requestID] = metadata
            session.retainAsyncResult(target, metadata); providerRecords = session.asyncRequests()
            save(); unsavedProviders.remove(target.requestID)
            if (active && !readOnly && capturedGeneration == generation) {
                session.execute(ModernCommand.CompleteAsyncBlock(target, metadata)); providerRecords = session.asyncRequests(); save()
            }
            return target
        } catch (failure: Throwable) {
            if (!unsavedProviders.containsKey(target.requestID) && session.asyncRequests().any { it.target.requestID == target.requestID && it.status == "pending" }) {
                session.failAsyncBlock(target, failure.toString().take(1000)); providerRecords = session.asyncRequests()
                try { save() } catch (_: Throwable) { /* The original record remains available for explicit save retry. */ }
            }
            throw failure
        } finally { runningProviders.remove(target.requestID) }
    }
    suspend fun retryResult(target: ModernAsyncTarget) {
        check(active && !readOnly)
        val metadata = unsavedProviders[target.requestID] ?: session.asyncRequests().firstOrNull { it.target.requestID == target.requestID }?.result ?: return
        val capturedGeneration = generation
        session.retainAsyncResult(target, metadata); providerRecords = session.asyncRequests()
        save(); unsavedProviders.remove(target.requestID)
        if (!active || readOnly || generation != capturedGeneration) return
        session.execute(ModernCommand.CompleteAsyncBlock(target, metadata)); providerRecords = session.asyncRequests(); save()
    }
    suspend fun cancelProvider(target: ModernAsyncTarget) { session.cancelAsyncBlock(target); providerRecords = session.asyncRequests(); save() }
    companion object {
        fun restore(pair: JSONObject, store: ModernHostStore, policy: ModernPolicy = ModernPolicy()): Pair<ModernAndroidHost, () -> Unit> {
            validatePair(pair)
            val session = ModernSession.restore(ModernPayload.restore(pair.getJSONObject("accepted")), pair.getString("actorID"), policy)
            try {
                require(session.snapshot.syncState.documentID == pair.getString("documentID") && session.snapshot.syncState.epoch == pair.getString("epoch"))
                session.restoreHistorySelection(ModernHistorySelectionArchive.restore(pair.getJSONObject("historySelection")))
                session.restoreAsyncRequests(ModernAsyncArchive.restore(pair.getJSONObject("providers")))
                pair.optJSONObject("recovery")?.let { session.restoreRecovery(ModernRecovery.restore(it)) }
                val release = session.holdRemoteChanges(); val packets = pair.getJSONArray("deferred")
                session.restoreDeferredChanges((0 until packets.length()).map { ModernBatch.restore(packets.getJSONObject(it)) })
                val host = ModernAndroidHost(session, pair.getString("actorID"), store, pair.getString("revision"))
                fun records(name: String): List<JSONObject> = pair.getJSONArray(name).let { array -> (0 until array.length()).map { NativeJsonTransport.copy(array.getJSONObject(it)) } }
                host.drafts = records("drafts"); host.retainedClipboard = records("clipboard")
                host.retainedClipboard.forEach { it.optJSONObject("clipboard")?.let { value -> session.clipboardEncoded(value.toString()) } }
                return host to release // restored provider records remain inert
            } catch (failure: Throwable) { session.close(); throw failure }

        }
    }
}

private fun validatePair(pair: JSONObject) {
    require(pair.getInt("version") == 1)
    val documentID = pair.getString("documentID"); val epoch = pair.getString("epoch")
    pair.getString("actorID"); UUID.fromString(pair.getString("revision"))
    fun bounded(name: String, limit: Int) { require(pair.get(name).toString().toByteArray(Charsets.UTF_8).size <= limit) { "Oversized $name" } }
    bounded("accepted", 64_000_000); bounded("historySelection", 16_000_000); bounded("providers", 16_000_000)
    bounded("recovery", 64_000_000); bounded("deferred", 64_000_000); bounded("drafts", 16_000_000); bounded("clipboard", 64_000_000)
    require(pair.getJSONArray("deferred").length() <= 64)
    val identifiers = mutableSetOf<String>()
    fun scoped(value: JSONObject) { require(value.getString("documentID") == documentID && value.getString("epoch") == epoch) }
    fun range(value: JSONObject) { scoped(value.getJSONObject("start")); scoped(value.getJSONObject("end")) }
    for (name in listOf("drafts", "clipboard")) {
        val array = pair.getJSONArray(name); require(array.length() <= 64)
        for (index in 0 until array.length()) {
            val value = array.getJSONObject(index); require(identifiers.add(value.getString("id")))
            require(value.getString("reason").length <= 1000)
            val target = value.getJSONObject("target")
            if (name == "drafts") { range(target); value.getString("text"); value.optString("nativeText") }
            else {
                require(target.has("range") != target.has("boundary"))
                target.optJSONObject("range")?.let { range(it) }; target.optJSONObject("boundary")?.let { scoped(it) }
                require(value.has("clipboard") || value.has("raw") || value.has("plainText"))
            }
        }
    }
}

object ModernNativeClipboard {
    const val MIME = "application/x-seventwo-modern-clipboard+json"
    fun publish(manager: ClipboardManager, payload: ModernClipboard): Boolean {
        val encoded = payload.export().toString(); val plain = payload.export().getString("plainText")
        manager.setPrimaryClip(ClipData(ClipDescription("Block Editor", arrayOf(MIME, "text/plain")), ClipData.Item(plain)).apply { addItem(ClipData.Item(encoded)) })
        val read = manager.primaryClip ?: return false
        return read.itemCount == 2 && read.getItemAt(0).text?.toString() == plain && read.getItemAt(1).text?.toString() == encoded
    }
    fun capture(manager: ClipboardManager): JSONObject? {
        val clip = manager.primaryClip ?: return null
        val plain = clip.getItemAt(0).text?.toString() ?: ""
        require(plain.length <= 32_000_000)
        val raw = if (clip.description.hasMimeType(MIME)) {
            require(clip.itemCount == 2) { "Malformed internal clipboard" }
            clip.getItemAt(1).text?.toString() ?: error("Clipboard is not inert text")
        } else null
        require(raw == null || raw.length <= 32_000_000)
        return modernObject("plainText" to plain).also { if (raw != null) it.put("raw", raw) }
    }
    fun decode(record: JSONObject, session: ModernSession, plainOnly: Boolean = false): ModernClipboard {
        record.optJSONObject("clipboard")?.let { if (!plainOnly) return session.clipboardEncoded(it.toString()) }
        if (!plainOnly && record.has("raw")) return session.clipboardEncoded(record.getString("raw"))
        return session.clipboardText(record.getString("plainText"), "multiline")
    }
    fun read(manager: ClipboardManager, session: ModernSession, plainOnly: Boolean = false): ModernClipboard? {
        val clip = manager.primaryClip ?: return null
        if (!plainOnly && clip.description.hasMimeType(MIME)) {
            require(clip.itemCount == 2) { "Malformed internal clipboard" }
            val encoded = clip.getItemAt(1).text?.toString() ?: error("Clipboard is not inert text")
            require(encoded.length <= 32_000_000)
            return session.clipboardEncoded(encoded)
        }
        val plain = clip.getItemAt(0).text?.toString() ?: return null
        return session.clipboardText(plain.replace("\r\n", "\n").replace('\r', '\n'), "multiline")
    }
}
