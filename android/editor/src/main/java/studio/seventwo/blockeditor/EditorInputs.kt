package studio.seventwo.blockeditor

import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.compose.runtime.staticCompositionLocalOf
import androidx.compose.ui.text.input.TextFieldValue
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.launch
import kotlinx.coroutines.yield
import org.json.JSONArray
import org.json.JSONObject
import java.io.Closeable

internal val LocalEditorInputs = staticCompositionLocalOf<EditorInputs> { error("Missing editor input owner") }

/** A scoped origin owns its draft even when its rendered parent changes. */
internal class EditorInputs(private val session: EditorSession, private val scope: CoroutineScope,
                            private val report: (Exception) -> Unit) : Closeable {
    private data class Entry(val input: CollaborativeTextInput, var references: Int = 0, var retirement: Job? = null, var generation: Int = 0)
    private val entries = mutableMapOf<String, Entry>()
    private var targetsSnapshot: JSONObject? = null
    private val collectionTargets = mutableMapOf<String, List<RenderedNodeTarget>>()
    private var active: String? = null
    private var activeAddress: NodeAddress? = null
    private var focused = false
    private var localAction = false
    var focusRequest by mutableStateOf<Pair<String, Int>?>(null)
        private set
    private var revision = 0
    private val unsubscribe = session.subscribe {
        val key = active
        val address = key?.let { entries[it]?.input?.liveAddress() }
        if (key == null || address == null) {
            key?.let { retireUnused(it) }
            active = null; activeAddress = null; focused = false; focusRequest = null
        } else {
            if (address != activeAddress && (focused || localAction || focusRequest?.first == key)) focusRequest = key to ++revision
            activeAddress = address
        }
    }
    /** One native identity query per collection per snapshot, shared by rendered siblings. */
    fun renderedTargets(collection: NodeCollection, addressAt: (Int) -> NodeAddress): List<RenderedNodeTarget> {
        if (targetsSnapshot !== session.snapshot) {
            collectionTargets.clear(); targetsSnapshot = session.snapshot
        }
        return collectionTargets.getOrPut(canonical(collection.wire)) {
            session.nodes(collection).mapIndexed { index, identity -> RenderedNodeTarget(session, addressAt(index), identity) }
        }
    }
    fun key(identity: NodeIdentity?, address: NodeAddress): String =
        if (identity == null) "legacy:${canonical(address.wire())}" else "${canonical(identity.wire)}:${address.path.last()}"
    class Binding internal constructor(val key: String, val input: CollaborativeTextInput, private val valid: () -> Boolean) {
        private var attached = false
        fun current(): Boolean = attached && valid()
        internal fun attach(): Boolean { if (attached) return false; attached = true; return true }
        internal fun detach(): Boolean { if (!attached) return false; attached = false; return true }
        fun update(value: TextFieldValue) { if (current()) input.update(value) }
    }
    fun bind(key: String, identity: NodeIdentity?, address: NodeAddress): Binding {
        val entry = entries.getOrPut(key) { Entry(CollaborativeTextInput(session, address.blockID, address.path, identity, report)) }
        val generation = ++entry.generation
        return Binding(key, entry.input) { entries[key] === entry && entry.generation == generation }
    }
    fun attach(binding: Binding) {
        if (!binding.attach()) return
        entries.getValue(binding.key).also { it.retirement?.cancel(); it.retirement = null; it.references++ }
    }
    fun detach(binding: Binding) {
        // Retain the controller lease, but revoke the departing view's callbacks now.
        if (!binding.detach()) return
        val key = binding.key
        val entry = entries[key] ?: return
        entry.references--
        if (entry.references > 0) return
        entry.retirement = scope.launch {
            // Compose disposes the old location before attaching the new one.
            yield()
            if (entry.references == 0 && entries[key] === entry && focusRequest?.first != key) {
                entries.remove(key); entry.input.close()
                if (active == key) { active = null; activeAddress = null; focused = false; focusRequest = null }
            }
        }
    }
    fun requestedAddress(): NodeAddress? = focusRequest?.first?.let { entries[it]?.input?.liveAddress() }
    fun focusChanged(binding: Binding, hasFocus: Boolean) {
        if (!binding.current()) return
        val key = binding.key
        if (hasFocus) {
            if (focusRequest?.first != key) {
                val previous = focusRequest?.first
                focusRequest = null
                previous?.let { retireUnused(it) }
            }
            active = key; activeAddress = entries[key]?.input?.liveAddress(); focused = true
        } else if (active == key) focused = false
    }
    private fun retireUnused(key: String) {
        val entry = entries[key] ?: return
        if (entry.references == 0) {
            entries.remove(key); entry.retirement?.cancel(); entry.input.close()
            if (active == key) { active = null; activeAddress = null; focused = false }
        }
    }
    fun cancelFocusRestoration() {
        val key = focusRequest?.first
        focusRequest = null
        key?.let { retireUnused(it) }
    }
    fun consumedFocus(request: Pair<String, Int>) { if (focusRequest == request) focusRequest = null }
    fun perform(action: () -> Unit) {
        localAction = true
        try { action() } finally { localAction = false }
    }
    override fun close() {
        unsubscribe()
        entries.values.forEach { it.retirement?.cancel(); it.input.close() }
        entries.clear(); collectionTargets.clear(); targetsSnapshot = null; active = null; focusRequest = null
    }
}

/** A rendered action captures an origin before remote replay can reuse its label. */
internal class RenderedNodeTarget(private val session: EditorSession, val address: NodeAddress,
                                  val identity: NodeIdentity? = if (session.syncState().optInt("version", 1) >= 2) session.node(address) else null) {
    val key: String = identity?.let { canonical(it.wire) } ?: "legacy:${canonical(address.wire())}"
    fun current(): Boolean = identity?.let { runCatching { session.nodeAddress(it) == address }.getOrDefault(false) } ?: true
}

private fun canonical(value: Any?): String = when (value) {
    is JSONObject -> value.keys().asSequence().sorted().joinToString(",", "{", "}") { JSONObject.quote(it) + ":" + canonical(value.get(it)) }
    is JSONArray -> (0 until value.length()).joinToString(",", "[", "]") { canonical(value.get(it)) }
    is String -> JSONObject.quote(value)
    else -> value.toString()
}
