package studio.seventwo.blockeditor

import android.util.AtomicFile
import android.util.Base64
import android.system.Os
import android.system.OsConstants
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import org.json.JSONObject
import java.io.File
import java.io.RandomAccessFile
import java.util.UUID

/** Host-controlled cutover: immutable originals and the detached fresh pair are
 * verified before a single CAS pointer is activated. JNI stays on Main. Existing
 * writers must be quiesced before activation or rollback. */
class ModernActivationStore(private val directory: File, private val documentID: String) {
    private val pointer get() = File(directory, "active.json")
    private fun <T> locked(action: () -> T): T = RandomAccessFile(File(directory, ".activation.lock"), "rw").use { file -> file.channel.lock().use { action() } }
    private fun bytes(file: File): ByteArray {
        require(file.length() <= 384_000_000) { "Activation capacity exceeded" }
        return AtomicFile(file).openRead().use { it.boundedBytes(384_000_000) }
    }
    private fun readActive(): JSONObject? = if (!pointer.exists()) null else JSONObject(bytes(pointer).toString(Charsets.UTF_8)).also { verify(it) }
    private fun verify(value: JSONObject) {
        val id = UUID.fromString(value.getString("revision")).toString()
        require(value.getString("documentID") == documentID && value.getString("checkpointFile") == "session-$id.json" && value.getString("archiveFile") == "archive-$id.json" && value.getString("liveFile") == "live-$id.json")
        val pair = JSONObject(bytes(File(directory, value.getString("checkpointFile"))).toString(Charsets.UTF_8))
        val archive = JSONObject(bytes(File(directory, value.getString("archiveFile"))).toString(Charsets.UTF_8))
        require(pair.getString("documentID") == documentID && pair.getString("epoch") == value.getString("epoch") && archive.getString("documentID") == documentID && archive.getString("epoch") == value.getString("epoch"))
    }
    private fun publish(file: File, data: ByteArray, immutable: Boolean = false) {
        require(data.size <= 384_000_000)
        if (immutable && file.exists()) { check(bytes(file).contentEquals(data)) { "Immutable activation revision conflict" }; return }
        val atomic = AtomicFile(file); val output = atomic.startWrite()
        try { output.write(data); atomic.finishWrite(output) } catch (failure: Throwable) { atomic.failWrite(output); throw failure }
        Os.chmod(file.path, 384)
        val fd = Os.open(directory.path, OsConstants.O_RDONLY, 0)
        try { Os.fsync(fd) } finally { Os.close(fd) }
        check(bytes(file).contentEquals(data)) { "Activation readback mismatch" }
    }
    suspend fun active(): JSONObject? = withContext(Dispatchers.IO) { locked { readActive()?.let { NativeJsonTransport.copy(it) } } }
    suspend fun activate(archive: ModernCutoverArchive, candidate: JSONObject, expectedRevision: String?, oldWritersStopped: Boolean): JSONObject {
        check(oldWritersStopped) { "Old writers must be quiesced" }
        val pair = NativeJsonTransport.copy(candidate); val original = archive.export().toString().toByteArray(Charsets.UTF_8)
        require(pair.getString("documentID") == documentID && archive.export().getString("documentID") == documentID && pair.getString("epoch") == archive.export().getString("epoch"))
        val id = UUID.fromString(pair.getString("revision")).toString(); val cutover = ModernCutover()
        val archiveID = withContext(Dispatchers.Main.immediate) {
            val handle = cutover.begin(original.size.toLong()).export().getString("archiveID")
            try {
                for (offset in original.indices step 131072) cutover.append(handle, offset.toLong(), Base64.encodeToString(original.copyOfRange(offset, minOf(original.size, offset + 131072)), Base64.NO_WRAP))
                val prepared = cutover.prepareUploaded(handle)
                check(prepared.status == "prepared" && prepared.document != null) { prepared.reason ?: "Migration rejected" }
                val restored = ModernAndroidHost.restore(pair, ModernHostStore(File(directory, "live-$id.json"))).first.session
                try { check(restored.snapshot.syncState.received.isEmpty() && restored.snapshot.document.export().toString() == prepared.document!!.export().toString()) { "Candidate does not match migration" } } finally { restored.close() }
                handle
            } catch (failure: Throwable) { cutover.forget(handle); throw failure }
        }
        try {
            val activation = withContext(Dispatchers.IO) { locked {
                val previous = readActive(); check(previous?.getString("revision") == expectedRevision) { "Activation revision conflict" }
                check(previous == null || previous.getString("epoch") != pair.getString("epoch")) { "Migration requires a fresh epoch" }
                val value = modernObject("revision" to id, "documentID" to documentID, "epoch" to pair.getString("epoch"), "checkpointFile" to "session-$id.json", "archiveFile" to "archive-$id.json", "liveFile" to "live-$id.json", "previous" to previous)
                publish(File(directory, value.getString("archiveFile")), original, true)
                publish(File(directory, value.getString("checkpointFile")), pair.toString().toByteArray(Charsets.UTF_8), true)
                publish(File(directory, value.getString("liveFile")), pair.toString().toByteArray(Charsets.UTF_8), true)
                value
            } }
            val savedOriginal = withContext(Dispatchers.IO) { bytes(File(directory, activation.getString("archiveFile"))) }
            withContext(Dispatchers.Main.immediate) { for (offset in savedOriginal.indices step 131072) cutover.verifyReadback(archiveID, offset.toLong(), Base64.encodeToString(savedOriginal.copyOfRange(offset, minOf(savedOriginal.size, offset + 131072)), Base64.NO_WRAP)) }
            withContext(Dispatchers.IO) { locked {
                check(readActive()?.getString("revision") == expectedRevision) { "Activation revision conflict" }
                verify(activation); publish(pointer, activation.toString().toByteArray(Charsets.UTF_8))
            } }
            return activation
        } finally { withContext(Dispatchers.Main.immediate) { cutover.forget(archiveID) } }
    }
    suspend fun rollback(expectedRevision: String, oldWritersStopped: Boolean): JSONObject = withContext(Dispatchers.IO) { locked {
        check(oldWritersStopped)
        val current = readActive() ?: error("No active session"); check(current.getString("revision") == expectedRevision) { "Activation revision conflict" }
        val previous = current.optJSONObject("previous") ?: error("No previous activation")
        verify(previous); publish(pointer, previous.toString().toByteArray(Charsets.UTF_8)); NativeJsonTransport.copy(previous)
    } }
    suspend fun activeHostStore(): ModernHostStore? = active()?.let { ModernHostStore(File(directory, it.getString("liveFile"))) }
    suspend fun loadActive(): JSONObject? {
        val activation = active() ?: return null
        val pair = ModernHostStore(File(directory, activation.getString("liveFile"))).load() ?: error("Missing active checkpoint")
        require(pair.getString("documentID") == documentID && pair.getString("epoch") == activation.getString("epoch"))
        return pair
    }
}
