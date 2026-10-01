package studio.seventwo.blockeditor.demo

import androidx.test.platform.app.InstrumentationRegistry
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withContext
import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test
import studio.seventwo.blockeditor.*
import java.io.File
import java.util.UUID

class RecoveryTest {
    private fun paragraph(text: String) = JSONObject().put("id", "same").put("type", "paragraph")
        .put("content", JSONArray().put(JSONObject().put("type", "text").put("text", text).put("marks", JSONArray())))
    private fun wrapper() = JSONObject().put("id", UUID.randomUUID().toString()).put("type", "toggle")
        .put("summary", JSONArray()).put("children", JSONArray())
    private fun directory() = File(InstrumentationRegistry.getInstrumentation().targetContext.cacheDir, "recovery-${UUID.randomUUID()}").also { it.mkdirs() }

    @Test fun pendingDraftAndArchivePreserveHistoryAndWriterIsolation() = runBlocking {
        withContext(Dispatchers.Main) {
            val directory = directory()
            val file = File(directory, "draft.json")
            val archive = File(directory, "archive.json")
            val a = EditorSession.create("storage-recovery", "alice", JSONArray(), collaborationVersion = 2)
            val b = EditorSession.create("storage-recovery", "bob", JSONArray(), collaborationVersion = 2)
            try {
                a.insertNode(paragraph("café 😀 Alice"), NodeCollection.ROOT)
                val second = b.insertNode(paragraph("世界 Bob"), NodeCollection.ROOT)
                val accepted = a.save().toString()
                val receipts = a.syncState().toString()
                try { a.receive(b.changes()); fail("Expected recovery") } catch (_: MergeRecoveryException) { }
                val proposal = checkNotNull(a.mergeRecovery()).export().toString()
                assertTrue(a.mergeRecovery()!!.originalBlocksForWrapping().any { it.label.contains("世界 Bob") })
                LocalDraft(file).use { draft ->
                    draft.save("local-room", "alice", a)
                    draft.exportRecovery("local-room", "alice", a, archive)
                    val bytes = archive.readText()
                    try { draft.exportRecovery("local-room", "alice", a, archive); fail("Archive overwritten") }
                    catch (_: IllegalStateException) { }
                    assertEquals(bytes, archive.readText())
                }
                LocalDraft(file).use { draft ->
                    val (actor, restored) = draft.restore(checkNotNull(draft.read("local-room")))
                    restored.use {
                        assertEquals("alice", actor)
                        assertEquals(accepted, restored.save().toString())
                        assertEquals(receipts, restored.syncState().toString())
                        assertEquals(proposal, restored.mergeRecovery()!!.export().toString())
                        try { restored.undo(); fail("Ordinary undo allowed") } catch (_: IllegalStateException) { }
                        try { restored.repairMerge(listOf(MergeRepair.Move(second, NodeCollection.ROOT))); fail("Invalid repair admitted") }
                        catch (error: IllegalStateException) { assertEquals("structuralConflict", error.message) }
                        assertEquals(accepted, restored.save().toString())
                        assertEquals(proposal, restored.mergeRecovery()!!.export().toString())
                        LocalDraft(archive).use { exported ->
                            val (fresh, recovered) = exported.restore(checkNotNull(exported.read("local-room")))
                            recovered.use {
                                assertNotEquals(actor, fresh)
                                assertEquals(proposal, recovered.mergeRecovery()!!.export().toString())
                                assertEquals(receipts, recovered.syncState().toString())
                            }
                        }
                        restored.repairMerge(listOf(MergeRepair.Wrap(second, wrapper(), "children")))
                        b.receive(restored.changes())
                        assertNull(restored.mergeRecovery())
                        assertEquals(restored.snapshot.getJSONArray("blocks").toString(), b.snapshot.getJSONArray("blocks").toString())
                        draft.save("local-room", actor, restored)
                    }
                    val (_, repaired) = draft.restore(checkNotNull(draft.read("local-room")))
                    repaired.use { assertNull(repaired.mergeRecovery()) }
                }
            } finally { a.close(); b.close(); directory.deleteRecursively() }
        }
    }

    @Test fun legacyUpgradeAndIncompatibleRecoveryDoNotResetTheFile() = runBlocking {
        withContext(Dispatchers.Main) {
            val directory = directory(); val file = File(directory, "draft.json")
            val original = EditorSession.create("legacy", "author", JSONArray().put(paragraph("Keep me")))
            try {
                LocalDraft(file).use { draft ->
                    file.writeText(JSONObject().put("version", 1).put("endpoint", "local-room")
                        .put("actor", "author").put("snapshot", original.save()).toString())
                    val (actor, restored) = draft.restore(checkNotNull(draft.read("local-room")))
                    restored.use {
                        assertEquals("author", actor)
                        assertEquals(original.snapshot.getJSONArray("blocks").toString(), restored.snapshot.getJSONArray("blocks").toString())
                        draft.save("local-room", actor, restored)
                    }
                    val upgraded = checkNotNull(draft.read("local-room"))
                    assertEquals(2, upgraded.getInt("version"))
                    val bad = JSONObject().put("reason", "identityConflict").put("batch",
                        JSONObject().put("version", 99).put("documentID", "legacy").put("baseline", JSONObject().put("blocks", JSONArray())).put("changes", JSONArray()))
                    for (invalid in listOf<Any>(bad, "malformed proposal")) {
                        file.writeText(JSONObject(upgraded.toString()).put("recovery", invalid).toString())
                        val bytes = file.readText()
                        try { draft.restore(checkNotNull(draft.read("local-room"))); fail("Incompatible recovery ignored") }
                        catch (_: Exception) { }
                        assertEquals(bytes, file.readText())
                    }
                }
            } finally { original.close(); directory.deleteRecursively() }
        }
    }

    @Test fun typedRelayRejectionSurvivesOfflineRestartAndExplicitRepair() = runBlocking {
        val args = InstrumentationRegistry.getArguments()
        val root = checkNotNull(args.getString("recoveryRelayUrl")) { "Pass recoveryRelayUrl for an empty v2 relay" }
        val token = checkNotNull(args.getString("relayToken"))
        val endpoint = "$root/rooms/android-recovery-${UUID.randomUUID()}"
        withContext(Dispatchers.Main) {
            val directory = directory(); val file = File(directory, "draft.json")
            val a = LocalRelayConnection.open(endpoint, token)
            var b: LocalRelayConnection? = null
            try {
                b = LocalRelayConnection.open(endpoint, token, file)
                a.session.insertNode(paragraph("Alice"), NodeCollection.ROOT)
                val second = b.session.insertNode(paragraph("Bob"), NodeCollection.ROOT)
                a.exchange()
                val accepted = b.session.save().toString(); val receipts = b.session.syncState().toString()
                try { b.exchange(); fail("Relay rejection ignored") } catch (_: MergeRecoveryException) { }
                assertNotNull(b.recovery)
                assertEquals(accepted, b.session.save().toString())
                assertEquals(receipts, b.session.syncState().toString())
                assertEquals("Saved locally", b.saveStatus)
                b.exportRecovery(File(directory, "export.json"))
                b.close(); b = null
                b = LocalRelayConnection.open(endpoint, "invalid-token", file)
                assertFalse(b.connected)
                assertNotNull(b.recovery)
                assertEquals(accepted, b.session.save().toString())
                b.session.repairMerge(listOf(MergeRepair.Wrap(second, wrapper(), "children")))
                assertNull(b.recovery)
                b.setToken(token); b.connected = true; b.exchange(); a.exchange()
                assertEquals(a.session.snapshot.getJSONArray("blocks").toString(), b.session.snapshot.getJSONArray("blocks").toString())
                assertEquals(0, b.pending)
                assertTrue(b.session.snapshot.toString().contains("Alice"))
                assertTrue(b.session.snapshot.toString().contains("Bob"))
            } finally { b?.close(); a.close(); directory.deleteRecursively() }
        }
    }
}
