package studio.seventwo.blockeditor

import android.view.inputmethod.EditorInfo
import android.view.inputmethod.InputConnection
import androidx.activity.ComponentActivity
import androidx.compose.material3.MaterialTheme
import androidx.compose.runtime.mutableStateOf
import androidx.compose.ui.ExperimentalComposeUiApi
import androidx.compose.ui.platform.InterceptPlatformTextInput
import androidx.compose.ui.platform.PlatformTextInputInterceptor
import androidx.compose.ui.semantics.SemanticsActions
import androidx.compose.ui.semantics.SemanticsProperties
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.createAndroidComposeRule
import androidx.compose.ui.text.AnnotatedString
import androidx.compose.ui.text.TextRange
import kotlinx.coroutines.awaitCancellation
import org.json.JSONArray
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test

/** Real Compose InputConnection/component proof, not installed keyboard acceptance. */
@OptIn(ExperimentalComposeUiApi::class, ExperimentalTestApi::class)
class WritingComposeInputTest {
    @get:Rule val compose = createAndroidComposeRule<ComponentActivity>()
    private fun seed() = JSONArray("""[{"id":"p","type":"paragraph","content":[{"type":"text","text":"AB","marks":[{"type":"bold"}]},{"type":"entity-ref","entityType":"person","entityId":"mira","label":"Mira","host":"opaque"}]}]""")
    private fun texts(session: WritingSession) = session.snapshot.getJSONArray("blocks").let { blocks ->
        (0 until blocks.length()).map { plainText(blocks.getJSONObject(it).getJSONArray("content")) }
    }
    private fun retainedDrafts(drafts: List<WritingInputDraft>) { assertTrue("No pending draft in this test", drafts.isEmpty()) }

    @Test fun nativeMarkedTextAndHeldPeerCommitBeforeActualSharedEnter() {
        lateinit var a: WritingSession; lateinit var b: WritingSession
        val visible = mutableStateOf(true)
        var connection: InputConnection? = null
        val interceptor = PlatformTextInputInterceptor { request, _ ->
            val current = request.createInputConnection(EditorInfo()); connection = current
            try { awaitCancellation() } finally { current.closeConnection(); if (connection === current) connection = null }
        }
        compose.runOnUiThread {
            a = WritingSession.createV4("compose-shared-enter", "a", "v4", seed())
            b = WritingSession.createV4("compose-shared-enter", "b", "v4", seed())
        }
        try {
            compose.setContent { InterceptPlatformTextInput(interceptor) { MaterialTheme { run {
                val state = rememberWritingParagraphEditorState(a, ::retainedDrafts, reportError = { throw it })
                if (visible.value) WritingParagraphEditor(state, reportError = { throw it })
            } } } }
            val field = compose.onNode(hasSetTextAction()); field.performClick(); field.performTextInputSelection(TextRange(1))
            compose.waitUntil { connection != null }
            compose.runOnIdle { assertTrue(checkNotNull(connection).setComposingText("東京", 1)) }
            compose.runOnIdle {
                assertEquals(listOf("ABMira"), texts(a))
                b.replaceText(b.textAddress(b.node(NodeAddress("p"))), 6, 6, "R"); a.receive(b.changes())
                assertEquals(listOf("ABMira"), texts(a)); assertEquals(1, a.exportDeferredChanges().size)
            }
            field.assertTextContains("A東京BMira")
            compose.onNodeWithTag("writing-enter").assertIsEnabled().performClick()
            compose.runOnIdle {
                assertEquals(listOf("A東京", "BMiraR"), texts(a)); assertTrue(a.exportDeferredChanges().isEmpty())
                val rich = a.snapshot.getJSONArray("blocks").toString(); assertTrue(rich.contains("mira")); assertTrue(rich.contains("bold")); assertTrue(rich.contains("opaque"))
            }
            val focused = compose.onNode(hasSetTextAction() and isFocused()); focused.assertTextContains("BMiraR")
            assertEquals(TextRange(0), focused.fetchSemanticsNode().config[SemanticsProperties.TextSelectionRange])
            compose.onNodeWithTag("writing-undo").assertIsEnabled().performClick()
            compose.runOnIdle { assertEquals(listOf("A東京BMiraR"), texts(a)) }
            compose.onNodeWithTag("writing-redo").assertIsEnabled().performClick()
            compose.runOnIdle { assertEquals(listOf("A東京", "BMiraR"), texts(a)) }
        } finally {
            compose.runOnIdle { visible.value = false }; compose.waitForIdle()
            compose.runOnIdle { a.close(); b.close() }
        }
    }

    @Test fun renderedUnicodeSelectionRebasesThenReplacesOnlySharedAtoms() {
        lateinit var a: WritingSession; lateinit var b: WritingSession
        val visible = mutableStateOf(true)
        val interceptor = PlatformTextInputInterceptor { request, _ ->
            val connection = request.createInputConnection(EditorInfo()); try { awaitCancellation() } finally { connection.closeConnection() }
        }
        compose.runOnUiThread {
            val blocks = JSONArray("""[{"id":"p","type":"paragraph","content":[{"type":"text","text":"A😀B","marks":[{"type":"bold"}]},{"type":"entity-ref","entityType":"person","entityId":"mira","label":"Mira"}]}]""")
            a = WritingSession.createV4("compose-shared-selection", "a", "v4", blocks)
            b = WritingSession.createV4("compose-shared-selection", "b", "v4", blocks)
        }
        try {
            compose.setContent { InterceptPlatformTextInput(interceptor) { MaterialTheme { run {
                val state = rememberWritingParagraphEditorState(a, ::retainedDrafts, reportError = { throw it })
                if (visible.value) WritingParagraphEditor(state, reportError = { throw it })
            } } } }
            val field = compose.onNode(hasSetTextAction()); field.performClick(); field.performTextInputSelection(TextRange(3, 1))
            val nativeSelection = field.fetchSemanticsNode().config[SemanticsProperties.TextSelectionRange]
            assertEquals(1, nativeSelection.min); assertEquals(3, nativeSelection.max)
            // Preserve whichever direction the actual Android control accepted.
            compose.runOnIdle { b.replaceText(b.textAddress(b.node(NodeAddress("p"))), 0, 0, "R"); a.receive(b.changes()) }
            assertEquals(TextRange(nativeSelection.start + 1, nativeSelection.end + 1), field.fetchSemanticsNode().config[SemanticsProperties.TextSelectionRange])
            field.performTextInput("東京")
            compose.runOnIdle {
                assertEquals(listOf("RA東京BMira"), texts(a))
                assertTrue(a.snapshot.getJSONArray("blocks").toString().contains("mira"))
                val restored = WritingSession.restore(a.save(), "a")
                try { restored.undo(); assertEquals(listOf("RA😀BMira"), texts(restored)) } finally { restored.close() }
            }
        } finally {
            compose.runOnIdle { visible.value = false }; compose.waitForIdle()
            compose.runOnIdle { a.close(); b.close() }
        }
    }

    @Test fun retainedRenderedSetTextCannotWriteAfterPermissionRevocation() {
        lateinit var a: WritingSession; val readonly = mutableStateOf(false)
        var renderedOwner: WritingParagraphEditorState? = null
        val visible = mutableStateOf(true)
        val interceptor = PlatformTextInputInterceptor { request, _ ->
            val connection = request.createInputConnection(EditorInfo()); try { awaitCancellation() } finally { connection.closeConnection() }
        }
        compose.runOnUiThread { a = WritingSession.createV4("compose-shared-readonly", "a", "v4", seed()) }
        try {
            compose.setContent { InterceptPlatformTextInput(interceptor) { MaterialTheme { run {
                val state = rememberWritingParagraphEditorState(a, ::retainedDrafts, reportError = { throw it })
                // Observe the requested permission during composition. A read
                // only inside SideEffect does not subscribe this composition to
                // changes of the host flag, leaving the real owner editable.
                val requestedReadOnly = readonly.value
                androidx.compose.runtime.SideEffect { state.readOnly = requestedReadOnly; renderedOwner = state }
                if (visible.value) WritingParagraphEditor(state, reportError = { throw it })
            } } } }
            val field = compose.onNode(hasSetTextAction()); field.performClick()
            val retained = checkNotNull(field.fetchSemanticsNode().config[SemanticsActions.SetText].action)
            val before = a.save().export().toString()
            compose.runOnIdle { readonly.value = true }
            compose.waitForIdle()
            compose.runOnIdle {
                assertTrue("The real input owner must be revoked before invoking the retained callback", checkNotNull(renderedOwner).readOnly)
                retained(AnnotatedString("retained overwrite")); assertEquals(before, a.save().export().toString())
            }
            compose.runOnIdle { readonly.value = false }
            field.performClick()
            compose.runOnIdle { assertFalse("The current owner must be editable for the fresh positive callback", checkNotNull(renderedOwner).readOnly) }
            field.performTextInputSelection(TextRange(0)); field.performTextInput("X")
            compose.runOnIdle { assertEquals(listOf("XABMira"), texts(a)) }
        } finally {
            compose.runOnIdle { visible.value = false }; compose.waitForIdle()
            compose.runOnIdle { a.close() }
        }
    }

    @Test fun nativeEmptyTailUndoRedoKeepsOriginalRetainedHeadSelection() {
        lateinit var a: WritingSession
        val visible = mutableStateOf(true)
        val interceptor = PlatformTextInputInterceptor { request, _ ->
            val connection = request.createInputConnection(EditorInfo()); try { awaitCancellation() } finally { connection.closeConnection() }
        }
        compose.runOnUiThread { a = WritingSession.createV4("compose-shared-empty-tail", "a", "v4", seed()) }
        try {
            compose.setContent { InterceptPlatformTextInput(interceptor) { MaterialTheme { run {
                val state = rememberWritingParagraphEditorState(a, ::retainedDrafts, reportError = { throw it })
                if (visible.value) WritingParagraphEditor(state, reportError = { throw it })
            } } } }
            val original = compose.onNode(hasSetTextAction()); original.performClick(); original.performTextInputSelection(TextRange(6))
            compose.onNodeWithTag("writing-enter").performClick()
            compose.onNode(hasSetTextAction() and isFocused()).assertTextContains("")
            compose.runOnIdle { assertEquals(listOf("ABMira", ""), texts(a)) }
            compose.onNodeWithTag("writing-undo").performClick()
            compose.onNode(hasSetTextAction() and isFocused()).assertTextContains("ABMira")
            assertEquals(TextRange(6), compose.onNode(hasSetTextAction() and isFocused()).fetchSemanticsNode().config[SemanticsProperties.TextSelectionRange])
            compose.onNodeWithTag("writing-redo").performClick()
            compose.runOnIdle { assertEquals(listOf("ABMira", ""), texts(a)) }
            assertEquals(TextRange(0), compose.onNode(hasSetTextAction() and isFocused()).fetchSemanticsNode().config[SemanticsProperties.TextSelectionRange])
        } finally {
            compose.runOnIdle { visible.value = false }; compose.waitForIdle()
            compose.runOnIdle { a.close() }
        }
    }
}
