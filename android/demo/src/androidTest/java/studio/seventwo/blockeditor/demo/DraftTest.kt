package studio.seventwo.blockeditor.demo

import androidx.test.platform.app.InstrumentationRegistry
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withContext
import org.junit.Assert.*
import org.junit.Assume.assumeTrue
import org.junit.Test
import java.io.File
import java.util.UUID

class DraftTest {
    @Test fun invalidDraftsRemainUnchanged() {
        val file = File(InstrumentationRegistry.getInstrumentation().targetContext.cacheDir, "invalid-${UUID.randomUUID()}.json")
        try {
            LocalDraft(file).use { draft ->
                for (text in listOf("broken JSON", "{\"version\":99}", "{\"version\":1,\"endpoint\":\"another-room\"}")) {
                    file.writeText(text)
                    try { draft.read("expected-room"); fail("Invalid draft was accepted") }
                    catch (_: Exception) { }
                    assertEquals(text, file.readText())
                }
            }
        } finally { file.delete(); File(file.path + ".lock").delete() }
    }
    @Test fun restoreOfflineHistoryAndRejectConcurrentWriter() = runBlocking {
        val instrumentation = InstrumentationRegistry.getInstrumentation()
        val args = InstrumentationRegistry.getArguments()
        val endpoint = (args.getString("relayUrl") ?: "http://10.0.2.2:4319") + "/rooms/draft-${UUID.randomUUID()}"
        val token = args.getString("relayToken") ?: "relay-test"
        val file = File(instrumentation.targetContext.cacheDir, "draft-${UUID.randomUUID()}.json")
        withContext(Dispatchers.Main) {
            val remote = LocalRelayConnection.open(endpoint, token)
            var local: LocalRelayConnection? = null
            try {
                local = LocalRelayConnection.open(endpoint, token, file)
                try { LocalDraft(file).use { fail("A second writer acquired the draft") } }
                catch (_: IllegalStateException) { }
                local.connected = false
                local.session.setText("p", "Local survived 😀")
                assertEquals("Saved locally", local.saveStatus)
                local.close(); local = null
                remote.session.setText("p", "Remote survived 世界"); remote.exchange()
                // Invalid token proves restoring this draft does not fetch the relay.
                local = LocalRelayConnection.open(endpoint, "invalid-token", file)
                assertFalse(local.connected)
                assertTrue(local.session.snapshot.toString().contains("Local survived"))
                local.session.undo()
                assertFalse(local.session.snapshot.toString().contains("Local survived"))
                local.session.redo()
                local.setToken(token); local.connected = true; local.exchange(); remote.exchange()
                assertTrue(local.session.snapshot.toString().contains("Remote survived"))
                local.session.undo(); local.exchange(); remote.exchange()
                assertFalse(remote.session.snapshot.toString().contains("Local survived"))
                assertTrue(remote.session.snapshot.toString().contains("Remote survived"))
                assertEquals(0, local.pending)
            } finally { local?.close(); remote.close(); file.delete(); File(file.path + ".lock").delete() }
        }
    }

    /** Invoked twice by the acceptance command so the Android process really exits. */
    @Test fun processRestartPhase() = runBlocking {
        val args = InstrumentationRegistry.getArguments()
        val phase = args.getString("draftPhase")
        assumeTrue(phase != null)
        check(phase == "save" || phase == "restore")
        val run = checkNotNull(args.getString("draftRun"))
        val endpoint = checkNotNull(args.getString("relayUrl")) + "/rooms/$run"
        val token = checkNotNull(args.getString("relayToken"))
        val file = File(InstrumentationRegistry.getInstrumentation().targetContext.filesDir, "$run.json")
        withContext(Dispatchers.Main) {
            val client = LocalRelayConnection.open(endpoint, if (phase == "save") token else "", file)
            try {
                if (phase == "save") {
                    client.connected = false; client.session.setText("p", "Android process survived 😀")
                    assertEquals("Saved locally", client.saveStatus)
                } else {
                    assertFalse(client.connected)
                    assertTrue(client.session.snapshot.toString().contains("Android process survived"))
                    client.setToken(token); client.connected = true; client.exchange()
                    assertTrue(client.session.snapshot.toString().contains("remote process edit"))
                    client.session.undo(); client.exchange()
                    assertFalse(client.session.snapshot.toString().contains("Android process survived"))
                    assertTrue(client.session.snapshot.toString().contains("remote process edit"))
                    assertEquals(0, client.pending)
                }
            } finally { client.close(); if (phase != "save") { file.delete(); File(file.path + ".lock").delete() } }
        }
    }
}
