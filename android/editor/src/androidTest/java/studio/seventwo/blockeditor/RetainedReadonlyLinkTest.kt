package studio.seventwo.blockeditor

import android.view.inputmethod.EditorInfo
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
import androidx.test.platform.app.InstrumentationRegistry
import java.io.File
import kotlinx.coroutines.awaitCancellation
import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Rule
import org.junit.Test

/** Separately covers the retained Apply path when host editing permission changes. */
@OptIn(ExperimentalTestApi::class, ExperimentalComposeUiApi::class)
class RetainedReadonlyLinkTest {
    @get:Rule val compose = createAndroidComposeRule<ComponentActivity>()

    @Test fun retainedApplyCannotEditAfterReadOnlyTransition() {
        lateinit var session: EditorSession
        val readOnly = mutableStateOf(false)
        compose.runOnUiThread {
            session = EditorSession.create("retained-readonly-link", "local", JSONArray("""[
                {"id":"p","type":"paragraph","content":[{"type":"text","text":"Original","marks":[]}]}
            ]"""), collaborationVersion = 2)
        }
        val interceptor = PlatformTextInputInterceptor { request, _ ->
            val connection = request.createInputConnection(EditorInfo())
            try { awaitCancellation() } finally { connection.closeConnection() }
        }
        try {
            compose.setContent { InterceptPlatformTextInput(interceptor) { MaterialTheme { BlockEditor(session, readOnly = readOnly.value) } } }
            compose.onNodeWithTag("editor-text:p:content").performClick().performTextInputSelection(TextRange(0, 5))
            compose.onNodeWithText("Link", substring = false).performTouchInput { click() }
            compose.onNode(hasSetTextAction() and hasText("Link URL")).performTextInput("https://example.test/read-only")
            val action = checkNotNull(compose.onNodeWithText("Apply link").fetchSemanticsNode().config[SemanticsActions.OnClick].action)
            lateinit var before: JSONObject
            compose.runOnIdle { before = JSONObject(session.save().toString()); readOnly.value = true }
            compose.onNodeWithText("Apply link").assertDoesNotExist()
            compose.runOnIdle {
                action()
                val after = JSONObject(session.save().toString())
                val proof = JSONObject().put("beforeHistory", before).put("afterHistory", after)
                    .put("runID", InstrumentationRegistry.getArguments().getString("retainedActionRun"))
                File(InstrumentationRegistry.getInstrumentation().targetContext.filesDir, "retained-action-readonly-link.json").writeText(proof.toString())
                assertEquals("Retained Apply must respect the current read-only host", before.toString(), after.toString())
            }
        } finally { compose.runOnIdle { session.close() } }
    }
}
