package studio.seventwo.blockeditor

import android.view.inputmethod.EditorInfo
import android.view.inputmethod.InputConnection
import androidx.activity.ComponentActivity
import androidx.compose.material3.MaterialTheme
import androidx.compose.ui.semantics.SemanticsProperties
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.createAndroidComposeRule
import androidx.compose.ui.text.TextRange
import org.json.JSONArray
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test

@OptIn(ExperimentalTestApi::class)
class ComposeInputTest {
    @get:Rule val compose = createAndroidComposeRule<ComponentActivity>()

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

    @Test fun androidInputConnectionCommitsCompositionBeforeRemoteApply() {
        lateinit var a: EditorSession
        lateinit var b: EditorSession
        lateinit var connection: InputConnection
        compose.runOnUiThread {
            val blocks = JSONArray("""[{"id":"c","type":"code","language":"swift","code":"Hello"}]""")
            a = EditorSession.create("compose-ime", "a", blocks)
            b = EditorSession.create("compose-ime", "b", blocks)
        }
        try {
            compose.setContent { MaterialTheme { BlockEditor(a) } }
            val field = compose.onNode(hasSetTextAction())
            field.performClick().performTextInputSelection(TextRange(0))
            compose.runOnIdle {
                connection = checkNotNull(compose.activity.window.decorView.findFocus().onCreateInputConnection(EditorInfo()))
                assertTrue(connection.setComposingText("漢", 1))
            }
            compose.waitForIdle()
            compose.runOnIdle {
                b.setText("c", "RHello", listOf("code")); a.receive(b.changes())
                assertEquals(0, a.syncState().getJSONArray("received").length())
            }
            field.assertTextContains("漢Hello")
            compose.runOnIdle { assertTrue(connection.finishComposingText()) }
            compose.waitForIdle()
            field.assertTextContains("R漢Hello")
            assertEquals(TextRange(2), field.fetchSemanticsNode().config[SemanticsProperties.TextSelectionRange])
            compose.runOnIdle { a.undo() }
            field.assertTextContains("RHello")
        } finally { compose.runOnIdle { a.close(); b.close() } }
    }
}
