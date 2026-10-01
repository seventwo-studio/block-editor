package studio.seventwo.blockeditor.demo

import android.util.AtomicFile
import org.json.JSONObject
import studio.seventwo.blockeditor.EditorSession
import studio.seventwo.blockeditor.MergeRecovery
import studio.seventwo.blockeditor.MergeRecoveryException
import java.io.Closeable
import java.io.File
import java.io.RandomAccessFile
import java.nio.channels.FileLock
import java.security.MessageDigest
import java.util.UUID

/** Retain for the entire session: the saved actor must have exactly one writer. */
class LocalDraft(file: File) : Closeable {
    private val storage = AtomicFile(file)
    private val lockFile: RandomAccessFile
    private val lock: FileLock
    init {
        check(file.parentFile!!.mkdirs() || file.parentFile!!.isDirectory) { "Local draft directory unavailable" }
        lockFile = RandomAccessFile(File(file.path + ".lock"), "rw")
        try { lock = checkNotNull(lockFile.channel.tryLock()) { "This draft is already open" } }
        catch (error: Exception) { lockFile.close(); throw IllegalStateException("Cannot acquire local draft writer", error) }
    }
    fun read(endpoint: String): JSONObject? {
        if (!storage.baseFile.exists() && !File(storage.baseFile.path + ".bak").exists()) return null
        val record = JSONObject(storage.readFully().toString(Charsets.UTF_8))
        val version = record.getInt("version")
        check(version == 1 || version == 2) { "Unsupported local draft version" }
        check(version != 1 || (!record.has("recovery") && !record.has("purpose"))) { "Unsupported legacy draft fields" }
        if (record.has("purpose")) check(record.getString("purpose") in listOf("draft", "recoveryArchive")) { "Unsupported draft purpose" }
        check(record.getString("endpoint") == endpoint) { "Draft belongs to another endpoint" }
        return record
    }
    fun restore(record: JSONObject): Pair<String, EditorSession> {
        val actor = if (record.optString("purpose") == "recoveryArchive") UUID.randomUUID().toString() else record.getString("actor")
        val session = EditorSession.restore(record.getJSONObject("snapshot"), actor)
        try {
            if (record.has("recovery")) {
                val proposal = record.getJSONObject("recovery")
                try { session.receive(MergeRecovery.restore(proposal).batch) }
                catch (_: MergeRecoveryException) { /* Pending transport state remains separate from accepted history. */ }
            }
            return actor to session
        } catch (error: Exception) { session.close(); throw error }
    }
    fun save(endpoint: String, actor: String, session: EditorSession) {
        write(storage, record(endpoint, actor, session, "draft"))
    }
    fun exportRecovery(endpoint: String, actor: String, session: EditorSession, destination: File) {
        check(session.mergeRecovery() != null) { "No pending merge recovery" }
        check(!destination.exists() && !File(destination.path + ".bak").exists()) { "Recovery archive already exists" }
        check(destination.parentFile!!.mkdirs() || destination.parentFile!!.isDirectory) { "Recovery archive directory unavailable" }
        write(AtomicFile(destination), record(endpoint, actor, session, "recoveryArchive"))
    }
    private fun record(endpoint: String, actor: String, session: EditorSession, purpose: String): JSONObject {
        val record = JSONObject().put("version", 2).put("endpoint", endpoint).put("actor", actor)
            .put("snapshot", session.save()).put("purpose", purpose)
        session.mergeRecovery()?.let { record.put("recovery", it.export()) }
        return record
    }
    private fun write(storage: AtomicFile, record: JSONObject) {
        val output = storage.startWrite()
        try { output.write(record.toString().toByteArray(Charsets.UTF_8)); storage.finishWrite(output) }
        catch (error: Exception) { storage.failWrite(output); throw error }
    }
    override fun close() { try { if (lock.isValid) lock.release() } finally { lockFile.close() } }
    companion object {
        fun file(directory: File, endpoint: String): File {
            val hash = MessageDigest.getInstance("SHA-256").digest(endpoint.toByteArray(Charsets.UTF_8))
                .joinToString("") { "%02x".format(it) }
            return File(directory, "$hash.json")
        }
    }
}
