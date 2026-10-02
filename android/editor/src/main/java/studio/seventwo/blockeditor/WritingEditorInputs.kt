package studio.seventwo.blockeditor

import androidx.compose.runtime.RememberObserver
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateMapOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.compose.ui.text.input.TextFieldValue
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.launch
import kotlinx.coroutines.yield
import java.io.Closeable

/** One owner per rendered shared-writing surface; drafts belong to opaque fields. */
internal class WritingEditorInputs(private val session: WritingSession, private val scope: CoroutineScope,
    private val editable: () -> Boolean, private val retainDrafts: (List<WritingInputDraft>) -> Unit,
    private val report: (Exception) -> Unit,
    private val pastePolicy: () -> WritingPastePolicy = { WritingPastePolicy() }) : Closeable {
    init {
        require(session.save().export().getInt("version") in setOf(4, 5, 6)) { "Use an explicit v4, v5 or v6 writing epoch" }
        session.acquireNativeInputOwner(this)
    }
    private class Entry(val input: WritingCollaborativeTextInput, var references: Int = 0,
        var reservations: Int = 0, var generation: Int = 0, var serial: Int = 0,
        var finalGeneration: Int? = null, var retirement: Job? = null)
    data class FocusRequest(val key: String, val range: WritingTextRange, val serial: Int)
    private val entries = linkedMapOf<String, Entry>()
    private val revisions = mutableStateMapOf<String, Int>()
    private var active: String? = null
    private var focused = false
    private var closed = false
    private var acting = false
    private var focusSerial = 0
    var focusRequest by mutableStateOf<FocusRequest?>(null)
        private set
    private val unsubscribe = session.subscribe {
        if (!acting && focused && focusRequest == null) {
            active?.let { key -> entries[key]?.input?.resolvedSelection()?.let { request(it, key) } }
        }
    }
    private fun composing() { if (!closed) session.setComposing(entries.values.any { it.input.composing }) }
    class Binding internal constructor(val key: String, val input: WritingCollaborativeTextInput,
        private val valid: () -> Boolean, private val finalValid: () -> Boolean,
        private val attachLease: () -> Unit, private val detachLease: () -> Unit,
        private val abandonLease: () -> Unit, private val mayUpdate: () -> Boolean) : RememberObserver {
        private var attached = false; private var reserved = true; private var retired = false
        internal var hadFocus = false
        fun current() = !retired && attached && valid()
        fun update(next: TextFieldValue) {
            if ((current() && mayUpdate()) || (!retired && attached && finalValid() && input.acceptsFinalNativeValue)) input.update(next)
        }
        internal fun attach() {
            check(!retired); if (attached) return
            attachLease(); reserved = false; attached = true
        }
        internal fun detach() {
            if (!attached) return
            attached = false; retired = true; detachLease()
        }
        override fun onRemembered() = Unit
        override fun onForgotten() = release()
        override fun onAbandoned() = release()
        private fun release() {
            if (retired) return
            retired = true
            if (attached) { attached = false; detachLease() }
            if (reserved) { reserved = false; abandonLease() }
        }
    }
    fun revision(key: String) = revisions[key] ?: 0
    fun bind(identity: NodeIdentity): Binding {
        check(!closed)
        val key = writingKey(session.textAddress(identity))
        val capturedAddress = session.nodeAddress(identity)
        fun locationCurrent() = runCatching { session.nodeAddress(identity) == capturedAddress }.getOrDefault(false)
        val entry = entries.getOrPut(key) { Entry(WritingCollaborativeTextInput(session, identity, { !closed && editable() }, ::composing, report)) }
        entry.retirement?.cancel(); entry.retirement = null; entry.reservations++
        val generation = ++entry.serial
        return Binding(key, entry.input,
            valid = { !closed && entries[key] === entry && entry.generation == generation && locationCurrent() },
            finalValid = { !closed && editable() && entries[key] === entry && entry.finalGeneration == generation && locationCurrent() },
            attachLease = {
                check(!closed && entries[key] === entry && entry.reservations > 0)
                entry.retirement?.cancel(); entry.retirement = null
                entry.reservations--; entry.references++; entry.generation = maxOf(entry.generation, generation)
            }, detachLease = {
                if (entries[key] === entry) { check(entry.references > 0); entry.references--; retire(key, entry) }
            }, abandonLease = {
                if (entries[key] === entry) { check(entry.reservations > 0); entry.reservations--; retire(key, entry) }
            }, mayUpdate = { editable() && focused && active == key && (focusRequest == null || focusRequest?.key == key) })
    }
    fun attach(binding: Binding) = binding.attach()
    fun detach(binding: Binding) = binding.detach()
    fun focusChanged(binding: Binding, hasFocus: Boolean) {
        if (!binding.current()) return
        if (hasFocus) {
            binding.hadFocus = true
            if (focusRequest?.key != binding.key) focusRequest = null
            active = binding.key; focused = true
        } else if (active == binding.key && binding.hadFocus) {
            binding.hadFocus = false; focused = false
            if (!acting) focusRequest = null // Intentional focus departure revokes deferred handoff.
        }
    }
    private fun retire(key: String, entry: Entry) {
        if (closed || entry.references != 0 || entry.reservations != 0) return
        entry.retirement?.cancel()
        entry.retirement = scope.launch {
            yield()
            if (entries[key] !== entry || entry.references != 0 || entry.reservations != 0 || focusRequest?.key == key) return@launch
            try {
                entry.input.close { retainDrafts(listOf(it)) }
                entries.remove(key)
                if (active == key) { active = null; focused = false }
            } catch (error: Exception) { report(error) } // Preserve owner/draft if host retention fails.
        }
    }
    fun consume(request: FocusRequest, binding: Binding) {
        if (focusRequest != request || !binding.current() || request.key != binding.key) return
        binding.input.adopt(request.range); focusRequest = null
    }
    private fun request(range: WritingTextRange, original: String? = null) {
        val resolved = try { session.resolvePosition(range.start) to session.resolvePosition(range.end) }
        catch (_: IllegalStateException) { return } // A remotely deleted origin has no destination to guess.
        val (a, b) = resolved
        if (writingKey(a.address) != writingKey(b.address)) return // Cross-field selection requires a broader surface.
        val key = writingKey(a.address)
        if (original != null && key == original) return
        focusRequest = FocusRequest(key, range, ++focusSerial)
    }
    private fun finalise(key: String, entry: Entry, revokeNative: () -> Unit) {
        check(entry.references > 0 && entry.input.canAuthor())
        entry.finalGeneration = entry.generation
        try {
            entry.input.finish {
                // Only the immediately current native lease may send a final correction.
                entry.generation = ++entry.serial; revisions[key] = revision(key) + 1
                revokeNative()
            }
        } finally { entry.finalGeneration = null }
    }
    /** Native finalization, accepted local draft, remote drain, then one shared command. */
    fun perform(binding: Binding?, revokeNative: () -> Unit, command: (WritingCollaborativeTextInput?) -> WritingPosition?) {
        check(!closed && editable()) { "Shared writing is read-only or closed" }
        check(focusRequest == null) { "Wait for the returned caret's native field" }
        val key = binding?.key ?: active
        val entry = key?.let { entries[it] }
        if (binding != null) check(binding.current() && focused && active == key)
        check(entries.values.none { it !== entry && it.input.requiresCommit }) { "Another input has a pending native draft" }
        acting = true
        try {
            if (entry != null) finalise(key!!, entry, revokeNative)
            check(entries.values.none { it.input.requiresCommit }) { "Commit the retained native draft first" }
            entries.values.forEach { it.input.prepare() }
            val sourceRange = entry?.input?.resolvedSelection()
            val caret = command(entry?.input)
            val returned = if (caret == null) sourceRange else {
                session.resolvePosition(caret)
                // Keep original head/atom provenance for Undo -> Redo on empty tails.
                WritingTextRange(org.json.JSONObject().put("start", caret.export()).put("end", caret.export()))
            }
            if (returned != null) request(returned)
        } catch (error: Exception) {
            // Finalization revoked a real native lease even when a command failed.
            // Restore only its original opaque selection, never a guessed sibling.
            if (entry != null && entry.input.canAuthor() && !entry.input.requiresCommit) {
                runCatching { entry.input.resolvedSelection()?.let { request(it) } }
            }
            throw error
        } finally { acting = false }
    }
    fun enter(binding: Binding, revokeNative: () -> Unit, newBlockID: String) = perform(binding, revokeNative) { input ->
        val (address, selected) = checkNotNull(input).commandTarget()
        session.splitParagraph(address, selected.min, selected.max, newBlockID)
    }
    fun softBreak(binding: Binding, revokeNative: () -> Unit) = perform(binding, revokeNative) { input ->
        val (address, selected) = checkNotNull(input).commandTarget()
        session.softBreak(address, selected.min, selected.max)
    }
    fun mergePrevious(binding: Binding, revokeNative: () -> Unit) = perform(binding, revokeNative) { input ->
        val (address, selected) = checkNotNull(input).commandTarget()
        check(selected.collapsed && selected.min == 0)
        val current = NodeIdentity(address.export().getJSONObject("identity"))
        val roots = session.collectionNodes(NodeCollection.ROOT)
        val index = roots.indexOfFirst { writingCanonical(it.wire) == writingCanonical(current.wire) }
        check(index > 0) { "No compatible previous root paragraph" }
        session.mergeParagraphs(roots[index - 1], current)
    }
    /** All range derivation happens after the current native lease commits and peers drain. */
    fun paste(binding: Binding, revokeNative: () -> Unit, clipboard: WritingClipboard) = perform(binding, revokeNative) { input ->
        val (address, selected) = checkNotNull(input).commandTarget()
        val range = session.selectedText(address, selected.min, selected.max)
        val imported = session.normalizeForImport(clipboard, pastePolicy())
        if (session.save().export().getInt("version") == 4)
            session.pasteInline(imported.clipboard, range, imported.effectivePastePolicy)
        else session.pasteSelection(imported.clipboard, range, imported.effectivePastePolicy)
    }
    fun copy(binding: Binding, revokeNative: () -> Unit, deliver: (WritingClipboard) -> Unit) = perform(binding, revokeNative) { input ->
        val (address, selected) = checkNotNull(input).commandTarget()
        deliver(session.copyClipboard(WritingSelection(text = listOf(session.selectedText(address, selected.min, selected.max)))))
        null
    }
    fun cut(binding: Binding, revokeNative: () -> Unit, deliver: (WritingClipboard) -> Unit) = perform(binding, revokeNative) { input ->
        val (address, selected) = checkNotNull(input).commandTarget()
        val range = session.selectedText(address, selected.min, selected.max)
        val selection = WritingSelection(text = listOf(range))
        deliver(session.copyClipboard(selection))
        session.deleteSelection(selection).text.firstOrNull()?.start
    }
    fun format(binding: Binding, revokeNative: () -> Unit, type: String, mark: org.json.JSONObject?) = perform(binding, revokeNative) { input ->
        val (address, selected) = checkNotNull(input).commandTarget()
        session.format(address, selected.min, selected.max, type, mark)
        null
    }
    fun convert(binding: Binding, revokeNative: () -> Unit, target: WritingBlockTarget) = perform(binding, revokeNative) { input ->
        val (address, selected) = checkNotNull(input).commandTarget()
        session.convertBlock(address, selected.min, target)
    }
    fun markdownShortcut(binding: Binding, revokeNative: () -> Unit) = perform(binding, revokeNative) { input ->
        val (address, selected) = checkNotNull(input).commandTarget()
        check(selected.collapsed) { "Markdown shortcut requires a caret" }
        session.markdownShortcut(address, selected.min)
    }
    fun history(revokeNative: () -> Unit, redo: Boolean) = perform(null, revokeNative) {
        if (redo) session.redo() else session.undo(); null
    }
    fun exportDrafts(): List<WritingInputDraft> = entries.values.mapNotNull { it.input.draft() }
    override fun close() {
        if (closed) return
        val drafts = exportDrafts()
        if (drafts.isNotEmpty()) retainDrafts(drafts) // Host failure must leave remote holds intact.
        closed = true; unsubscribe()
        entries.values.forEach { it.retirement?.cancel(); it.input.close { } }
        // Clear composing after all closed inputs; this surface owns the flag.
        session.setComposing(false); session.releaseNativeInputOwner(this)
        entries.clear(); revisions.clear(); active = null; focusRequest = null
    }
}
