package studio.seventwo.blockeditor

import android.content.ClipData
import android.content.ClipboardManager
import android.content.Context
import androidx.activity.ComponentActivity
import androidx.compose.ui.test.junit4.createAndroidComposeRule
import androidx.compose.ui.text.TextRange
import androidx.compose.ui.text.input.TextFieldValue
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test

/** Typed shared JNI and foreground inert clipboard data; separate from installed IME acceptance. */
class WritingMarkdownInputTest {
    @get:Rule val compose = createAndroidComposeRule<ComponentActivity>()
    private fun seed() = JSONArray("""[{"id":"p","type":"paragraph","consumer":"owner-meta","content":[{"type":"text","text":"A","marks":[{"type":"bold"}]},{"type":"entity-ref","entityType":"person","entityId":"mira","label":"Mira","consumer":"reference-meta"},{"type":"text","text":"B","marks":[]}]}]""")
    private fun session(version: Int, document: String, actor: String = "a") = when (version) {
        4 -> WritingSession.createV4(document, actor, "four", seed())
        5 -> WritingSession.createV5(document, actor, "five", seed())
        else -> WritingSession.createV6(document, actor, "six", seed())
    }
    private fun texts(session: WritingSession) = session.snapshot.getJSONArray("blocks").let { blocks ->
        (0 until blocks.length()).map { plainText(blocks.getJSONObject(it).optJSONArray("content")) }
    }
    private fun rejected(action: () -> Unit) { try { action(); fail("Expected shared rejection") } catch (_: IllegalStateException) { } }

    @Test fun explicitMarkdownUsesPlainCompanionWhileOrdinaryPasteKeepsTypedPriority() {
        compose.setContent { androidx.compose.material3.Text("Shared clipboard test host") }
        compose.runOnIdle {
            val manager = compose.activity.getSystemService(Context.CLIPBOARD_SERVICE) as ClipboardManager
            for (version in listOf(4, 5, 6)) {
                val a = session(version, "markdown-companion-$version")
                try {
                    val dto = a.clipboardText("DTO", "inline")
                    val data = ClipData("Markdown companion", arrayOf("text/plain", WritingNativeClipboard.MIME), ClipData.Item("## Title 東京😀"))
                    data.addItem(ClipData.Item(dto.export().toString())); manager.setPrimaryClip(data)
                    assertEquals(writingCanonical(dto.export()), writingCanonical(checkNotNull(WritingNativeClipboard.read(manager, a)).export()))
                    if (version == 4) rejected { WritingNativeClipboard.readMarkdown(manager, a) }
                    else {
                        val parsed = checkNotNull(WritingNativeClipboard.readMarkdown(manager, a)).export().getJSONArray("parts")
                        val heading = parsed.getJSONObject(0).getJSONObject("node").getJSONObject("value")
                        assertEquals("heading", heading.getString("type")); assertEquals(2, heading.getInt("level"))
                        assertEquals("Title 東京😀", plainText(heading.getJSONArray("content")))
                    }
                    assertEquals(0, a.changes().export().getJSONArray("changes").length())
                    assertEquals(version, a.save().export().getInt("version"))
                    val malformed = ClipData("Plain remains explicit", arrayOf("text/plain", WritingNativeClipboard.MIME), ClipData.Item("Text"))
                    malformed.addItem(ClipData.Item("not JSON")); manager.setPrimaryClip(malformed)
                    val explicit = checkNotNull(WritingNativeClipboard.readMarkdown(manager, a)).export().getJSONArray("parts").getJSONObject(0)
                    val rich = if (version == 4) explicit.getJSONObject("inline").getJSONArray("_0")
                        else explicit.getJSONObject("node").getJSONObject("value").getJSONArray("content")
                    assertEquals("Text", plainText(rich))
                    try { WritingNativeClipboard.read(manager, a); fail("Ordinary structured paste must still validate its DTO") }
                    catch (_: org.json.JSONException) { }
                } finally { a.close() }
            }
        }
    }

    @Test fun compositionAndHeldPeerCommitBeforeMarkdownPasteWithOneUndoAndStableCaret() {
        compose.setContent { androidx.compose.material3.Text("Shared clipboard test host") }
        compose.runOnIdle {
            for (version in listOf(4, 5, 6)) {
                val a = session(version, "markdown-composition-$version"); val b = session(version, "markdown-composition-$version", "b")
                val scope = CoroutineScope(SupervisorJob() + Dispatchers.Unconfined)
                val owner = WritingEditorInputs(a, scope, { true }, { assertTrue(it.isEmpty()) }, { throw it })
                val original = a.node(NodeAddress("p")); val old = owner.bind(original); owner.attach(old); owner.focusChanged(old, true)
                try {
                    old.update(TextFieldValue("A東MiraB", TextRange(2), TextRange(1, 2)))
                    b.replaceText(b.textAddress(b.node(NodeAddress("p"))), 6, 6, "R"); a.receive(b.changes())
                    assertEquals(listOf("AMiraB"), texts(a)); assertEquals(1, a.exportDeferredChanges().size)
                    val parsed = WritingNativeClipboard.markdown(a, "M😀")
                    assertEquals("A東MiraB", old.input.value.text); assertEquals(1, a.exportDeferredChanges().size)
                    owner.paste(old, { old.update(TextFieldValue("A東京MiraB", TextRange(3))) }, parsed)
                    assertTrue(a.exportDeferredChanges().isEmpty())
                    val expected = if (version == 4) listOf("A東京M😀MiraBR") else listOf("A東京", "M😀", "MiraBR")
                    assertEquals(expected, texts(a)); assertEquals(3, a.changes().export().getJSONArray("changes").length())
                    assertEquals("owner-meta", writingNodeValue(a, original).getString("consumer"))
                    assertTrue(a.snapshot.toString().contains("reference-meta")); assertTrue(a.snapshot.toString().contains("bold"))
                    val returned = checkNotNull(owner.focusRequest)
                    assertEquals(if (version == 4) 6 else 0, a.resolvePosition(returned.range.start).offset)
                    val address = a.resolvePosition(returned.range.start).address
                    val fresh = owner.bind(NodeIdentity(address.export().getJSONObject("identity"))); owner.attach(fresh)
                    owner.consume(returned, fresh); owner.focusChanged(fresh, true); assertTrue(owner.exportDrafts().isEmpty())
                    val accepted = a.save().export().toString(); old.update(TextFieldValue("stale")); assertEquals(accepted, a.save().export().toString())
                    val reopened = WritingSession.restore(a.save(), "a")
                    try {
                        reopened.undo(); assertEquals(listOf("A東京MiraBR"), texts(reopened)); b.receive(reopened.changes())
                        assertEquals(texts(reopened), texts(b)); reopened.redo(); assertEquals(expected, texts(reopened))
                    } finally { reopened.close() }
                } finally { owner.close(); scope.cancel(); a.close(); b.close() }
            }
        }
    }

    @Test fun structuralMarkdownHasFreshIdentitiesPolicyAndExplicitProtocolAdmission() {
        compose.setContent { androidx.compose.material3.Text("Shared clipboard test host") }
        compose.runOnIdle {
            for (version in listOf(4, 5, 6)) {
                val a = session(version, "markdown-structure-$version")
                val scope = CoroutineScope(SupervisorJob() + Dispatchers.Unconfined)
                val owner = WritingEditorInputs(a, scope, { true }, { assertTrue(it.isEmpty()) }, { throw it })
                val original = a.node(NodeAddress("p")); val old = owner.bind(original); owner.attach(old); owner.focusChanged(old, true)
                try {
                    old.update(TextFieldValue("AMiraB", TextRange(0)))
                    val before = a.save().export().toString(); val receipts = a.syncState().export().toString()
                    if (version == 4) {
                        rejected { WritingNativeClipboard.markdown(a, "# Title\r\n\r\n- [x] Task 東京😀") }
                        assertEquals(before, a.save().export().toString()); assertEquals(receipts, a.syncState().export().toString())
                    } else {
                        owner.paste(old, {}, WritingNativeClipboard.markdown(a, "# Title\r\n\r\n- [x] Task 東京😀"))
                        val blocks = a.snapshot.getJSONArray("blocks"); assertEquals(3, blocks.length())
                        assertEquals("heading", blocks.getJSONObject(0).getString("type"))
                        assertEquals("list", blocks.getJSONObject(1).getString("type"))
                        assertEquals("todo", blocks.getJSONObject(1).getString("style"))
                        assertTrue(blocks.getJSONObject(1).getJSONArray("items").getJSONObject(0).getBoolean("checked"))
                        assertEquals("Task 東京😀", plainText(blocks.getJSONObject(1).getJSONArray("items").getJSONObject(0).getJSONArray("content")))
                        for (index in 0..1) assertTrue(blocks.getJSONObject(index).getString("id").startsWith("paste-a-1-"))
                        assertEquals(writingCanonical(original.wire), writingCanonical(a.node(NodeAddress("p")).wire))
                        assertEquals(1, a.changes().export().getJSONArray("changes").length()); assertEquals(version, a.save().export().getInt("version"))
                        val reopened = WritingSession.restore(a.save(), "a")
                        try { reopened.undo(); assertEquals(listOf("AMiraB"), texts(reopened)); reopened.redo(); assertEquals(writingCanonical(a.snapshot.getJSONArray("blocks")), writingCanonical(reopened.snapshot.getJSONArray("blocks"))) }
                        finally { reopened.close() }
                    }
                } finally { owner.close(); scope.cancel(); a.close() }
                val limited = session(version, "markdown-policy-$version")
                val limitedScope = CoroutineScope(SupervisorJob() + Dispatchers.Unconfined)
                val limitedOwner = WritingEditorInputs(limited, limitedScope, { true }, { assertTrue(it.isEmpty()) }, { throw it })
                val binding = limitedOwner.bind(limited.node(NodeAddress("p"))); limitedOwner.attach(binding); limitedOwner.focusChanged(binding, true)
                try {
                    limited.setAllowedBlockTypes(emptySet()); val before = limited.save().export().toString(); val receipts = limited.syncState().export().toString()
                    rejected { limitedOwner.paste(binding, {}, WritingNativeClipboard.markdown(limited, "# Restricted")) }
                    assertEquals(before, limited.save().export().toString()); assertEquals(receipts, limited.syncState().export().toString())
                } finally { limitedOwner.close(); limitedScope.cancel(); limited.close() }
            }
        }
    }

    @Test fun externalMarkdownBoundsRejectBeforeTouchingMarkedDraftOrHeldRemoteHistory() {
        compose.setContent { androidx.compose.material3.Text("Shared clipboard test host") }
        compose.runOnIdle {
            for (version in listOf(4, 5, 6)) {
                val a = session(version, "markdown-bounds-$version"); val b = session(version, "markdown-bounds-$version", "b")
                val scope = CoroutineScope(SupervisorJob() + Dispatchers.Unconfined)
                val owner = WritingEditorInputs(a, scope, { true }, { }, { throw it })
                val binding = owner.bind(a.node(NodeAddress("p"))); owner.attach(binding); owner.focusChanged(binding, true)
                try {
                    binding.update(TextFieldValue("A東京MiraB", TextRange(3), TextRange(1, 3)))
                    b.replaceText(b.textAddress(b.node(NodeAddress("p"))), 6, 6, "R"); a.receive(b.changes())
                    val before = a.save().export().toString(); val receipts = a.syncState().export().toString()
                    for (tooLarge in listOf("x".repeat(1_000_001), "\n".repeat(10_000))) {
                        try { WritingNativeClipboard.markdown(a, tooLarge); fail("External input must reject before shared parsing") }
                        catch (_: IllegalArgumentException) { }
                    }
                    if (version == 4) {
                        val manager = compose.activity.getSystemService(Context.CLIPBOARD_SERVICE) as ClipboardManager
                        manager.setPrimaryClip(ClipData.newPlainText("Explicit structural Markdown", "## Unavailable"))
                        var finalized = 0
                        rejected {
                            val parsed = checkNotNull(WritingNativeClipboard.readMarkdown(manager, a))
                            owner.paste(binding, { finalized++ }, parsed)
                        }
                        assertEquals(0, finalized)
                    }
                    assertEquals(before, a.save().export().toString()); assertEquals(receipts, a.syncState().export().toString())
                    assertEquals("A東京MiraB", binding.input.value.text); assertEquals(TextRange(1, 3), binding.input.value.composition)
                    assertEquals(1, a.exportDeferredChanges().size); assertEquals(version, a.save().export().getInt("version"))
                } finally { owner.close(); scope.cancel(); a.close(); b.close() }
            }
        }
    }
}
