package studio.seventwo.blockeditor

import android.content.ClipData
import android.content.ClipboardManager
import org.json.JSONArray
import org.json.JSONObject

/** Typed inert clipboard plus a plain companion; never resolve URI/Intent data. */
internal object WritingNativeClipboard {
    const val MIME = "application/x-seventwo-writing-clipboard+json"
    private fun bounded(text: String): String {
        require(text.length <= 1_000_000) { "Clipboard text exceeds the external import limit" }
        return text
    }
    /** Bound parser recursion before JSONTokener sees untrusted native data. */
    fun decodeTyped(text: String): WritingClipboard {
        val encoded = bounded(text)
        val containers = java.util.ArrayDeque<Char>()
        var quoted = false
        var escaped = false
        var previous: Char? = null
        for (character in encoded) {
            if (quoted) {
                if (escaped) escaped = false
                else if (character == '\\') escaped = true
                else if (character == '"') { quoted = false; previous = '"' }
                continue
            }
            // Android JSONTokener accepts non-JSON comments, single quotes and
            // bare literals. Reject those quote-hiding forms before parsing.
            require(character !in "'/#\\") { "Clipboard JSON uses a non-JSON token" }
            when (character) {
                '"' -> {
                    require(previous == null || previous in listOf('{', '[', ':', ',')) { "Clipboard JSON quote follows a bare token" }
                    quoted = true
                }
                '{', '[' -> {
                    require(containers.size < 128) { "Clipboard JSON exceeds the envelope depth limit" }
                    containers.addLast(character)
                }
                '}', ']' -> {
                    val expected = if (character == '}') '{' else '['
                    require(containers.pollLast() == expected) { "Malformed clipboard JSON containers" }
                }
            }
            if (character !in " \t\r\n") previous = character
        }
        require(!quoted && containers.isEmpty()) { "Malformed clipboard JSON envelope" }
        // The ordinary parser still owns complete JSON syntax and the shared
        // normalizer owns schema, payload depth, policy and unknown metadata.
        return WritingClipboard.restore(JSONObject(encoded))
    }
    fun plain(session: WritingSession, text: String): WritingClipboard {
        val normalized = bounded(text).replace("\r\n", "\n").replace('\r', '\n')
        require(normalized.count { it == '\n' } < 10_000) { "Clipboard has too many lines" }
        val version = session.save().export().getInt("version")
        return session.clipboardText(normalized, if (version == 4 || !normalized.contains('\n')) "inline" else "multiline")
    }
    fun read(manager: ClipboardManager, session: WritingSession): WritingClipboard? {
        val data = manager.primaryClip ?: return null
        if (data.description.hasMimeType(MIME)) {
            require(data.itemCount == 2) { "Malformed structured clipboard" }
            val encoded = data.getItemAt(1).text?.toString() ?: error("Structured clipboard is not inert text")
            return decodeTyped(encoded)
        }
        // Item.text is inert. coerceToText may access a ContentProvider/URI and
        // is deliberately excluded from this editor's clipboard boundary.
        val text = if (data.itemCount > 0) data.getItemAt(0).text?.toString() else null
        return text?.let { plain(session, it) }
    }
    fun write(manager: ClipboardManager, clipboard: WritingClipboard) {
        val value = clipboard.export(); val parts = value.getJSONArray("parts")
        val plain = (0 until parts.length()).joinToString("\n") { index ->
            val part = parts.getJSONObject(index)
            part.optJSONObject("inline")?.optJSONArray("_0")?.let(::plainText)
                ?: part.optJSONObject("node")?.optJSONObject("value")?.let { node ->
                    plainText(node.optJSONArray("content") ?: node.optJSONArray("summary") ?: JSONArray())
                } ?: ""
        }
        val encoded = bounded(value.toString())
        val data = ClipData("Shared writing", arrayOf("text/plain", MIME), ClipData.Item(bounded(plain)))
        data.addItem(ClipData.Item(encoded)); manager.setPrimaryClip(data)
    }
}
