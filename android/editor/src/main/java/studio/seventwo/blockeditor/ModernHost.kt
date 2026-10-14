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
import java.lang.ref.WeakReference
import java.math.BigDecimal
import java.nio.charset.CodingErrorAction

/** Native uncommitted buffers may temporarily contain unpaired UTF-16 units.
 * Escape those units in the private archive instead of replacing them in UTF-8. */
internal fun encodeModernCheckpoint(pair: JSONObject): ByteArray {
    val text = pair.toString(); val result = StringBuilder(text.length)
    var index = 0
    while (index < text.length) {
        val character = text[index++]
        if (character.isHighSurrogate() && index < text.length && text[index].isLowSurrogate()) result.append(character).append(text[index++])
        else if (character.isSurrogate()) result.append("\\u").append(character.code.toString(16).padStart(4, '0'))
        else result.append(character)
    }
    return result.toString().toByteArray(Charsets.UTF_8)
}

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
        val decoder = Charsets.UTF_8.newDecoder().onMalformedInput(CodingErrorAction.REPORT).onUnmappableCharacter(CodingErrorAction.REPORT)
        val value = JSONObject(decoder.decode(java.nio.ByteBuffer.wrap(bytes)).toString())
        require(encodeModernCheckpoint(value).contentEquals(bytes) && exactCheckpointInt(value.get("version")) == 1) { "Invalid host checkpoint" }
        return value
    }
    private fun <T> locked(action: () -> T): T = RandomAccessFile(File(file.parentFile, ".${file.name}.lock"), "rw").use { lock ->
        lock.channel.lock().use { action() }
    }
    suspend fun load(): JSONObject? = withContext(Dispatchers.IO) { locked { read() } }
    suspend fun save(pair: JSONObject, expectedRevision: String?): String {
        val captured = NativeJsonTransport.copy(pair)
        return withContext(Dispatchers.IO) {
        val bytes = encodeModernCheckpoint(captured)
        require(bytes.size <= 384_000_000)
        locked {
            check(read()?.getString("revision") == expectedRevision) { "Host checkpoint revision conflict" }
            val atomic = AtomicFile(file); val output = atomic.startWrite()
            try { output.write(bytes); atomic.finishWrite(output) } catch (failure: Throwable) { atomic.failWrite(output); throw failure }
            Os.chmod(file.path, 384) // 0600, including a newly created checkpoint
            val directory = Os.open(file.parentFile!!.path, OsConstants.O_RDONLY, 0)
            try { Os.fsync(directory) } finally { Os.close(directory) }
            check(atomic.openRead().use { it.boundedBytes(384_000_000) }.contentEquals(bytes)) { "Host checkpoint readback mismatch" }
            captured.getString("revision")
        }
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
    var relayReceipt: ModernRelayReceipt? = null
        internal set
    internal var relayOwner: WeakReference<ModernAndroidRelay>? = null
    fun setActive(value: Boolean) { if (active != value) { active = value; generation++ } }
    fun captureInvocation(): () -> Boolean {
        val captured = generation
        return { active && !readOnly && generation == captured }
    }
    fun captureSynchronization(): () -> Boolean {
        val captured = generation
        return { active && generation == captured }
    }
    fun checkpoint(relay: ModernRelayReceipt? = relayReceipt): JSONObject {
        check(!session.capabilities().export().optBoolean("isComposing") || drafts.isNotEmpty()) { "Original composed input must be retained" }
        val confirmed = relay?.canonical(session)
        val pair = modernObject("version" to 1, "revision" to UUID.randomUUID().toString(), "actorID" to actorID,
        "documentID" to session.snapshot.syncState.documentID, "epoch" to session.snapshot.syncState.epoch,
        "accepted" to session.save(), "historySelection" to session.exportHistorySelection(), "providers" to session.exportAsyncRequests(),
        "recovery" to session.recovery(), "deferred" to JSONArray(session.deferredChanges().map { it.export() }),
        "drafts" to JSONArray(drafts), "clipboard" to JSONArray(retainedClipboard)).also { pair ->
            confirmed?.let { pair.put("relay", it.export()) }; validatePair(pair)
        }
        return NativeJsonTransport.copy(pair)
    }
    fun exportCheckpoint(): ByteArray = encodeModernCheckpoint(checkpoint())
    suspend fun save() { savePair(null) }
    internal suspend fun savedCheckpoint(): JSONObject = savePair(null)
    internal suspend fun confirmRelay(relay: ModernRelayReceipt): JSONObject = savePair(relay)
    private suspend fun savePair(relay: ModernRelayReceipt?): JSONObject = saves.withLock {
        val pair = checkpoint(relay ?: relayReceipt)
        try { revision = store.save(pair, revision) }
        catch (failure: Throwable) {
            // AtomicFile may already have renamed the proposed revision. Never
            // assume rollback after a directory-sync/readback failure.
            try { if (store.load()?.optString("revision") == pair.getString("revision")) revision = pair.getString("revision") }
            catch (readFailure: Throwable) { failure.addSuppressed(readFailure) }
            throw failure
        }
        if (relay != null) relayReceipt = ModernRelayReceipt.restore(pair.getJSONObject("relay"))
        NativeJsonTransport.copy(pair)
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
                pair.optJSONObject("recovery")?.let { recovery ->
                    try { session.restoreRecovery(ModernRecovery.restore(recovery)) } catch (_: ModernRecoveryException) { }
                    require(session.recovery()?.export()?.toString() == recovery.toString()) { "Invalid retained recovery" }
                }
                val release = session.holdRemoteChanges(); val packets = pair.getJSONArray("deferred")
                session.restoreDeferredChanges((0 until packets.length()).map { ModernBatch.restore(packets.getJSONObject(it)) })
                require(session.save().export().toString() == pair.getJSONObject("accepted").toString()) { "Restored acceptance differs" }
                if (packets.length() == 0) release()
                val host = ModernAndroidHost(session, pair.getString("actorID"), store, pair.getString("revision"))
                host.relayReceipt = pair.optJSONObject("relay")?.let { ModernRelayReceipt.restore(it).also { record -> record.validate(session) } }
                fun records(name: String): List<JSONObject> = pair.getJSONArray(name).let { array -> (0 until array.length()).map { NativeJsonTransport.copy(array.getJSONObject(it)) } }
                host.drafts = records("drafts"); host.retainedClipboard = records("clipboard")
                host.retainedClipboard.forEach { it.optJSONObject("clipboard")?.let { value -> session.clipboardEncoded(value.toString()) } }
                return host to release // restored provider records remain inert
            } catch (failure: Throwable) { session.close(); throw failure }

        }
    }
}

private fun validatePair(pair: JSONObject) {
    require(exactCheckpointInt(pair.get("version")) == 1)
    require(pair.keys().asSequence().toSet() == setOf("version", "revision", "actorID", "documentID", "epoch", "accepted", "historySelection", "providers", "recovery", "deferred", "drafts", "clipboard") + if (pair.has("relay")) setOf("relay") else emptySet<String>()) { "Unknown checkpoint sidecar" }
    fun text(value: JSONObject, key: String): String { require(value.get(key) is String); return value.getString(key) }
    val documentID = text(pair, "documentID"); val epoch = text(pair, "epoch")
    text(pair, "actorID"); UUID.fromString(text(pair, "revision"))
    fun bounded(name: String, limit: Int) { require(pair.get(name).toString().toByteArray(Charsets.UTF_8).size <= limit) { "Oversized $name" } }
    bounded("accepted", 64_000_000); bounded("historySelection", 16_000_000); bounded("providers", 16_000_000)
    bounded("recovery", 64_000_000); bounded("deferred", 64_000_000); bounded("drafts", 16_000_000); bounded("clipboard", 64_000_000)
    require(pair.getJSONArray("deferred").length() <= 64)
    pair.optJSONObject("relay")?.let { value ->
        bounded("relay", 16_000_000)
        val relay = ModernRelayReceipt.restore(value)
        require(relay.receipt.documentID == documentID && relay.receipt.epoch == epoch)
    }
    val identifiers = mutableSetOf<String>()
    fun scoped(value: JSONObject) { require(value.getString("documentID") == documentID && value.getString("epoch") == epoch) }
    fun range(value: JSONObject) { scoped(value.getJSONObject("start")); scoped(value.getJSONObject("end")) }
    for (name in listOf("drafts", "clipboard")) {
        val array = pair.getJSONArray(name); require(array.length() <= 64)
        for (index in 0 until array.length()) {
            val value = array.getJSONObject(index); require(identifiers.add(text(value, "id")))
            require(text(value, "reason").length <= 1000)
            val target = value.getJSONObject("target")
            if (name == "drafts") {
                range(target); val replacement = text(value, "text"); val native = if (value.has("nativeText")) text(value, "nativeText") else replacement
                if (value.has("start") || value.has("end")) require(exactCheckpointInt(value.get("start")) in 0..native.length && exactCheckpointInt(value.get("end")) in 0..native.length)
            }
            else {
                require(target.has("range") != target.has("boundary"))
                target.optJSONObject("range")?.let { range(it) }; target.optJSONObject("boundary")?.let { scoped(it) }
                require(value.has("clipboard") || value.has("raw") || value.has("plainText"))
            }
        }
    }
}

private fun exactCheckpointInt(value: Any): Int { require(value is Number); return BigDecimal(value.toString()).intValueExact() }

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
