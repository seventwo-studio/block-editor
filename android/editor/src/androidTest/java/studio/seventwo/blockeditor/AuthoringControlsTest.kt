package studio.seventwo.blockeditor

import androidx.activity.ComponentActivity
import androidx.compose.material3.MaterialTheme
import androidx.compose.runtime.mutableStateOf
import androidx.compose.ui.semantics.SemanticsProperties
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.createAndroidComposeRule
import androidx.compose.ui.text.TextRange
import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test

/** Rendered control regression checks. Semantics input does not accept system IME/TalkBack. */
@OptIn(ExperimentalTestApi::class)
class AuthoringControlsTest {
    @get:Rule val compose = createAndroidComposeRule<ComponentActivity>()

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
            compose.setContent { MaterialTheme { BlockEditor(host.value) } }
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
            compose.onNodeWithText("Redo").performTouchInput { click() }
            compose.onNodeWithText("Redo").performTouchInput { click() }
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
}
