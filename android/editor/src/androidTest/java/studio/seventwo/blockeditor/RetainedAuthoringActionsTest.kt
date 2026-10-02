package studio.seventwo.blockeditor

import androidx.activity.ComponentActivity
import androidx.compose.material3.MaterialTheme
import androidx.compose.runtime.mutableStateOf
import androidx.compose.ui.ExperimentalComposeUiApi
import androidx.compose.ui.platform.InterceptPlatformTextInput
import androidx.compose.ui.platform.PlatformTextInputInterceptor
import androidx.compose.ui.semantics.SemanticsActions
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.createAndroidComposeRule
import androidx.compose.ui.text.TextRange
import android.view.inputmethod.EditorInfo
import kotlinx.coroutines.awaitCancellation
import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test
import androidx.test.platform.app.InstrumentationRegistry
import java.io.File

/** Retained rendered callbacks must never target a replacement sharing an old path. */
@OptIn(ExperimentalTestApi::class, ExperimentalComposeUiApi::class)
class RetainedAuthoringActionsTest {
    @get:Rule val compose = createAndroidComposeRule<ComponentActivity>()
    @Test fun retainedBoldDoesNotFormatReplacementAfterReparent() = checkRetainedAction(false)
    @Test fun retainedLinkDoesNotFormatReplacementAfterReparent() = checkRetainedAction(true)

    @Test fun retainedBoldCannotEditAfterReadOnlyTransition() {
        lateinit var session: EditorSession
        val readOnly = mutableStateOf(false)
        compose.runOnUiThread {
            session = EditorSession.create("retained-readonly", "local", JSONArray("""[
                {"id":"p","type":"paragraph","content":[{"type":"text","text":"Original","marks":[]}]}
            ]"""), collaborationVersion = 2)
        }
        try {
            val interceptor = PlatformTextInputInterceptor { request, _ ->
                val connection = request.createInputConnection(EditorInfo())
                try { awaitCancellation() } finally { connection.closeConnection() }
            }
            compose.setContent { InterceptPlatformTextInput(interceptor) { MaterialTheme { BlockEditor(session, readOnly = readOnly.value) } } }
            compose.onNodeWithTag("editor-text:p:content").performClick().performTextInputSelection(TextRange(0, 5))
            val action = checkNotNull(compose.onNodeWithTag("editor-format:p:content:bold")
                .fetchSemanticsNode().config[SemanticsActions.OnClick].action)
            lateinit var before: JSONObject
            compose.runOnIdle { before = JSONObject(session.save().toString()); readOnly.value = true }
            compose.onNodeWithTag("editor-format:p:content:bold").assertDoesNotExist()
            compose.runOnIdle {
                action()
                val after = JSONObject(session.save().toString())
                writeProof("readonly", JSONObject().put("beforeHistory", before).put("afterHistory", after))
                assertEquals("Retained editable callback must respect the current read-only host", before.toString(), after.toString())
            }
        } finally { compose.runOnIdle { session.close() } }
    }

    private fun writeProof(name: String, proof: JSONObject) {
        val instrumentation = InstrumentationRegistry.getInstrumentation()
        proof.put("runID", InstrumentationRegistry.getArguments().getString("retainedActionRun"))
        File(instrumentation.targetContext.filesDir, "retained-action-$name.json").writeText(proof.toString())
    }

    private fun checkRetainedAction(link: Boolean) {
        lateinit var local: EditorSession
        lateinit var remote: EditorSession
        compose.runOnUiThread {
            val blocks = JSONArray("""[
                {"id":"a","type":"toggle","summary":[{"type":"text","text":"First","marks":[]}],"children":[
                    {"id":"p","type":"paragraph","content":[{"type":"text","text":"Hello","marks":[{"type":"italic"}]}]}]},
                {"id":"b","type":"toggle","summary":[{"type":"text","text":"Second","marks":[]}],"children":[]}
            ]""")
            local = EditorSession.create("retained-action-$link", "local", blocks, collaborationVersion = 2)
            remote = EditorSession.create("retained-action-$link", "remote", blocks, collaborationVersion = 2)
        }
        val interceptor = PlatformTextInputInterceptor { request, _ ->
            val connection = request.createInputConnection(EditorInfo())
            try { awaitCancellation() } finally { connection.closeConnection() }
        }
        try {
            compose.setContent { InterceptPlatformTextInput(interceptor) { MaterialTheme { BlockEditor(local) } } }
            compose.onNodeWithTag("editor-text:a:children/p/content").performScrollTo()
                .performClick().performTextInputSelection(TextRange(0, 5))
            val button = if (link) {
                compose.onNodeWithText("Link", substring = false).performTouchInput { click() }
                compose.onNode(hasSetTextAction() and hasText("Link URL")).performTextInput("https://example.test/original")
                compose.onNodeWithText("Apply link")
            } else compose.onNodeWithTag("editor-format:a:children/p/content:bold")
            val retainedClick = checkNotNull(button.fetchSemanticsNode().config[SemanticsActions.OnClick].action)
            lateinit var replacementBefore: JSONObject
            lateinit var originalBefore: JSONObject
            lateinit var historyBefore: JSONObject
            val phases = JSONArray()
            fun invokeAndRecord(phase: String) {
                retainedClick()
                val blocks = local.snapshot.getJSONArray("blocks")
                phases.put(JSONObject().put("phase", phase)
                    .put("replacement", JSONObject(blocks.getJSONObject(0).getJSONArray("children").getJSONObject(0).toString()))
                    .put("original", JSONObject(blocks.getJSONObject(1).getJSONArray("children").getJSONObject(0).toString()))
                    .put("history", JSONObject(local.save().toString())))
                writeProof(if (link) "link" else "bold", JSONObject().put("replacementBefore", replacementBefore)
                    .put("originalBefore", originalBefore).put("historyBefore", historyBefore).put("phases", phases))
            }
            compose.runOnIdle {
                val origin = remote.node(NodeAddress("a", listOf("children", "p")))
                remote.moveNode(origin, NodeCollection.children(remote.node(NodeAddress("b"))))
                remote.insertNode(JSONObject("""{"id":"p","type":"paragraph","content":[{"type":"text","text":"Other","marks":[]}]}"""),
                    NodeCollection.children(remote.node(NodeAddress("a"))))
                local.receive(remote.changes())
                assertEquals(NodeAddress("b", listOf("children", "p")).wire().toString(), local.nodeAddress(origin).wire().toString())
                val blocks = local.snapshot.getJSONArray("blocks")
                replacementBefore = JSONObject(blocks.getJSONObject(0).getJSONArray("children").getJSONObject(0).toString())
                originalBefore = JSONObject(blocks.getJSONObject(1).getJSONArray("children").getJSONObject(0).toString())
                historyBefore = JSONObject(local.save().toString())
                invokeAndRecord("before-compose-detach")
            }
            compose.waitForIdle() // Old view disposed, new destination binding attached.
            compose.runOnIdle {
                invokeAndRecord("after-compose-detach")
                for (index in 0 until phases.length()) {
                    val phase = phases.getJSONObject(index)
                    assertEquals("Retained action must not edit replacement at the old address", replacementBefore.toString(), phase.getJSONObject("replacement").toString())
                    assertEquals("Retained action must leave the moved original unchanged", originalBefore.toString(), phase.getJSONObject("original").toString())
                    assertEquals("Rejected action must preserve history", historyBefore.toString(), phase.getJSONObject("history").toString())
                }
            }
        } finally { compose.runOnIdle { local.close(); remote.close() } }
    }
}
