package studio.seventwo.blockeditor

import android.view.inputmethod.EditorInfo
import androidx.activity.ComponentActivity
import androidx.compose.material3.MaterialTheme
import androidx.compose.runtime.Composable
import androidx.compose.runtime.mutableStateOf
import androidx.compose.ui.ExperimentalComposeUiApi
import androidx.compose.ui.platform.InterceptPlatformTextInput
import androidx.compose.ui.platform.PlatformTextInputInterceptor
import androidx.compose.ui.semantics.SemanticsProperties
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.createAndroidComposeRule
import androidx.compose.ui.text.TextRange
import androidx.compose.ui.text.input.TextFieldValue
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.awaitCancellation
import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test

/** Rendered control regression checks. Semantics input does not accept system IME/TalkBack. */
@OptIn(ExperimentalTestApi::class)
class AuthoringControlsTest {
    @get:Rule val compose = createAndroidComposeRule<ComponentActivity>()

    @OptIn(ExperimentalComposeUiApi::class)
    private fun componentContent(content: @Composable () -> Unit) {
        // Own the rendered field's input connection, as ComposeInputTest does.
        // The installed keyboard can start composition after focus restoration
        // on API26; that correctly blocks toolbar actions and makes a component
        // history assertion race a different, system-IME acceptance boundary.
        val interceptor = PlatformTextInputInterceptor { request, _ ->
            val connection = request.createInputConnection(EditorInfo())
            try { awaitCancellation() } finally { connection.closeConnection() }
        }
        compose.setContent { InterceptPlatformTextInput(interceptor) { content() } }
    }

    @Test fun reusedLabelRejectsDeletedOriginCallback() {
        compose.runOnIdle {
            val session = EditorSession.create("reused-label-binding", "local", JSONArray("""[
                {"id":"p","type":"paragraph","content":[{"type":"text","text":"Original","marks":[]}]}
            ]"""), collaborationVersion = 2)
            val scope = CoroutineScope(Dispatchers.Main + SupervisorJob())
            val inputs = EditorInputs(session, scope) { /* Deleted origin may report a rejected edit. */ }
            try {
                val address = NodeAddress("p", listOf("content"))
                val origin = session.node(NodeAddress("p"))
                val old = inputs.bind(inputs.key(origin, address), origin, address)
                inputs.attach(old)
                session.deleteNode(origin)
                val replacement = session.insertNode(JSONObject("""{"id":"p","type":"paragraph","content":[{"type":"text","text":"Replacement","marks":[]}]}"""), NodeCollection.ROOT)
                val replacementSnapshot = session.snapshot.getJSONArray("blocks").toString()
                old.update(TextFieldValue("Late old-origin callback"))
                assertEquals(replacementSnapshot, session.snapshot.getJSONArray("blocks").toString())
                assertNotEquals(inputs.key(origin, address), inputs.key(replacement, address))
                val current = inputs.bind(inputs.key(replacement, address), replacement, address)
                inputs.attach(current)
                current.update(TextFieldValue("Valid replacement edit"))
                assertEquals("Valid replacement edit", plainText(session.snapshot.getJSONArray("blocks").getJSONObject(0).getJSONArray("content")))
                inputs.detach(old); inputs.detach(current)
            } finally { inputs.close(); scope.cancel(); session.close() }
        }
    }

    @Test fun detachedBindingRejectsLateCallbackWithoutClosingNewAttachment() {
        compose.runOnIdle {
            val session = EditorSession.create("detached-binding", "local", JSONArray("""[
                {"id":"p","type":"paragraph","content":[{"type":"text","text":"Original","marks":[]}]}
            ]"""), collaborationVersion = 2)
            val scope = CoroutineScope(Dispatchers.Main + SupervisorJob())
            val inputs = EditorInputs(session, scope) { throw it }
            try {
                val address = NodeAddress("p", listOf("content"))
                val origin = session.node(NodeAddress("p"))
                val key = inputs.key(origin, address)
                val old = inputs.bind(key, origin, address)
                inputs.attach(old)
                inputs.detach(old)
                val original = session.snapshot.getJSONArray("blocks").toString()
                // No coroutine yield occurs between detach and the stale callback.
                old.update(TextFieldValue("Late callback"))
                assertEquals(original, session.snapshot.getJSONArray("blocks").toString())
                val current = inputs.bind(key, origin, address)
                inputs.attach(current)
                inputs.detach(old) // Repeated disposal must not invalidate the new lease.
                old.update(TextFieldValue("Stale overwrite"))
                assertEquals(original, session.snapshot.getJSONArray("blocks").toString())
                current.update(TextFieldValue("Valid current edit", TextRange(18)))
                assertEquals("Valid current edit", plainText(session.snapshot.getJSONArray("blocks").getJSONObject(0).getJSONArray("content")))
                inputs.detach(current)
            } finally { inputs.close(); scope.cancel(); session.close() }
        }
    }

    @Test fun legacySlashIDsKeepDistinctNestedFields() {
        lateinit var session: EditorSession
        compose.runOnUiThread {
            session = EditorSession.create("legacy-delimiter-fields", "local", JSONArray("""[
                {"id":"t","type":"toggle","summary":[{"type":"text","text":"Root","marks":[]}],"children":[
                    {"id":"p/children/q","type":"paragraph","content":[{"type":"text","text":"First field","marks":[]}]},
                    {"id":"p","type":"toggle","summary":[{"type":"text","text":"Nested","marks":[]}],"children":[
                        {"id":"q","type":"paragraph","content":[{"type":"text","text":"Second field","marks":[]}]}]}]}
            ]"""))
        }
        try {
            compose.setContent { MaterialTheme { BlockEditor(session) } }
            val second = compose.onNode(hasSetTextAction() and hasText("Second field"))
            second.performScrollTo().performClick().performTextInputSelection(TextRange(0))
            second.performTextInput("日本語 ")
            compose.runOnIdle {
                val children = session.snapshot.getJSONArray("blocks").getJSONObject(0).getJSONArray("children")
                assertEquals("First field", plainText(children.getJSONObject(0).getJSONArray("content")))
                assertEquals("日本語 Second field", plainText(children.getJSONObject(1).getJSONArray("children").getJSONObject(0).getJSONArray("content")))
            }
            val first = compose.onNode(hasSetTextAction() and hasText("First field"))
            first.performScrollTo().performClick().performTextInputSelection(TextRange(0))
            first.performTextInput("Independent ")
            compose.runOnIdle {
                val children = session.snapshot.getJSONArray("blocks").getJSONObject(0).getJSONArray("children")
                assertEquals("Independent First field", plainText(children.getJSONObject(0).getJSONArray("content")))
                assertEquals("日本語 Second field", plainText(children.getJSONObject(1).getJSONArray("children").getJSONObject(0).getJSONArray("content")))
            }
        } finally { compose.runOnIdle { session.close() } }
    }

    @Test fun movedOriginRevokesOldNativeSelectionBeforeReplacementAttachment() {
        compose.runOnIdle {
            val blocks = JSONArray("""[
                {"id":"a","type":"toggle","summary":[{"type":"text","text":"First","marks":[]}],"children":[
                    {"id":"p","type":"paragraph","content":[{"type":"text","text":"Hello café","marks":[{"type":"italic"}]}],"consumer":{"id":"opaque"}}]},
                {"id":"b","type":"toggle","summary":[{"type":"text","text":"Second","marks":[]}],"children":[]}
            ]""")
            val local = EditorSession.create("moved-native-lease", "local", blocks, collaborationVersion = 2)
            val peer = EditorSession.create("moved-native-lease", "peer", blocks, collaborationVersion = 2)
            val scope = CoroutineScope(Dispatchers.Main + SupervisorJob())
            val inputs = EditorInputs(local, scope) { throw it }
            try {
                val oldAddress = NodeAddress("a", listOf("children", "p", "content"))
                val origin = local.node(NodeAddress("a", listOf("children", "p")))
                val key = inputs.key(origin, oldAddress)
                val old = inputs.bind(key, origin, oldAddress)
                inputs.attach(old)
                old.update(TextFieldValue("Hello café", TextRange(5, 2)))
                inputs.focusChanged(old, true)
                peer.moveNode(peer.node(NodeAddress("a", listOf("children", "p"))), NodeCollection.children(peer.node(NodeAddress("b"))))
                local.receive(peer.changes())
                assertFalse("Old address is revoked during replay, before Compose disposal", old.current())
                val accepted = local.save().toString()
                val receipt = local.syncState().toString()
                val request = inputs.focusRequest
                assertEquals(TextRange(5, 2), old.input.value.selection)
                // The still-attached old view can emit a collapsed selection
                // and a stale final value during native focus disposal.
                old.update(TextFieldValue("Hello café", TextRange(5)))
                old.update(TextFieldValue("Stale native overwrite", TextRange(22)))
                inputs.focusChanged(old, false)
                assertEquals(accepted, local.save().toString())
                assertEquals(receipt, local.syncState().toString())
                assertEquals(TextRange(5, 2), old.input.value.selection)
                assertEquals(request, inputs.focusRequest)
                val replacement = inputs.bind(key, origin, NodeAddress("b", listOf("children", "p", "content")))
                inputs.attach(replacement)
                assertTrue(replacement.current())
                assertSame(old.input, replacement.input)
                assertEquals(TextRange(5, 2), replacement.input.value.selection)
                replacement.update(TextFieldValue("He世界 café", TextRange(4)))
                inputs.detach(old)
                val leaf = local.snapshot.getJSONArray("blocks").getJSONObject(1).getJSONArray("children").getJSONObject(0)
                assertEquals("He世界 café", plainText(leaf.getJSONArray("content")))
                assertEquals("opaque", leaf.getJSONObject("consumer").getString("id"))
                assertEquals("italic", leaf.getJSONArray("content").getJSONObject(0).getJSONArray("marks").getJSONObject(0).getString("type"))
                inputs.detach(replacement)
            } finally { inputs.close(); scope.cancel(); local.close(); peer.close() }
        }
    }

    @Test fun remoteReparentingPreservesActiveNestedFieldAndReversedSelection() {
        lateinit var local: EditorSession
        lateinit var remote: EditorSession
        compose.runOnUiThread {
            val blocks = JSONArray("""[
                {"id":"a","type":"toggle","summary":[{"type":"text","text":"First","marks":[]}],"children":[
                    {"id":"p","type":"paragraph","content":[{"type":"text","text":"Hello café","marks":[{"type":"italic"}]}]}]},
                {"id":"b","type":"toggle","summary":[{"type":"text","text":"Second","marks":[]}],"children":[]}
            ]""")
            local = EditorSession.create("reparent-focus", "local", blocks, collaborationVersion = 2)
            remote = EditorSession.create("reparent-focus", "remote", blocks, collaborationVersion = 2)
        }
        try {
            compose.setContent { MaterialTheme { BlockEditor(local) } }
            val before = compose.onNodeWithTag("editor-text:a:children/p/content")
            before.performScrollTo().performClick().performTextInputSelection(TextRange(5, 2))
            val selected = before.fetchSemanticsNode().config[SemanticsProperties.TextSelectionRange]
            before.assertIsFocused()
            compose.runOnIdle {
                val origin = remote.node(NodeAddress("a", listOf("children", "p")))
                remote.moveNode(origin, NodeCollection.children(remote.node(NodeAddress("b"))))
                local.receive(remote.changes())
                assertTrue("Remote move must be applied before asserting rendered focus", local.syncState().getJSONArray("received").length() > 0)
                assertEquals(NodeAddress("b", listOf("children", "p")).wire().toString(), local.nodeAddress(origin).wire().toString())
            }
            val moved = compose.onNodeWithTag("editor-text:b:children/p/content")
            moved.assertIsFocused()
            assertEquals(selected, moved.fetchSemanticsNode().config[SemanticsProperties.TextSelectionRange])
            moved.performTextInput("世界")
            compose.runOnIdle {
                val content = local.snapshot.getJSONArray("blocks").getJSONObject(1).getJSONArray("children").getJSONObject(0).getJSONArray("content")
                assertEquals("He世界 café", plainText(content))
            }
        } finally { compose.runOnIdle { local.close(); remote.close() } }
    }

    @Test fun nestedUnicodeAndChecklistHistorySurviveSessionRestore() {
        lateinit var session: EditorSession
        compose.runOnUiThread {
            session = EditorSession.create("nested-controls", "local", JSONArray("""[
              {"id":"toggle","type":"toggle","summary":[{"type":"text","text":"Summary","marks":[]}],"children":[
                {"id":"child","type":"paragraph","content":[{"type":"text","text":"Nested café","marks":[{"type":"italic"}]},{"type":"mention","entityId":"ref","entityType":"user","label":"Reference"}]}]},
              {"id":"tasks","type":"list","style":"todo","items":[{"id":"task","checked":false,"content":[{"type":"text","text":"Keep history","marks":[]}],"children":[]}]},
              {"id":"asset","type":"image","src":"asset:opaque","alt":"Host asset"}
            ]"""), collaborationVersion = 2)
        }
        val host = mutableStateOf(session)
        val prefix = "日本語 👩🏽‍💻 "
        try {
            componentContent { MaterialTheme { BlockEditor(host.value) } }
            val initial = JSONArray(session.snapshot.getJSONArray("blocks").toString())
            val field = compose.onNodeWithTag("editor-text:toggle:children/child/content")
            field.performScrollTo().performClick().performTextInputSelection(TextRange(0))
            field.performTextInput(prefix)
            lateinit var afterText: JSONArray
            compose.runOnIdle {
                afterText = JSONArray(session.snapshot.getJSONArray("blocks").toString())
                val child = afterText.getJSONObject(0).getJSONArray("children").getJSONObject(0)
                assertEquals(prefix + "Nested caféReference", plainText(child.getJSONArray("content")))
                val nodes = child.getJSONArray("content")
                val reference = (0 until nodes.length()).map { nodes.getJSONObject(it) }.single { it.optString("type") == "mention" }
                assertEquals("ref", reference.getString("entityId"))
                assertEquals(initial.getJSONObject(1).toString(), afterText.getJSONObject(1).toString())
                assertEquals(initial.getJSONObject(2).toString(), afterText.getJSONObject(2).toString())
            }
            val checkbox = compose.onNodeWithTag("editor-check:tasks:items/task")
            checkbox.performScrollTo().performTouchInput { click() }
            lateinit var afterCheck: JSONArray
            compose.runOnIdle {
                afterCheck = JSONArray(session.snapshot.getJSONArray("blocks").toString())
                assertTrue(afterCheck.getJSONObject(1).getJSONArray("items").getJSONObject(0).getBoolean("checked"))
                assertEquals(afterText.getJSONObject(0).toString(), afterCheck.getJSONObject(0).toString())
                val restored = EditorSession.restore(session.save(), "local")
                host.value = restored
                session.close()
                session = restored
                assertEquals(afterCheck.toString(), session.snapshot.getJSONArray("blocks").toString())
            }
            compose.onNodeWithText("Undo").performTouchInput { click() }
            compose.runOnIdle { assertEquals(afterText.toString(), session.snapshot.getJSONArray("blocks").toString()) }
            compose.onNodeWithText("Undo").performTouchInput { click() }
            compose.runOnIdle { assertEquals(initial.toString(), session.snapshot.getJSONArray("blocks").toString()) }
            // Exercise the rendered authoring command through semantics. Screen
            // touch/keyboard occlusion is a separate installed-host acceptance
            // gate; do not turn that coordinate-dependent result into a history
            // assertion. Keep both intermediate and final documents explicit.
            compose.onNodeWithText("Redo").assertIsEnabled().performClick()
            compose.runOnIdle { assertEquals(afterText.toString(), session.snapshot.getJSONArray("blocks").toString()) }
            compose.onNodeWithText("Redo").assertIsEnabled().performClick()
            compose.runOnIdle { assertEquals(afterCheck.toString(), session.snapshot.getJSONArray("blocks").toString()) }
        } finally { compose.runOnIdle { session.close() } }
    }

    @Test fun contextualFormattingPreservesRemotePrefixReferenceAndSelection() {
        lateinit var local: EditorSession
        lateinit var remote: EditorSession
        compose.runOnUiThread {
            val blocks = JSONArray("""[{"id":"p","type":"paragraph","content":[
                {"type":"text","text":"Hello café ","marks":[{"type":"italic"}]},
                {"type":"mention","entityId":"ref","entityType":"user","label":"Reference"}]}]""")
            local = EditorSession.create("format-controls", "local", blocks)
            remote = EditorSession.create("format-controls", "remote", blocks)
        }
        try {
            compose.setContent { MaterialTheme { BlockEditor(local) } }
            val field = compose.onNodeWithTag("editor-text:p:content")
            field.performClick().performTextInputSelection(TextRange(5, 0))
            val selected = field.fetchSemanticsNode().config[SemanticsProperties.TextSelectionRange]
            lateinit var remoteOnly: JSONArray
            compose.runOnIdle {
                remote.setText("p", "RHello café Reference")
                local.receive(remote.changes())
                remoteOnly = JSONArray(local.snapshot.getJSONArray("blocks").toString())
            }
            assertEquals(TextRange(selected.start + 1, selected.end + 1), field.fetchSemanticsNode().config[SemanticsProperties.TextSelectionRange])
            compose.onNodeWithTag("editor-format:p:content:bold").performTouchInput { click() }
            compose.runOnIdle {
                val nodes = local.snapshot.getJSONArray("blocks").getJSONObject(0).getJSONArray("content")
                val values = (0 until nodes.length()).map { nodes.getJSONObject(it) }
                val hello = values.single { it.optString("text") == "Hello" }
                val marks = hello.getJSONArray("marks")
                assertTrue((0 until marks.length()).any { marks.getJSONObject(it).getString("type") == "bold" })
                assertTrue((0 until marks.length()).any { marks.getJSONObject(it).getString("type") == "italic" })
                val reference = values.single { it.optString("type") == "mention" }
                assertEquals("ref", reference.getString("entityId")); assertEquals("Reference", reference.getString("label"))
                assertEquals("RHello café Reference", plainText(nodes))
                remote.receive(local.changes())
                assertEquals(remote.snapshot.getJSONArray("blocks").toString(), local.snapshot.getJSONArray("blocks").toString())
            }
            assertEquals(TextRange(selected.start + 1, selected.end + 1), field.fetchSemanticsNode().config[SemanticsProperties.TextSelectionRange])
            compose.onNodeWithText("Undo").performTouchInput { click() }
            compose.runOnIdle { assertEquals(remoteOnly.toString(), local.snapshot.getJSONArray("blocks").toString()) }
            val archive = JSONObject(local.save().toString())
            compose.runOnIdle {
                val restored = EditorSession.restore(archive, "local")
                try {
                    restored.redo()
                    assertEquals(remote.snapshot.getJSONArray("blocks").toString(), restored.snapshot.getJSONArray("blocks").toString())
                } finally { restored.close() }
            }
        } finally { compose.runOnIdle { local.close(); remote.close() } }
    }

    @Test fun tableCellUnicodePreservesOtherCellsAndUndoAfterRestore() {
        lateinit var session: EditorSession
        compose.runOnUiThread {
            session = EditorSession.create("table-controls", "local", JSONArray("""[
              {"id":"table","type":"table","rows":[{"id":"row","cells":[
                {"id":"first","header":true,"content":[{"type":"text","text":"Header","marks":[{"type":"bold"}]}]},
                {"id":"second","content":[{"type":"text","text":"Cell café","marks":[{"type":"italic"}]},{"type":"mention","entityId":"ref","entityType":"user","label":"Reference"}]}]}]}
            ]"""), collaborationVersion = 2)
        }
        try {
            compose.setContent { MaterialTheme { BlockEditor(session) } }
            val initial = JSONArray(session.snapshot.getJSONArray("blocks").toString())
            val field = compose.onNodeWithTag("editor-text:table:rows/row/cells/second/content")
            field.performClick().performTextInputSelection(TextRange(0))
            field.performTextInput("日本語 👩🏽‍💻 ")
            compose.runOnIdle {
                val cells = session.snapshot.getJSONArray("blocks").getJSONObject(0).getJSONArray("rows").getJSONObject(0).getJSONArray("cells")
                assertEquals(initial.getJSONObject(0).getJSONArray("rows").getJSONObject(0).getJSONArray("cells").getJSONObject(0).toString(), cells.getJSONObject(0).toString())
                assertEquals("second", cells.getJSONObject(1).getString("id"))
                assertEquals("日本語 👩🏽‍💻 Cell caféReference", plainText(cells.getJSONObject(1).getJSONArray("content")))
                val restored = EditorSession.restore(session.save(), "local")
                try {
                    restored.undo()
                    assertEquals(initial.toString(), restored.snapshot.getJSONArray("blocks").toString())
                    restored.redo()
                    assertEquals(session.snapshot.getJSONArray("blocks").toString(), restored.snapshot.getJSONArray("blocks").toString())
                } finally { restored.close() }
            }
        } finally { compose.runOnIdle { session.close() } }
    }

    @Test fun inlineLinkRejectsScriptAndTracksRemoteTextWhileEditingUrl() {
        lateinit var local: EditorSession
        lateinit var remote: EditorSession
        compose.runOnUiThread {
            val blocks = JSONArray("""[{"id":"p","type":"paragraph","content":[{"type":"text","text":"Hello café","marks":[{"type":"italic"}]}]}]""")
            local = EditorSession.create("link-controls", "local", blocks)
            remote = EditorSession.create("link-controls", "remote", blocks)
        }
        try {
            componentContent { MaterialTheme { BlockEditor(local) } }
            val field = compose.onNodeWithTag("editor-text:p:content")
            field.performClick().performTextInputSelection(TextRange(0, 5))
            compose.onNodeWithText("Link", substring = false).performTouchInput { click() }
            val url = compose.onNode(hasSetTextAction() and hasText("Link URL"))
            url.performClick().performTextInput("javascript:alert(1)")
            compose.onNodeWithText("Apply link").performTouchInput { click() }
            compose.runOnIdle {
                assertFalse(local.snapshot.getJSONArray("blocks").toString().contains("\"type\":\"link\""))
            }
            url.performTextReplacement("https://example.test/document")
            lateinit var remoteOnly: JSONArray
            compose.runOnIdle {
                remote.setText("p", "RHello café")
                local.receive(remote.changes())
                remoteOnly = JSONArray(local.snapshot.getJSONArray("blocks").toString())
            }
            compose.onNodeWithText("Apply link").performTouchInput { click() }
            compose.runOnIdle {
                val nodes = local.snapshot.getJSONArray("blocks").getJSONObject(0).getJSONArray("content")
                val values = (0 until nodes.length()).map { nodes.getJSONObject(it) }
                val linked = values.single { it.optString("text") == "Hello" }
                val marks = linked.getJSONArray("marks")
                assertTrue((0 until marks.length()).any {
                    marks.getJSONObject(it).optString("type") == "link" && marks.getJSONObject(it).optString("href") == "https://example.test/document"
                })
                assertEquals("RHello café", plainText(nodes))
                val remotePrefix = values.first()
                assertEquals("R", remotePrefix.optString("text"))
                assertFalse(remotePrefix.getJSONArray("marks").toString().contains("https://example.test/document"))
            }
            compose.onNodeWithText("Undo").assertIsEnabled().performClick()
            compose.runOnIdle { assertEquals(remoteOnly.toString(), local.snapshot.getJSONArray("blocks").toString()) }
        } finally { compose.runOnIdle { local.close(); remote.close() } }
    }
}
