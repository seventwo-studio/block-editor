package studio.seventwo.blockeditor.demo

import android.util.AtomicFile
import org.json.JSONObject
import studio.seventwo.blockeditor.EditorSession
import java.io.Closeable
import java.io.File
import java.io.RandomAccessFile
import java.nio.channels.FileLock
import java.security.MessageDigest

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
        check(record.getInt("version") == 1) { "Unsupported local draft version" }
        check(record.getString("endpoint") == endpoint) { "Draft belongs to another endpoint" }
        return record
    }
    fun save(endpoint: String, actor: String, session: EditorSession) {
        val record = JSONObject().put("version", 1).put("endpoint", endpoint).put("actor", actor).put("snapshot", session.save())
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
