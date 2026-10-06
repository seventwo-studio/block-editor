package studio.seventwo.blockeditor.demo

import android.content.Context
import android.graphics.BitmapFactory
import android.net.Uri
import android.util.AtomicFile
import android.system.Os
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import org.json.JSONObject
import studio.seventwo.blockeditor.ModernMediaPresentation
import studio.seventwo.blockeditor.ModernPayload
import java.io.File
import java.util.UUID

/** The example application owns bytes and permissions, independently of JNI. */
suspend fun storeModernAsset(context: Context, uri: Uri, kind: String): ModernPayload = withContext(Dispatchers.IO) {
    val bytes = context.contentResolver.openInputStream(uri)?.use { input ->
        val output = java.io.ByteArrayOutputStream(); val buffer = ByteArray(65536)
        while (true) { val count = input.read(buffer); if (count < 0) break; require(count <= 16_000_000 - output.size()) { "Local example accepts files up to 16 MB" }; output.write(buffer, 0, count) }
        output.toByteArray()
    } ?: error("File permission unavailable")
    val id = UUID.randomUUID().toString(); val directory = File(context.filesDir, "modern-assets").apply { mkdirs() }; val file = File(directory, id)
    val atomic = AtomicFile(file); val output = atomic.startWrite()
    try { output.write(bytes); atomic.finishWrite(output) } catch (failure: Throwable) { atomic.failWrite(output); throw failure }
    Os.chmod(file.path, 384); check(atomic.openRead().use { it.readBytes() }.contentEquals(bytes)) { "Asset readback mismatch" }
    val metadata = JSONObject().put("src", "asset://$id")
    if (kind == "image") {
        val dimensions = BitmapFactory.Options().apply { inJustDecodeBounds = true }; BitmapFactory.decodeByteArray(bytes, 0, bytes.size, dimensions)
        require(dimensions.outWidth > 0 && dimensions.outHeight > 0) { "Unsupported image" }
        metadata.put("width", dimensions.outWidth).put("height", dimensions.outHeight).put("alt", uri.lastPathSegment ?: "Image")
    } else metadata.put("name", uri.lastPathSegment ?: "File").put("mimeType", context.contentResolver.getType(uri) ?: "application/octet-stream").put("size", bytes.size)
    ModernPayload.restore(metadata)
}
suspend fun resolveModernAsset(context: Context, value: ModernPayload): ModernMediaPresentation = withContext(Dispatchers.IO) {
    val metadata = value.export(); val source = metadata.optString("src")
    if (!source.startsWith("asset://")) return@withContext ModernMediaPresentation.Unavailable("Application has no local asset for this reference")
    val id = try { UUID.fromString(source.removePrefix("asset://")).toString() } catch (_: Throwable) { return@withContext ModernMediaPresentation.Unavailable("Invalid asset reference") }
    val file = File(File(context.filesDir, "modern-assets"), id)
    if (!file.isFile || file.length() > 16_000_000) return@withContext ModernMediaPresentation.Unavailable("Local asset unavailable")
    val label = metadata.optString("alt", metadata.optString("name", "Attachment"))
    if (metadata.optString("type") != "image") return@withContext ModernMediaPresentation.Available(label)
    val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }; BitmapFactory.decodeFile(file.path, bounds)
    var sample = 1; while (maxOf(bounds.outWidth, bounds.outHeight) / sample > 2048) sample *= 2
    val bitmap = BitmapFactory.decodeFile(file.path, BitmapFactory.Options().apply { inSampleSize = sample }) ?: return@withContext ModernMediaPresentation.Unavailable("Image decode failed")
    ModernMediaPresentation.Available(label, bitmap)
}
