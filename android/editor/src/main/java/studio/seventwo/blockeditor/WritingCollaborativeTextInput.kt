package studio.seventwo.blockeditor

import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.compose.ui.text.TextRange
import androidx.compose.ui.text.input.TextFieldValue
import org.json.JSONArray
import org.json.JSONObject

/** Export a failed native draft together with both accepted and deferred history.
 * The host persists this record before releasing an input owner. */
data class WritingInputDraft(val address: WritingAddress, val text: String,
    val selectionStart: Int, val selectionEnd: Int, val reason: String,
    val accepted: WritingBatch, val deferred: List<WritingBatch>, val recovery: WritingRecovery?)

/** Native offsets are UTF-16, but a replacement never cuts a surrogate pair.
 * Keeping the unchanged prefix/suffix avoids replacing marks and reference atoms. */
internal fun writingDifference(old: String, next: String): Triple<Int, Int, String> {
    val before = old.codePoints().toArray(); val after = next.codePoints().toArray()
    require(after.none { it in 0xd800..0xdfff }) { "Native text contains an unpaired surrogate" }
    var prefix = 0; var suffix = 0
    while (prefix < minOf(before.size, after.size) && before[prefix] == after[prefix]) prefix++
    while (suffix < minOf(before.size, after.size) - prefix && before[before.size - 1 - suffix] == after[after.size - 1 - suffix]) suffix++
    val start = old.offsetByCodePoints(0, prefix)
    val end = old.offsetByCodePoints(0, before.size - suffix)
    return Triple(start, end, String(after, prefix, after.size - prefix - suffix))
}

internal class WritingCollaborativeTextInput(
    private val session: WritingSession, val identity: NodeIdentity,
    private val editable: () -> Boolean, private val compositionChanged: () -> Unit,
    private val report: (Exception) -> Unit,
) {
    val address: WritingAddress = session.textAddress(identity)
    var value by mutableStateOf(TextFieldValue(readText()))
        private set
    var failedReason by mutableStateOf<String?>(null)
        private set
    private var release: (() -> Unit)? = null
    private var blockedDrain = false
    private var committedBeforeDrain: String? = null
    private var closed = false
    private var committing = false
    private var finishing = false
    val acceptsFinalNativeValue: Boolean get() = finishing
    val composing: Boolean get() = !closed && (value.composition != null || release != null)
    val requiresCommit: Boolean get() = composing || failedReason != null || value.text != runCatching { readText() }.getOrDefault(value.text)
    private var anchors: WritingTextRange? = null
    private var retained: WritingTextRange? = null
    private val unsubscribeBefore = session.subscribeBeforeReceive {
        prepare(); val rollback: () -> Unit = { anchors = null }; rollback
    }
    private val unsubscribe = session.subscribe { refresh() }
    fun liveAddress(): WritingAddress {
        val current = session.nodeAddress(identity)
        check(current.path.isEmpty()) { "Paragraph moved outside this root-only surface" }
        val node = fieldValue(session.snapshot, current.blockID, current.path) as? JSONObject
        check(node?.optString("type") == "paragraph") { "This surface edits paragraphs only" }
        return session.textAddress(identity)
    }
    fun readNodes(): JSONArray {
        liveAddress()
        val current = session.nodeAddress(identity)
        return fieldValue(session.snapshot, current.blockID, current.path + "content") as? JSONArray ?: error("Paragraph content is not rich text")
    }
    fun readText(): String = plainText(readNodes())
    fun canAuthor(): Boolean = !closed && editable() && runCatching { liveAddress(); true }.getOrDefault(false)
    fun update(next: TextFieldValue) {
        if (!canAuthor()) return
        if (next.selection != value.selection) { retained = null; anchors = null }
        value = next
        if (finishing) return
        if (next.composition != null) {
            if (release == null) release = session.deferRemoteChanges()
            compositionChanged(); return
        }
        try { commit() } catch (error: Exception) { failedReason = error.message ?: error.javaClass.simpleName; report(error) }
    }
    /** A real focus/InputConnection revocation may synchronously send corrections.
     * Capture that exact lease's final value before committing or releasing peers. */
    fun finish(revokeNativeInput: () -> Unit) {
        check(canAuthor()) { "Shared input is not editable or its origin is retired" }
        if (release == null) release = session.deferRemoteChanges()
        finishing = true
        try { revokeNativeInput() } finally { finishing = false }
        check(canAuthor()) { "Authoring permission changed during native finalization" }
        try { commit() } catch (error: Exception) { failedReason = error.message ?: error.javaClass.simpleName; throw error }
    }
    private fun commit() {
        check(canAuthor())
        committing = true
        try {
            if (blockedDrain) {
                check(value.text == committedBeforeDrain) { "Retain the changed draft before resolving failed remote delivery" }
                value = value.copy(composition = null)
                val finish = release; release = null; compositionChanged()
                if (finish != null) finish() else session.retryDeferredChanges()
                session.mergeRecovery()?.let { throw WritingRecoveryException(it) }
                blockedDrain = false; committedBeforeDrain = null; failedReason = null
                val saved = retained
                val selected = saved?.let { session.resolvePosition(it.start) to session.resolvePosition(it.end) }
                if (selected != null && writingKey(selected.first.address) == writingKey(address) && writingKey(selected.second.address) == writingKey(address)) {
                    value = TextFieldValue(readText(), TextRange(selected.first.offset, selected.second.offset))
                }
                anchors = saved
                return
            }
            val live = liveAddress(); val text = readText()
            fun scalarBoundary(offset: Int) = offset in 0..value.text.length &&
                (offset == 0 || offset == value.text.length || !(value.text[offset - 1].isHighSurrogate() && value.text[offset].isLowSurrogate()))
            check(scalarBoundary(value.selection.start) && scalarBoundary(value.selection.end)) { "Native selection cuts a Unicode scalar" }
            if (text != value.text) {
                val delta = writingDifference(text, value.text)
                session.replaceText(live, delta.first, delta.second, delta.third)
                retained = null
            }
            // Validate atomic references and native selection before releasing peers.
            val previous = retained
            val resolved = previous?.let { runCatching { session.resolvePosition(it.start) to session.resolvePosition(it.end) }.getOrNull() }
            val selection = if (resolved != null && writingKey(resolved.first.address) == writingKey(live) &&
                writingKey(resolved.second.address) == writingKey(live) && resolved.first.offset == value.selection.start && resolved.second.offset == value.selection.end)
                previous else nativeRange(live, value.selection.start, value.selection.end)
            retained = selection; anchors = selection
            value = value.copy(composition = null)
            failedReason = null
            val finish = release; release = null; compositionChanged()
            try { finish?.invoke() } catch (error: Exception) { blockedDrain = true; committedBeforeDrain = value.text; throw error }
        } finally { committing = false; if (!requiresCommit) refresh() }
    }
    private fun nativeRange(address: WritingAddress, start: Int, end: Int): WritingTextRange {
        val range = session.selectedText(address, minOf(start, end), maxOf(start, end))
        return if (start <= end) range else WritingTextRange(JSONObject().put("start", range.end.export()).put("end", range.start.export()))
    }
    fun prepare() {
        if (closed || composing || committing) return
        anchors = runCatching {
            val saved = retained
            if (saved != null) {
                val a = session.resolvePosition(saved.start); val b = session.resolvePosition(saved.end)
                if (writingKey(a.address) == writingKey(b.address) && writingKey(a.address) != writingKey(address)) return@runCatching saved
                if (writingKey(a.address) == writingKey(liveAddress()) && writingKey(b.address) == writingKey(a.address) &&
                    minOf(a.offset, b.offset) == value.selection.min && maxOf(a.offset, b.offset) == value.selection.max) return@runCatching saved
            }
            nativeRange(liveAddress(), value.selection.start, value.selection.end)
        }.getOrNull()
    }
    /** A selection may now belong to a different paragraph after split/undo. */
    fun resolvedSelection(): WritingTextRange? = anchors ?: retained
    fun commandTarget(): Pair<WritingAddress, TextRange> {
        val saved = checkNotNull(resolvedSelection()) { "Native selection has no shared anchor" }
        val a = session.resolvePosition(saved.start); val b = session.resolvePosition(saved.end)
        check(writingKey(a.address) == writingKey(b.address)) { "Native selection spans shared fields" }
        return a.address to TextRange(a.offset, b.offset)
    }
    fun refresh() {
        if (closed || committing || composing || failedReason != null) return
        val saved = anchors ?: retained
        val resolved = runCatching {
            saved?.let { session.resolvePosition(it.start) to session.resolvePosition(it.end) }
        }.getOrNull()
        if (resolved != null && writingKey(resolved.first.address) == writingKey(resolved.second.address)) {
            retained = saved
            // A different origin is delivered to its own controller by the owner.
            if (writingKey(resolved.first.address) == writingKey(address) && canAuthor()) {
                value = TextFieldValue(readText(), TextRange(resolved.first.offset, resolved.second.offset))
            }
        } else if (runCatching { liveAddress() }.isSuccess) {
            val text = readText()
            value = TextFieldValue(text, TextRange(value.selection.start.coerceIn(0, text.length), value.selection.end.coerceIn(0, text.length)))
        }
        anchors = null
    }
    fun adopt(selection: WritingTextRange) {
        val a = session.resolvePosition(selection.start); val b = session.resolvePosition(selection.end)
        check(writingKey(a.address) == writingKey(address) && writingKey(b.address) == writingKey(address))
        value = TextFieldValue(readText(), TextRange(a.offset, b.offset)); retained = selection; anchors = selection
    }
    fun draft(): WritingInputDraft? = if (requiresCommit) WritingInputDraft(address, value.text, value.selection.start,
        value.selection.end, failedReason ?: "Native composition is pending", session.save(), session.exportDeferredChanges(), session.mergeRecovery()) else null
    fun close(retain: (WritingInputDraft) -> Unit) {
        if (closed) return
        draft()?.let(retain) // A failed retainer leaves the controller and remote hold intact.
        closed = true; unsubscribe(); unsubscribeBefore()
        value = value.copy(composition = null); compositionChanged()
        val finish = release; release = null
        try { finish?.invoke() } catch (error: Exception) { report(error) }
    }
}

internal fun writingKey(address: WritingAddress): String {
    val value = address.export()
    return writingCanonical(value.opt("identity") ?: value.optString("blockID")) + ":" + address.path.last()
}
internal fun writingCanonical(value: Any?): String = when (value) {
    is JSONObject -> value.keys().asSequence().sorted().joinToString(",", "{", "}") { JSONObject.quote(it) + ":" + writingCanonical(value.get(it)) }
    is JSONArray -> (0 until value.length()).joinToString(",", "[", "]") { writingCanonical(value.get(it)) }
    is String -> JSONObject.quote(value)
    else -> value.toString()
}
