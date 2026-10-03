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
    private var finishingNativeComposition = false
    internal val acceptsFinalNativeValue: Boolean get() = finishingNativeComposition
    private var release: (() -> Unit)? = null
    internal val requiresCommit: Boolean get() = value.composition != null || release != null
    internal fun canFinishUnchangedComposition(): Boolean =
        !closed && !finishingNativeComposition && requiresCommit && liveAddress() != null && value.text == readText()
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
        if (!finishingNativeComposition && !requiresCommit) {
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
        // Focus revocation may synchronously deliver the platform's final value.
        // Retain it, then let the explicit owner validate/drain before history.
        if (finishingNativeComposition) return
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
    fun select(next: TextFieldValue) {
        if (closed || next.text != value.text || next.composition != value.composition) return
        value = value.copy(selection = next.selection)
    }
    /** Finish only a native recomposition of already accepted text. A changed
     * draft must be committed through the ordinary input path first. */
    internal fun finishUnchangedComposition(revokeNativeInput: () -> Unit) {
        check(canFinishUnchangedComposition()) { "Commit the changed draft before history" }
        finishingNativeComposition = true
        try { revokeNativeInput() } finally { finishingNativeComposition = false }
        // Revocation can produce a final changed value (for example correction).
        // Preserve that draft and its remote hold; never run history over it.
        check(!closed && liveAddress() != null && value.text == readText()) { "Native input changed while ending composition; commit the retained draft first" }
        value = value.copy(composition = null)
        val finish = release; release = null
        // A failed remote drain must reach the command owner and suppress history.
        finish?.invoke()
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
