package studio.seventwo.blockeditor

import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.compose.ui.text.TextRange
import androidx.compose.ui.text.input.TextFieldValue
import org.json.JSONArray
import org.json.JSONObject
import java.io.Closeable

/** Compose owns in-progress composition; the engine receives the committed text. */
internal class CollaborativeTextInput(
    private val session: EditorSession,
    private val blockID: String,
    private val path: List<String> = listOf("content"),
    private val origin: NodeIdentity? = null,
    private val reportError: (Exception) -> Unit,
) : Closeable {
    var value by mutableStateOf(TextFieldValue(readText()))
        private set
    private var closed = false
    private var release: (() -> Unit)? = null
    private var anchors: Pair<JSONObject, JSONObject>? = null
    private val unsubscribeBefore = session.subscribeBeforeReceive {
        try {
            val address = checkNotNull(liveAddress())
            anchors = session.position(address.blockID, value.selection.start, address.path) to session.position(address.blockID, value.selection.end, address.path)
        } catch (_: Exception) { anchors = null }
        val rollback: () -> Unit = { anchors = null }
        rollback
    }
    private val unsubscribe = session.subscribe {
        if (value.composition == null) {
            val text = readText()
            val selection = try {
                anchors?.let { TextRange(session.resolvePosition(it.first), session.resolvePosition(it.second)) } ?: value.selection
            } catch (_: Exception) { value.selection }
            anchors = null
            value = TextFieldValue(text, TextRange(selection.start.coerceIn(0, text.length), selection.end.coerceIn(0, text.length)))
        }
    }
    fun update(next: TextFieldValue) {
        if (closed) return
        value = next
        if (next.composition != null) {
            if (release == null) release = session.deferRemoteChanges()
            return
        }
        try {
            if (next.text != readText()) {
                if (origin == null) session.setText(blockID, next.text, path)
                else session.setText(origin, next.text, path.last())
            }
        }
        catch (error: Exception) { value = TextFieldValue(readText()); reportError(error) }
        finally {
            val finish = release; release = null
            try { finish?.invoke() } catch (error: Exception) { reportError(error) }
        }
    }
    internal fun liveAddress(): NodeAddress? = if (origin == null) NodeAddress(blockID, path) else try {
        session.nodeAddress(origin).let { NodeAddress(it.blockID, it.path + path.last()) }
    } catch (_: IllegalStateException) { null }
    private fun readText(): String {
        val address = liveAddress() ?: return ""
        val field = fieldValue(session.snapshot, address.blockID, address.path)
        return when (field) {
            is String -> field
            is JSONArray -> plainText(field)
            else -> ""
        }
    }
    override fun close() {
        if (closed) return
        closed = true
        unsubscribeBefore(); unsubscribe()
        val finish = release; release = null
        try { finish?.invoke() } catch (error: Exception) { reportError(error) }
    }
}
