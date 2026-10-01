package studio.seventwo.blockeditor.demo

import android.graphics.Bitmap
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.createAndroidComposeRule
import androidx.compose.ui.semantics.SemanticsProperties
import androidx.compose.ui.text.TextRange
import androidx.test.platform.app.InstrumentationRegistry
import androidx.core.content.FileProvider
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withContext
import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test
import studio.seventwo.blockeditor.MergeRecoveryException
import studio.seventwo.blockeditor.NodeCollection
import java.io.File
import java.util.UUID

@OptIn(ExperimentalTestApi::class)
class RecoveryUiTest {
    @get:Rule val compose = createAndroidComposeRule<MainActivity>()
    private fun paragraph(text: String) = JSONObject().put("id", "same").put("type", "paragraph")
        .put("content", JSONArray().put(JSONObject().put("type", "text").put("text", text).put("marks", JSONArray())))
    private fun waitFor(text: String, substring: Boolean = false) {
        compose.waitUntil(10_000) { compose.onAllNodesWithText(text, substring = substring).fetchSemanticsNodes().isNotEmpty() }
    }
    private fun screenshot(name: String) {
        val instrumentation = InstrumentationRegistry.getInstrumentation()
        val image = checkNotNull(instrumentation.uiAutomation.takeScreenshot())
        File(instrumentation.targetContext.cacheDir, name).outputStream().use { image.compress(Bitmap.CompressFormat.PNG, 100, it) }
        image.recycle()
    }

    @Test fun visibleRecoveryExportsReopensOfflineAndRepairsThroughControls() = runBlocking {
        val args = InstrumentationRegistry.getArguments()
        val endpoint = checkNotNull(args.getString("recoveryRelayUrl")) + "/rooms/android-ui-${UUID.randomUUID()}"
        val token = checkNotNull(args.getString("relayToken"))
        val a = withContext(Dispatchers.Main) { LocalRelayConnection.open(endpoint, token) }
        val b = withContext(Dispatchers.Main) { LocalRelayConnection.open(endpoint, token) }
        try {
            withContext(Dispatchers.Main) {
                a.session.insertNode(paragraph("Local Alice"), NodeCollection.ROOT)
                b.session.insertNode(paragraph("Remote Bob"), NodeCollection.ROOT)
                a.exchange()
            }
            compose.onNodeWithText("Server room URL").performTextReplacement(endpoint)
            compose.onNodeWithText("Local demo token").performTextInput(token)
            compose.onNodeWithText("Open editor").performClick()
            waitFor("Local Alice")
            withContext(Dispatchers.Main) {
                try { b.exchange(); fail("Expected recovery") } catch (_: MergeRecoveryException) { }
            }
            waitFor("Some edits need recovery")
            compose.onNodeWithText("Undo").assertIsNotEnabled()
            compose.onNodeWithText("Paragraph").assertIsNotEnabled()
            compose.onNodeWithText("Local Alice").assertExists()
            val accepted = compose.onNodeWithText("Local Alice")
            accepted.performTextInputSelection(TextRange(0, 5))
            assertEquals(TextRange(0, 5), accepted.fetchSemanticsNode().config[SemanticsProperties.TextSelectionRange])
            screenshot("android-recovery-pending.png")
            compose.onNodeWithText("Export recovery archive").performScrollTo().performClick()
            waitFor("Recovery archive saved locally")
            val context = InstrumentationRegistry.getInstrumentation().targetContext
            val archives = File(context.filesDir, "recovery-archives").listFiles()!!.filter { it.extension == "json" }
            val archive = archives.maxBy { it.lastModified() }
            assertTrue(JSONObject(archive.readText()).has("recovery"))
            assertNotNull(FileProvider.getUriForFile(context, "${context.packageName}.recovery", archive))

            // Recreate the real host and reopen its saved draft without a token.
            // This is Activity recreation, not the separate process-kill acceptance gate.
            compose.activityRule.scenario.recreate()
            compose.onNodeWithText("Open editor").performClick()
            waitFor("Some edits need recovery")
            compose.onNode(isToggleable()).assertIsOff()
            compose.onNodeWithText("Undo").assertIsNotEnabled()
            compose.onNodeWithText("Choose a recorded block").performClick()
            compose.onNodeWithText("Original paragraph: Remote Bob").performClick()
            compose.onNodeWithText("Place selected block in a new toggle").performScrollTo().performClick()
            compose.waitUntil(5_000) { compose.onAllNodesWithText("Some edits need recovery").fetchSemanticsNodes().isEmpty() }
            compose.onNodeWithText("Local Alice").assertExists()
            compose.onNodeWithText("Local demo token").performTextInput(token)
            compose.onNodeWithText("Remote Bob").assertExists()
            compose.onNode(isToggleable()).performClick()
            waitFor("0 unacknowledged changes", substring = true)
            withContext(Dispatchers.Main) {
                a.exchange(); b.exchange()
                assertNull(b.recovery)
                assertEquals(0, b.pending)
                assertEquals(a.session.snapshot.getJSONArray("blocks").toString(), b.session.snapshot.getJSONArray("blocks").toString())
                assertTrue(b.session.snapshot.toString().contains("Local Alice"))
                assertTrue(b.session.snapshot.toString().contains("Remote Bob"))
            }
            screenshot("android-recovery-repaired.png")
        } finally { withContext(Dispatchers.Main) { a.close(); b.close() } }
    }
}
