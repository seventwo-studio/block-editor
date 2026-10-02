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
    private val pastePolicy: () -> WritingPastePolicy = { WritingPastePolicy() },
    private val collections: Boolean = false) : Closeable {
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
    fun bind(identity: NodeIdentity, field: String = "content"): Binding {
        check(!closed)
        val key = writingKey(session.textAddress(identity, field))
        val capturedAddress = session.nodeAddress(identity)
        fun locationCurrent() = runCatching { session.nodeAddress(identity) == capturedAddress }.getOrDefault(false)
        val entry = entries.getOrPut(key) { Entry(WritingCollaborativeTextInput(session, identity, { !closed && editable() }, ::composing, report, field, collections)) }
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
            // Focus callbacks from replacement/disposal cannot cancel an owned
            // native caret handoff and authorize another field's IME draft.
            if (focusRequest?.let { it.key != binding.key } == true) return
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
        val current = NodeIdentity(address.export().getJSONObject("identity"))
        val location = session.nodeAddress(current)
        val node = writingNodeValue(session, current)
        if (collections && node.optString("type").isEmpty() && location.path.dropLast(1).lastOrNull() in setOf("items", "children"))
            session.enterListItem(address, selected.min, selected.max, newBlockID)
        else if (collections && (address.path.last() != "content" || location.path.dropLast(1).lastOrNull() == "cells"))
            session.softBreak(address, selected.min, selected.max)
        else session.splitParagraph(address, selected.min, selected.max, newBlockID)
    }
    fun softBreak(binding: Binding, revokeNative: () -> Unit) = perform(binding, revokeNative) { input ->
        val (address, selected) = checkNotNull(input).commandTarget()
        session.softBreak(address, selected.min, selected.max)
    }
    fun mergesParagraph(binding: Binding): Boolean = !collections || runCatching {
        binding.input.field == "content" && writingNodeValue(session, binding.input.identity).optString("type") == "paragraph"
    }.getOrDefault(false)
    fun mergePrevious(binding: Binding, revokeNative: () -> Unit) {
        check(!binding.input.plainField) { "Paragraph merge is unavailable in plain fields" }
        perform(binding, revokeNative) { input ->
            val (address, selected) = checkNotNull(input).commandTarget()
            check(selected.collapsed && selected.min == 0)
            val current = NodeIdentity(address.export().getJSONObject("identity"))
            val roots = session.collectionNodes(if (collections) writingParentCollection(session, current) else NodeCollection.ROOT)
            val index = roots.indexOfFirst { writingCanonical(it.wire) == writingCanonical(current.wire) }
            check(index > 0) { "No compatible previous paragraph" }
            session.mergeParagraphs(roots[index - 1], current)
        }
    }
    /** All range derivation happens after the current native lease commits and peers drain. */
    fun paste(binding: Binding, revokeNative: () -> Unit, clipboard: WritingClipboard) {
        // Reject rich/structural content before finalizing a plain-field draft.
        if (binding.input.plainField) validatePlainPaste(clipboard)
        perform(binding, revokeNative) { input ->
            val live = checkNotNull(input)
            val (address, selected) = live.commandTarget()
            val range = session.selectedText(address, selected.min, selected.max)
            val imported = session.normalizeForImport(clipboard, pastePolicy())
            if (live.plainField || session.save().export().getInt("version") == 4)
                session.pasteInline(imported.clipboard, range, imported.effectivePastePolicy)
            else session.pasteSelection(imported.clipboard, range, imported.effectivePastePolicy)
        }
    }
    private fun validatePlainPaste(clipboard: WritingClipboard) {
        val wire = clipboard.export()
        val parts = wire.optJSONArray("parts")
        check(wire.optInt("version") == 1 && parts != null && parts.length() == 1) { "Plain fields require one inline text fragment" }
        val part = parts.getJSONObject(0)
        val values = part.optJSONObject("inline")?.optJSONArray("_0")
        check(values != null && !part.has("node")) { "Structural paste is unsupported in plain fields" }
        for (index in 0 until values.length()) {
            val value = values.optJSONObject(index)
            check(value != null && value.optString("type") == "text" && value.opt("text") is String &&
                value.keys().asSequence().all { it in setOf("type", "text", "marks") } &&
                (!value.has("marks") || (value.opt("marks") is org.json.JSONArray && value.getJSONArray("marks").length() == 0))) {
                "Rich marks, references and metadata are unsupported in plain fields"
            }
        }
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
    fun format(binding: Binding, revokeNative: () -> Unit, type: String, mark: org.json.JSONObject?) {
        check(!binding.input.plainField) { "Formatting is unavailable in plain fields" }
        perform(binding, revokeNative) { input ->
            val (address, selected) = checkNotNull(input).commandTarget()
            session.format(address, selected.min, selected.max, type, mark)
            null
        }
    }
    fun convert(binding: Binding, revokeNative: () -> Unit, target: WritingBlockTarget) {
        check(!binding.input.plainField) { "Conversion is unavailable in plain fields" }
        perform(binding, revokeNative) { input ->
            val (address, selected) = checkNotNull(input).commandTarget()
            session.convertBlock(address, selected.min, target)
        }
    }
    fun markdownShortcut(binding: Binding, revokeNative: () -> Unit) {
        check(!binding.input.plainField) { "Markdown shortcuts are unavailable in plain fields" }
        perform(binding, revokeNative) { input ->
            val (address, selected) = checkNotNull(input).commandTarget()
            check(selected.collapsed) { "Markdown shortcut requires a caret" }
            session.markdownShortcut(address, selected.min)
        }
    }
    /** Targets are opaque origins; resolve collection order only after composition and peers finish. */
    fun insert(revokeNative: () -> Unit, values: org.json.JSONArray, collection: NodeCollection, after: NodeIdentity? = null) {
        session.collectionNodes(collection) // Preflight a retired owner before committing a draft.
        after?.let { session.nodeAddress(it) }
        perform(null, revokeNative) {
            writingFirstPosition(session, session.insertCollectionNodes(values, collection, after).nodes.firstOrNull())
        }
    }
    fun append(revokeNative: () -> Unit, values: () -> org.json.JSONArray, collection: NodeCollection) {
        session.collectionNodes(collection)
        perform(null, revokeNative) {
            val after = session.collectionNodes(collection).lastOrNull()
            writingFirstPosition(session, session.insertCollectionNodes(values(), collection, after).nodes.firstOrNull())
        }
    }
    fun indent(revokeNative: () -> Unit, identity: NodeIdentity) {
        check(writingSiblingIndex(session, identity).first > 0) { "No preceding list item" }
        perform(null, revokeNative) {
            val siblings = session.collectionNodes(writingParentCollection(session, identity))
            val index = siblings.indexOfFirst { writingCanonical(it.wire) == writingCanonical(identity.wire) }
            check(index > 0) { "No preceding list item" }
            val owner = siblings[index - 1]
            val target = NodeCollection.children(owner)
            session.moveSelection(WritingSelection(nodes = listOf(identity)), target, session.collectionNodes(target).lastOrNull())
            null
        }
    }
    fun outdent(revokeNative: () -> Unit, identity: NodeIdentity) {
        check(writingMayOutdent(session, identity)) { "Not a nested list item" }
        perform(null, revokeNative) {
            val address = session.nodeAddress(identity)
            check(address.path.dropLast(1).lastOrNull() == "children") { "Not a nested list item" }
            val owner = session.node(NodeAddress(address.blockID, address.path.dropLast(2)))
            check(writingNodeValue(session, owner).optString("type").isEmpty()) { "Parent is not a list item" }
            session.moveSelection(WritingSelection(nodes = listOf(identity)), writingParentCollection(session, owner), owner)
            null
        }
    }
    fun listStyle(revokeNative: () -> Unit, identity: NodeIdentity, style: String) {
        session.nodeAddress(identity)
        perform(null, revokeNative) {
            val first = session.collectionNodes(NodeCollection.items(identity)).firstOrNull() ?: error("List has no item")
            session.convertBlock(session.textAddress(first), 0, WritingBlockTarget("list", style = style))
            null
        }
    }
    fun move(revokeNative: () -> Unit, identity: NodeIdentity, direction: Int) {
        val (beforeIndex, beforeCount) = writingSiblingIndex(session, identity)
        check(direction in setOf(-1, 1) && beforeIndex >= 0 && beforeIndex + direction in 0 until beforeCount) { "Already at collection boundary" }
        perform(null, revokeNative) {
            val collection = writingParentCollection(session, identity)
            val siblings = session.collectionNodes(collection)
            val index = siblings.indexOfFirst { writingCanonical(it.wire) == writingCanonical(identity.wire) }
            check(index >= 0 && direction in setOf(-1, 1))
            val destination = index + direction
            check(destination in siblings.indices) { "Already at collection boundary" }
            val after = if (direction < 0) siblings.getOrNull(index - 2) else siblings[destination]
            session.moveSelection(WritingSelection(nodes = listOf(identity)), collection, after)
            null
        }
    }
    fun duplicate(revokeNative: () -> Unit, identity: NodeIdentity) {
        session.nodeAddress(identity)
        perform(null, revokeNative) {
            writingFirstPosition(session, session.duplicateSelection(WritingSelection(nodes = listOf(identity)),
                writingParentCollection(session, identity), identity).nodes.firstOrNull())
        }
    }
    fun delete(revokeNative: () -> Unit, identity: NodeIdentity) {
        session.nodeAddress(identity)
        perform(null, revokeNative) {
            session.deleteSelection(WritingSelection(nodes = listOf(identity))).text.firstOrNull()?.start
        }
    }
    fun checked(revokeNative: () -> Unit, identity: NodeIdentity, value: Boolean) {
        session.nodeAddress(identity)
        perform(null, revokeNative) { session.setNodeField(identity, listOf("checked"), value); null }
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
