package studio.seventwo.blockeditor

import android.view.inputmethod.EditorInfo
import android.view.inputmethod.InputConnection
import androidx.activity.ComponentActivity
import androidx.compose.material3.MaterialTheme
import androidx.compose.ui.ExperimentalComposeUiApi
import androidx.compose.ui.semantics.SemanticsProperties
import androidx.compose.ui.platform.InterceptPlatformTextInput
import androidx.compose.ui.platform.PlatformTextInputInterceptor
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.createAndroidComposeRule
import androidx.compose.ui.text.TextRange
import org.json.JSONArray
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test
import kotlinx.coroutines.awaitCancellation

@OptIn(ExperimentalTestApi::class)
class ComposeInputTest {
    @get:Rule val compose = createAndroidComposeRule<ComponentActivity>()

    @Test fun readOnlyNestedContentShowsRecoveredTextTablesAndChecklistChildren() {
        lateinit var session: EditorSession
        compose.runOnUiThread {
            val blocks = JSONArray("""[{"id":"t","type":"toggle","summary":[{"type":"text","text":"Recovered block","marks":[]}],"children":[
                {"id":"p","type":"paragraph","content":[{"type":"text","text":"Remote Bob","marks":[]}]},
                {"id":"l","type":"list","style":"todo","items":[{"id":"i","checked":true,"content":[{"type":"text","text":"Parent","marks":[]}],"children":[{"id":"j","content":[{"type":"text","text":"Child","marks":[]}],"children":[]}]}]},
                {"id":"table","type":"table","rows":[{"id":"r","cells":[{"id":"c","content":[{"type":"text","text":"Cell text","marks":[]}]}]}]}
            ]}]""")
            session = EditorSession.create("nested-preview", "reader", blocks, collaborationVersion = 2)
        }
        try {
            compose.setContent { MaterialTheme { BlockEditor(session, readOnly = true) } }
            compose.onNodeWithText("Recovered block").assertExists()
            compose.onNodeWithText("Remote Bob").assertExists()
            compose.onNodeWithText("Parent").assertExists()
            compose.onNodeWithText("Child").assertExists()
            compose.onNodeWithText("Cell text").assertExists()
            val checks = compose.onAllNodes(isToggleable())
            checks.assertCountEquals(2)
            checks[0].assertIsOn().assertIsNotEnabled()
            checks[1].assertIsOff().assertIsNotEnabled()
            compose.onNodeWithText("Paragraph").assertIsNotEnabled()
        } finally { compose.runOnUiThread { session.close() } }
    }

    @Test fun renderedFieldPreservesSelectionAndLocalTypingAcrossRemoteEdits() {
        lateinit var a: EditorSession
        lateinit var b: EditorSession
        compose.runOnUiThread {
            val blocks = JSONArray("""[{"id":"p","type":"paragraph","content":[{"type":"text","text":"Hello world","marks":[]}]}]""")
            a = EditorSession.create("compose-selection", "a", blocks)
            b = EditorSession.create("compose-selection", "b", blocks)
        }
        try {
            compose.setContent { MaterialTheme { BlockEditor(a) } }
            val field = compose.onNode(hasSetTextAction())
            field.performClick().performTextInputSelection(TextRange(11, 6))
            // The semantics selection action may normalize direction; preserve the actual UI range.
            val before = field.fetchSemanticsNode().config[SemanticsProperties.TextSelectionRange]
            assertEquals(6, before.min); assertEquals(11, before.max)
            compose.runOnIdle { b.setText("p", "RHello world"); a.receive(b.changes()) }
            assertEquals(TextRange(before.start + 1, before.end + 1), field.fetchSemanticsNode().config[SemanticsProperties.TextSelectionRange])
            field.performTextInput("there")
            compose.runOnIdle {
                assertEquals("RHello there", plainText(a.snapshot.getJSONArray("blocks").getJSONObject(0).getJSONArray("content")))
                a.undo()
            }
            field.assertTextContains("RHello world")
        } finally { compose.runOnIdle { a.close(); b.close() } }
    }

    @OptIn(ExperimentalComposeUiApi::class)
    @Test fun androidInputConnectionHoldsRemoteApplyUntilCompositionCommits() {
        lateinit var a: EditorSession
        lateinit var b: EditorSession
        var connection: InputConnection? = null
        // Own this rendered field's input session. Creating another connection
        // from the focused View races the system keyboard, which can commit our
        // injected composing range. This checks the real Compose InputConnection
        // boundary; installed keyboard/system-IME acceptance remains separate.
        val interceptor = PlatformTextInputInterceptor { request, _ ->
            val current = request.createInputConnection(EditorInfo())
            connection = current
            try { awaitCancellation() }
            finally { current.closeConnection(); if (connection === current) connection = null }
        }
        compose.runOnUiThread {
            val blocks = JSONArray("""[{"id":"c","type":"code","language":"swift","code":"Hello"}]""")
            a = EditorSession.create("compose-ime", "a", blocks)
            b = EditorSession.create("compose-ime", "b", blocks)
        }
        try {
            compose.setContent { InterceptPlatformTextInput(interceptor) { MaterialTheme { BlockEditor(a) } } }
            val field = compose.onNode(hasSetTextAction())
            field.performClick().performTextInputSelection(TextRange(0))
            compose.waitUntil(5_000) { connection != null }
            compose.runOnIdle {
                assertTrue(checkNotNull(connection).setComposingText("漢", 1))
            }
            compose.waitForIdle()
            compose.runOnIdle {
                b.setText("c", "RHello", listOf("code")); a.receive(b.changes())
                assertEquals(0, a.syncState().getJSONArray("received").length())
            }
            field.assertTextContains("漢Hello")
            compose.runOnIdle { assertTrue(checkNotNull(connection).finishComposingText()) }
            compose.waitForIdle()
            field.assertTextContains("R漢Hello")
            assertEquals(TextRange(2), field.fetchSemanticsNode().config[SemanticsProperties.TextSelectionRange])
            compose.runOnIdle { a.undo() }
            field.assertTextContains("RHello")
        } finally { compose.runOnIdle { a.close(); b.close() } }
    }
}
