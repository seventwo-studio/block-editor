package studio.seventwo.blockeditor

import androidx.compose.runtime.RememberObserver
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.mutableStateMapOf
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
    private data class Entry(val input: CollaborativeTextInput, var references: Int = 0, var reservations: Int = 0,
                             var retirement: Job? = null, var generation: Int = 0, var leaseSerial: Int = 0,
                             var finishingGeneration: Int? = null)
    private val entries = mutableMapOf<String, Entry>()
    private val bindingRevisions = mutableStateMapOf<String, Int>()
    private var targetsSnapshot: JSONObject? = null
    private val collectionTargets = mutableMapOf<String, List<RenderedNodeTarget>>()
    private var active: String? = null
    private var activeAddress: NodeAddress? = null
    private var focused = false
    private var localAction = false
    private var closed = false
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
    class Binding internal constructor(val key: String, val input: CollaborativeTextInput,
                                      private val valid: () -> Boolean, private val finalValueValid: () -> Boolean,
                                      private val attachLease: () -> Unit, private val detachLease: () -> Unit,
                                      private val abandonLease: () -> Unit) : RememberObserver {
        private var attached = false
        private var reserved = true
        private var retired = false
        fun current(): Boolean = !retired && attached && valid()
        internal fun attach(): Boolean {
            check(!retired) { "Input binding is retired" }
            if (attached) return false
            // Consumption and ownership checks finish before callbacks become live.
            attachLease(); reserved = false; attached = true
            return true
        }
        internal fun detach(): Boolean {
            if (!attached) return false
            attached = false; retired = true
            detachLease()
            return true
        }
        // The reservation starts in the remember factory, before Compose can
        // dispose the old view and before this view's DisposableEffect attaches.
        override fun onRemembered() = Unit
        override fun onForgotten() = release()
        override fun onAbandoned() = release()
        private fun release() {
            if (retired) return
            retired = true
            if (attached) { attached = false; detachLease() }
            if (reserved) { reserved = false; abandonLease() }
        }
        fun update(value: TextFieldValue) {
            if (current() || (!retired && attached && finalValueValid() && input.acceptsFinalNativeValue)) input.update(value)
        }
    }
    fun bindingRevision(key: String): Int = bindingRevisions[key] ?: 0
    fun bind(key: String, identity: NodeIdentity?, address: NodeAddress): Binding {
        check(!closed) { "Editor input owner is closed" }
        val entry = entries.getOrPut(key) { Entry(CollaborativeTextInput(session, address.blockID, address.path, identity, report)) }
        entry.retirement?.cancel(); entry.retirement = null
        entry.reservations++
        val generation = ++entry.leaseSerial
        return Binding(key, entry.input,
            // A replayed origin can move before Compose detaches the old view.
            // Its late native selection/text belongs to the old address and
            // cannot overwrite the controller retained for the replacement.
            valid = { !closed && entries[key] === entry && entry.generation == generation && entry.input.liveAddress() == address },
            finalValueValid = { !closed && entries[key] === entry && entry.finishingGeneration == generation },
            attachLease = {
                check(!closed && entries[key] === entry && entry.reservations > 0) { "Input binding has no live reservation" }
                entry.retirement?.cancel(); entry.retirement = null
                entry.reservations--; entry.references++
                // A remembered-but-abandoned replacement never revokes the view
                // that stayed rendered. Older pending leases cannot supersede a
                // newer attached lease or an explicit native-history revocation.
                entry.generation = maxOf(entry.generation, generation)
            },
            detachLease = {
                if (entries[key] === entry) {
                    check(entry.references > 0) { "Input binding reference imbalance" }
                    entry.references--; scheduleRetirement(key, entry)
                }
            },
            abandonLease = {
                if (entries[key] === entry) {
                    check(entry.reservations > 0) { "Input binding reservation imbalance" }
                    entry.reservations--; scheduleRetirement(key, entry)
                }
            })
    }
    fun attach(binding: Binding) { binding.attach() }
    fun detach(binding: Binding) { binding.detach() }
    private fun scheduleRetirement(key: String, entry: Entry) {
        if (entry.references > 0 || entry.reservations > 0 || closed) return
        entry.retirement?.cancel()
        entry.retirement = scope.launch {
            // Pending remember leases, not timing alone, bridge replacement
            // composition and the next native attach. Yield also permits moves.
            yield()
            if (entry.references == 0 && entry.reservations == 0 && entries[key] === entry && focusRequest?.first != key) {
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
        if (entry.references == 0 && entry.reservations == 0) {
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
    private fun historyInput(): Pair<String, Entry>? {
        val pending = entries.filterValues { it.input.requiresCommit }
        if (pending.size != 1) return null
        val key = active ?: return null
        val entry = pending[key] ?: return null
        return if (entry.references > 0 && entry.input.canFinishUnchangedComposition()) key to entry else null
    }
    fun canPerformHistory(): Boolean = !closed && (entries.values.none { it.input.requiresCommit } || historyInput() != null)
    fun performHistory(revokeNativeInput: () -> Unit, action: () -> Unit) {
        check(!closed) { "Editor input owner is closed" }
        if (entries.values.any { it.input.requiresCommit }) {
            val (key, owner) = checkNotNull(historyInput()) { "Commit active changed input before history" }
            // Only the lease that is current now may deliver a synchronous
            // final native value. Older still-attached views remain revoked.
            owner.finishingGeneration = owner.generation
            try {
                owner.input.finishUnchangedComposition {
                    // Close the old callback lease before platform focus revocation.
                    // A fresh binding keeps this same controller/draft on recomposition.
                    owner.generation = ++owner.leaseSerial
                    bindingRevisions[key] = bindingRevision(key) + 1
                    focused = false; focusRequest = null
                    revokeNativeInput()
                }
            } finally { owner.finishingGeneration = null }
            check(entries.values.none { it.input.requiresCommit }) { "Input is still pending; commit it before history" }
        }
        perform(action)
    }
    override fun close() {
        if (closed) return
        closed = true
        unsubscribe()
        entries.values.forEach { it.retirement?.cancel(); it.input.close() }
        entries.clear(); bindingRevisions.clear(); collectionTargets.clear(); targetsSnapshot = null; active = null; focusRequest = null
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
