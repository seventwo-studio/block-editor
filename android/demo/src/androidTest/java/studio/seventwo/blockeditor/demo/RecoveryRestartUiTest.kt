package studio.seventwo.blockeditor.demo

import android.os.Process
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.createAndroidComposeRule
import androidx.test.platform.app.InstrumentationRegistry
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withContext
import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Assume.assumeTrue
import org.junit.Rule
import org.junit.Test
import studio.seventwo.blockeditor.MergeRecoveryException
import studio.seventwo.blockeditor.NodeCollection
import studio.seventwo.blockeditor.EditorSession
import java.io.File
import java.util.UUID

/** Three instrumentation processes, with force-stop and relay restart between phases. */
class RecoveryRestartUiTest {
    @get:Rule val compose = createAndroidComposeRule<MainActivity>()
    private fun waitFor(text: String, substring: Boolean = false) {
        compose.waitUntil(10_000) { compose.onAllNodesWithText(text, substring = substring).fetchSemanticsNodes().isNotEmpty() }
    }
    private fun paragraph(text: String) = JSONObject().put("id", "same").put("type", "paragraph")
        .put("content", JSONArray().put(JSONObject().put("type", "text").put("text", text).put("marks", JSONArray())))

    @Test fun processRestartPhase() = runBlocking {
        val args = InstrumentationRegistry.getArguments()
        val phase = args.getString("recoveryPhase")
        assumeTrue(phase != null)
        check(phase in listOf("prepare", "repair", "verify"))
        val run = checkNotNull(args.getString("recoveryRun"))
        val endpoint = checkNotNull(args.getString("recoveryRelayUrl")) + "/rooms/$run"
        val token = checkNotNull(args.getString("relayToken"))
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        val metadata = File(context.filesDir, "$run-proof.json")
        val draft = LocalDraft.file(File(context.filesDir, "local-drafts"), endpoint)
        val preferences = context.getSharedPreferences("local-demo", android.content.Context.MODE_PRIVATE)
        if (phase == "prepare") {
            val proof = JSONObject().put("pid", Process.myPid()).put("priorEndpoint", preferences.getString("endpoint", null))
            val a = withContext(Dispatchers.Main) { LocalRelayConnection.open(endpoint, token) }
            val b = withContext(Dispatchers.Main) { LocalRelayConnection.open(endpoint, token) }
            try {
                withContext(Dispatchers.Main) {
                    a.session.insertNode(paragraph("Restart Alice"), NodeCollection.ROOT)
                    b.session.insertNode(paragraph("Restart Bob"), NodeCollection.ROOT)
                    a.exchange()
                }
                compose.onNodeWithText("Server room URL").performTextReplacement(endpoint)
                compose.onNodeWithText("Local demo token").performTextInput(token)
                compose.onNodeWithText("Open editor").performClick()
                waitFor("Restart Alice")
                withContext(Dispatchers.Main) {
                    try { b.exchange(); fail("Expected recovery") } catch (_: MergeRecoveryException) { }
                }
                waitFor("Some edits need recovery")
                compose.onNodeWithText("Export recovery archive").performScrollTo().performClick()
                waitFor("Recovery archive saved locally")
                val saved = JSONObject(draft.readText())
                proof.put("actor", saved.getString("actor")).put("snapshot", saved.getJSONObject("snapshot"))
                    .put("recovery", saved.getJSONObject("recovery"))
                metadata.writeText(proof.toString())
            } finally { withContext(Dispatchers.Main) { a.close(); b.close() } }
            return@runBlocking
        }

        val proof = JSONObject(metadata.readText())
        assertNotEquals("Runner must terminate the previous Android process", proof.getInt("pid"), Process.myPid())
        compose.onNodeWithText("Server room URL").assertTextContains(endpoint)
        // No token, and the runner stops the relay entirely during the repair phase.
        compose.onNodeWithText("Open editor").performClick()
        waitFor("Restart Alice")
        compose.onNode(isToggleable()).assertIsOff()
        val saved = JSONObject(draft.readText())
        assertEquals(proof.getString("actor"), saved.getString("actor"))
        if (phase == "repair") {
            waitFor("Some edits need recovery")
            assertEquals(proof.getJSONObject("snapshot").toString(), saved.getJSONObject("snapshot").toString())
            assertEquals(proof.getJSONObject("recovery").toString(), saved.getJSONObject("recovery").toString())
            compose.onNodeWithText("Undo").assertIsNotEnabled()
            compose.onNodeWithText("Paragraph").assertIsNotEnabled()
            compose.onNodeWithText("Choose a recorded block").performClick()
            compose.onNodeWithText("Original paragraph: Restart Bob").performClick()
            compose.onNodeWithText("Place selected block in a new toggle").performScrollTo().performClick()
            compose.waitUntil(5_000) { compose.onAllNodesWithText("Some edits need recovery").fetchSemanticsNodes().isEmpty() }
            compose.onNodeWithText("Restart Bob").assertExists()
            val repaired = JSONObject(draft.readText())
            assertFalse(repaired.has("recovery"))
            assertEquals(proof.getString("actor"), repaired.getString("actor"))
            proof.put("repaired", repaired.getJSONObject("snapshot")).put("pid", Process.myPid())
            metadata.writeText(proof.toString())
            return@runBlocking
        }

        assertFalse(saved.has("recovery"))
        assertEquals(proof.getJSONObject("repaired").toString(), saved.getJSONObject("snapshot").toString())
        compose.onNodeWithText("Restart Bob").assertExists()
        compose.onNodeWithText("Local demo token").performTextInput(token)
        compose.onNode(isToggleable()).performClick()
        waitFor("0 unacknowledged changes", substring = true)
        withContext(Dispatchers.Main) {
            LocalRelayConnection.open(endpoint, token).use { peer ->
                assertTrue(peer.session.snapshot.toString().contains("Restart Alice"))
                assertTrue(peer.session.snapshot.toString().contains("Restart Bob"))
                assertEquals(run, peer.session.save().getString("documentID"))
                EditorSession.restore(JSONObject(draft.readText()).getJSONObject("snapshot"), UUID.randomUUID().toString()).use { local ->
                    assertEquals(local.snapshot.getJSONArray("blocks").toString(), peer.session.snapshot.getJSONArray("blocks").toString())
                }
            }
        }
        preferences.edit().apply {
            if (proof.has("priorEndpoint")) putString("endpoint", proof.getString("priorEndpoint")) else remove("endpoint")
        }.commit()
        metadata.delete()
    }
}
