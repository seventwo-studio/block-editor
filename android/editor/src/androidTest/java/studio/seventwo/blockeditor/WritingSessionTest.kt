package studio.seventwo.blockeditor

import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test

/** Typed Kotlin consumer proof, separate from the shared raw JNI transcript. */
class WritingSessionTest {
    private fun normalize(value: Any?): Any? = when (value) {
        is JSONObject -> value.keys().asSequence().associateWith { normalize(value.get(it)) }
        is JSONArray -> (0 until value.length()).map { normalize(value.get(it)) }
        JSONObject.NULL -> null
        else -> value
    }
    private fun blocks(session: WritingSession) = normalize(session.snapshot.getJSONArray("blocks"))
    private fun expected(text: String) = normalize(JSONArray("""[
        {"id":"left","type":"paragraph","content":[{"type":"text","text":"$text","marks":[]}]}
    ]"""))
    private fun error(message: String, operation: () -> Unit) {
        try { operation(); fail("Expected $message") }
        catch (failure: IllegalStateException) { assertEquals(message, failure.message) }
    }

    @Test fun typedV4RetainedPeerParagraphSupportsEnterAndReopenedUndo() {
        val seed = JSONArray("""[{"id":"p","type":"paragraph","content":[{"type":"text","text":"abcd","marks":[]}]}]""")
        val a = WritingSession.createV4("typed-roles", "a", "role-v4", seed)
        val b = WritingSession.createV4("typed-roles", "b", "role-v4", seed)
        var reopened: WritingSession? = null
        try {
            a.convertBlock(WritingAddress("p"), 0, WritingBlockTarget("list", style = "todo"))
            b.receive(a.changes())
            b.enterListItem(WritingAddress("p", listOf("items", "p-item", "content")), 2, 2, "peer")
            val peer = normalize(b.node(NodeAddress("p", listOf("items", "peer"))).wire)
            a.receive(b.changes()); a.undo(); b.receive(a.changes())
            assertEquals(peer, normalize(b.node(NodeAddress("peer")).wire))
            val caret = b.splitParagraph(WritingAddress("peer"), 1, 1, "tail")
            assertEquals(0, b.resolvePosition(caret).offset)
            assertEquals(peer, normalize(b.node(NodeAddress("peer")).wire))
            a.receive(b.changes()); assertEquals(blocks(a), blocks(b))
            val restored = WritingSession.restore(b.save(), "b"); reopened = restored
            assertEquals(blocks(b), blocks(restored))
            restored.undo()
            assertEquals(normalize(JSONArray("""[{"id":"p","type":"paragraph","content":[{"type":"text","text":"ab","marks":[]}]},{"id":"peer","type":"paragraph","content":[{"type":"text","text":"cd","marks":[]}],"checked":false}]""")), blocks(restored))
            restored.redo(); assertEquals(blocks(b), blocks(restored))
        } finally { reopened?.close(pendingStateRetained = true); a.close(pendingStateRetained = true); b.close(pendingStateRetained = true) }
    }

    @Test fun typedCollectionCreationReorderAndRemoteDescendantUndoUseStableIdentities() {
        val seed = JSONArray("""[{"id":"t","type":"table","rows":[],"columnWidths":[120],"extension":"keep"}]""")
        val a = WritingSession.createV4("typed-collections", "a", "collections-v4", seed)
        val b = WritingSession.createV4("typed-collections", "b", "collections-v4", seed)
        var reopened: WritingSession? = null
        try {
            val root = a.node(NodeAddress("t"))
            val rows = NodeCollection.rows(root)
            val values = JSONArray("""[
                {"id":"r1","cells":[{"id":"same","content":[{"type":"text","text":"one😀","marks":[]}]}]},
                {"id":"r2","cells":[{"id":"same","content":[{"type":"text","text":"two","marks":[]}]}]}
            ]""")
            val created = a.insertCollectionNodes(values, rows)
            assertEquals(2, created.nodes.size)
            assertEquals(created.nodes.map { normalize(it.wire) }, a.collectionNodes(rows).map { normalize(it.wire) })
            b.receive(a.changes())
            b.replaceText(WritingAddress("t", listOf("rows", "r1", "cells", "same", "content")), 0, 0, "R")
            a.receive(b.changes())
            a.moveSelection(WritingSelection(nodes = listOf(created.nodes[0])), rows, created.nodes[1])
            assertEquals(listOf("r2", "r1"), (0 until 2).map { a.snapshot.getJSONArray("blocks").getJSONObject(0).getJSONArray("rows").getJSONObject(it).getString("id") })
            val restored = WritingSession.restore(a.save(), "a"); reopened = restored
            restored.undo()
            assertEquals("Rone😀", restored.snapshot.getJSONArray("blocks").getJSONObject(0).getJSONArray("rows").getJSONObject(0).getJSONArray("cells").getJSONObject(0).getJSONArray("content").getJSONObject(0).getString("text"))
            restored.undo()
            assertEquals(listOf(normalize(created.nodes[0].wire)), restored.collectionNodes(rows).map { normalize(it.wire) })
            assertEquals("R", restored.snapshot.getJSONArray("blocks").getJSONObject(0).getJSONArray("rows").getJSONObject(0).getJSONArray("cells").getJSONObject(0).getJSONArray("content").getJSONObject(0).getString("text"))
            restored.redo()
            assertEquals(created.nodes.map { normalize(it.wire) }, restored.collectionNodes(rows).map { normalize(it.wire) })
            assertEquals("keep", restored.snapshot.getJSONArray("blocks").getJSONObject(0).getString("extension"))
            assertEquals(normalize(JSONArray("[120]")), normalize(restored.snapshot.getJSONArray("blocks").getJSONObject(0).getJSONArray("columnWidths")))
        } finally { reopened?.close(pendingStateRetained = true); a.close(pendingStateRetained = true); b.close(pendingStateRetained = true) }
    }

    @Test fun typedV4ConversionKeepsRootAndRetainsBothRemoteOriginsAcrossUndo() {
        val seed = JSONArray("""[{"id":"p","type":"paragraph","content":[{"type":"text","text":"café😀","marks":[]}],"extension":"keep"}]""")
        val a = WritingSession.createV4("typed-schema", "a", "schema-v4", seed)
        val b = WritingSession.createV4("typed-schema", "b", "schema-v4", seed)
        var reopened: WritingSession? = null
        try {
            val original = normalize(a.node(NodeAddress("p")).wire)
            val caret = a.convertBlock(WritingAddress("p"), 1, WritingBlockTarget("list", style = "todo"))
            assertEquals(original, normalize(a.node(NodeAddress("p")).wire))
            assertEquals(4, a.changes().export().getInt("version"))
            b.replaceText(WritingAddress("p"), 0, 0, "R")
            a.receive(b.changes()); b.receive(a.changes())
            assertEquals(blocks(a), blocks(b))
            val item = WritingAddress("p", listOf("items", "p-item", "content"))
            b.replaceText(item, 0, 0, "X")
            a.receive(b.changes())
            assertEquals(3, a.resolvePosition(caret).offset)
            val restored = WritingSession.restore(a.save(), "a"); reopened = restored
            restored.undo()
            assertEquals(original, normalize(restored.node(NodeAddress("p")).wire))
            assertEquals("paragraph", restored.snapshot.getJSONArray("blocks").getJSONObject(0).getString("type"))
            assertEquals(normalize(JSONArray("""[{"id":"p","type":"paragraph","content":[{"type":"text","text":"XRcafé😀","marks":[]}],"extension":"keep"}]""")), blocks(restored))
        } finally { reopened?.close(pendingStateRetained = true); a.close(pendingStateRetained = true); b.close(pendingStateRetained = true) }
    }

    @Test fun typedBlockConversionShortcutAndListContinuationKeepIdentityAndUndo() {
        val seed = JSONArray("""[{"id":"p","type":"paragraph","content":[{"type":"text","text":"## café","marks":[]}],"extension":"keep"}]""")
        val a = WritingSession.createV4("typed-commands", "a", "commands-v4", seed)
        var reopened: WritingSession? = null
        val list = WritingSession.createV4("typed-list-commands", "a", "commands-v4", JSONArray("""[
            {"id":"list","type":"list","style":"todo","items":[{"id":"i","content":[{"type":"text","text":"A😀","marks":[]}],"checked":true,"extension":"keep"}]}
        ]"""))
        try {
            val field = WritingAddress("p")
            val original = normalize(a.node(NodeAddress("p")).wire)
            a.setAllowedBlockTypes(setOf("paragraph"))
            val accepted = normalize(a.save().export())
            error("restrictedBlock(\"heading\")") { a.markdownShortcut(field, 3) }
            assertEquals(accepted, normalize(a.save().export()))
            a.setAllowedBlockTypes(null)
            val caret = a.markdownShortcut(field, 3)
            assertEquals(original, normalize(a.node(NodeAddress("p")).wire))
            assertEquals(0, a.resolvePosition(caret).offset)
            assertEquals(2, a.snapshot.getJSONArray("blocks").getJSONObject(0).getInt("level"))
            a.convertBlock(field, 1, WritingBlockTarget("quote"))
            assertEquals("quote", a.snapshot.getJSONArray("blocks").getJSONObject(0).getString("type"))
            val restored = WritingSession.restore(a.save(), "a"); reopened = restored
            restored.undo(); restored.undo()
            assertEquals(normalize(seed), blocks(restored))
            val position = list.enterListItem(WritingAddress("list", listOf("items", "i", "content")), 1, 1, "next")
            assertEquals(0, list.resolvePosition(position).offset)
            val items = list.snapshot.getJSONArray("blocks").getJSONObject(0).getJSONArray("items")
            assertEquals("i", items.getJSONObject(0).getString("id"))
            assertEquals("next", items.getJSONObject(1).getString("id"))
            assertFalse(items.getJSONObject(1).getBoolean("checked"))
            assertEquals("keep", items.getJSONObject(1).getString("extension"))
        } finally { reopened?.close(pendingStateRetained = true); a.close(pendingStateRetained = true); list.close(pendingStateRetained = true) }
    }

    @Test fun splitRemoteFormattingStablePositionAndReopenedAuthorUndo() {
        val seed = JSONArray("""[{"id":"left","type":"paragraph","content":[{"type":"text","text":"abcd","marks":[]}]}]""")
        val a = WritingSession.create("typed-kotlin", "a", "v3", seed)
        val b = WritingSession.create("typed-kotlin", "b", "v3", seed)
        var reopened: WritingSession? = null
        try {
            val field = WritingAddress("left")
            val position = a.splitParagraph(field, 2, 2, "right")
            b.replaceText(field, 3, 3, "X")
            b.format(field, 2, 3, "bold", JSONObject().put("type", "bold"))
            val left = a.changes(); val right = b.changes()
            a.receive(right); b.receive(left)
            assertEquals(blocks(a), blocks(b))
            assertEquals(normalize(JSONArray("""[
                {"id":"left","type":"paragraph","content":[{"type":"text","text":"ab","marks":[]}]},
                {"id":"right","type":"paragraph","content":[{"type":"text","text":"c","marks":[{"type":"bold"}]},{"type":"text","text":"Xd","marks":[]}]}
            ]""")), blocks(a))
            val resolved = a.resolvePosition(position)
            assertEquals(normalize(a.node(NodeAddress("right")).wire), normalize(resolved.address.export().getJSONObject("identity")))
            assertEquals(listOf("content"), resolved.address.path)
            assertEquals(0, resolved.offset)
            val restored = WritingSession.restore(a.save(), "a"); reopened = restored
            restored.undo()
            assertEquals(normalize(JSONArray("""[
                {"id":"left","type":"paragraph","content":[{"type":"text","text":"ab","marks":[]},{"type":"text","text":"c","marks":[{"type":"bold"}]},{"type":"text","text":"Xd","marks":[]}]}
            ]""")), blocks(restored))
        } finally { reopened?.close(pendingStateRetained = true); a.close(pendingStateRetained = true); b.close(pendingStateRetained = true) }
    }

    @Test fun compositionQueueReentrantReceiveAndProtocolFailureRemainRecoverable() {
        val seed = JSONArray("""[{"id":"left","type":"paragraph","content":[{"type":"text","text":"ab","marks":[]}]}]""")
        val c = WritingSession.create("typed-composition", "c", "v3", seed)
        val d = WritingSession.create("typed-composition", "d", "v3", seed)
        val e = WritingSession.create("typed-composition", "e", "v3", seed)
        try {
            val field = WritingAddress("left")
            d.replaceText(field, 1, 1, "X"); e.replaceText(field, 2, 2, "Z")
            val accepted = normalize(c.save().export())
            val release = c.deferRemoteChanges(); c.receive(d.changes())
            assertEquals(accepted, normalize(c.save().export()))
            assertEquals(0, c.syncState().export().getJSONArray("received").length())
            var nextRelease: (() -> Unit)? = null
            c.onChange = { if (nextRelease == null) { nextRelease = c.deferRemoteChanges(); c.receive(e.changes()) } }
            release()
            assertEquals(1, c.exportDeferredChanges().size)
            checkNotNull(nextRelease).invoke()
            assertEquals(expected("aXbZ"), blocks(c))
            c.setComposing(true)
            error("compositionActive") { c.splitParagraph(field, 1, 1, "blocked") }
            c.setComposing(false)
            val before = normalize(c.save().export())
            val wrong = WritingBatch.restore(d.changes().export().put("epoch", "wrong"))
            val badRelease = c.deferRemoteChanges(); c.receive(wrong)
            error("incompatibleEpoch") { badRelease() }
            assertEquals(before, normalize(c.save().export()))
            val retained = c.exportDeferredChanges()
            assertEquals(1, retained.size); assertEquals("wrong", retained.single().epoch)
            try { c.close(); fail("Pending packets require explicit host retention") } catch (_: IllegalStateException) { }
            c.close(pendingStateRetained = true)
        } finally { c.close(pendingStateRetained = true); d.close(pendingStateRetained = true); e.close(pendingStateRetained = true) }
    }

    @Test fun typedRecoveryRetainsRejectedDeltaAcrossReopenAndClearsAfterCompleteHistory() {
        val seed = JSONArray("""[{"id":"left","type":"paragraph","content":[{"type":"text","text":"ab","marks":[]}]}]""")
        val a = WritingSession.create("typed-gap", "a", "v3", seed)
        val b = WritingSession.create("typed-gap", "b", "v3", seed)
        var reopened: WritingSession? = null
        try {
            val field = WritingAddress("left")
            b.replaceText(field, 1, 1, "X"); val receipt = b.syncState()
            b.replaceText(field, 1, 1, "Y")
            val accepted = a.save(); val delta = b.changes(receipt)
            val recovery = try { a.receive(delta); throw AssertionError("Missing typed writing recovery") }
                catch (failure: WritingRecoveryException) { failure.recovery }
            assertEquals(MergeRecoveryReason.SCHEMA_CONSTRAINT, recovery.reason)
            assertEquals("v3", recovery.batch.epoch)
            assertEquals(3, recovery.batch.export().getInt("version"))
            assertEquals(normalize(accepted.export()), normalize(a.save().export()))
            assertEquals(normalize(recovery.export()), normalize(checkNotNull(a.mergeRecovery()).export()))
            val restored = WritingSession.restore(accepted, "a"); reopened = restored
            val exported = WritingRecovery.restore(recovery.export())
            try { restored.restoreRecovery(exported); fail("Incomplete history must stay rejected") }
            catch (failure: WritingRecoveryException) { assertEquals(normalize(exported.export()), normalize(failure.recovery.export())) }
            assertEquals(normalize(accepted.export()), normalize(restored.save().export()))
            assertEquals(normalize(exported.export()), normalize(checkNotNull(restored.mergeRecovery()).export()))
            restored.receive(b.changes())
            assertEquals(expected("aYXb"), blocks(restored))
            assertEquals(blocks(b), blocks(restored))
            assertNull(restored.mergeRecovery())
        } finally { reopened?.close(pendingStateRetained = true); a.close(pendingStateRetained = true); b.close(pendingStateRetained = true) }
    }

    @Test fun batchRangesCopyMoveDuplicateAndRemotePreservingUndo() {
        val seed = JSONArray("""[
            {"id":"first","type":"paragraph","content":[{"type":"text","text":"ABC","marks":[]}]},
            {"id":"middle","type":"paragraph","content":[{"type":"text","text":"kept","marks":[]}]},
            {"id":"last","type":"paragraph","content":[{"type":"text","text":"XYZ","marks":[]}]}
        ]""")
        val a = WritingSession.create("typed-batch", "a", "v3", seed)
        val b = WritingSession.create("typed-batch", "b", "v3", seed)
        var reopened: WritingSession? = null
        try {
            val firstField = WritingAddress("first"); val lastField = WritingAddress("last")
            val selected = a.selection(a.position(lastField, 2), a.position(firstField, 1))
            val copied = a.copySelection(selected).export()
            assertEquals("middle", copied.getJSONArray("nodes").getJSONObject(0).getString("id"))
            b.replaceText(firstField, 0, 0, "R-"); b.replaceText(lastField, 3, 3, "!")
            a.receive(b.changes())
            val carets = a.deleteSelection(selected)
            assertEquals(listOf(3, 0), carets.text.map { a.resolvePosition(it.start).offset })
            assertEquals(normalize(JSONArray("""[
                {"id":"first","type":"paragraph","content":[{"type":"text","text":"R-A","marks":[]}]},
                {"id":"last","type":"paragraph","content":[{"type":"text","text":"Z!","marks":[]}]}
            ]""")), blocks(a))
            val restored = WritingSession.restore(a.save(), "a"); reopened = restored
            restored.undo()
            assertFalse(restored.snapshot.getBoolean("canUndo")); assertTrue(restored.snapshot.getBoolean("canRedo"))
            val first = restored.node(NodeAddress("first")); val last = restored.node(NodeAddress("last"))
            val moved = restored.moveSelection(WritingSelection(nodes = listOf(first)), NodeCollection.ROOT, last)
            val duplicated = restored.duplicateSelection(moved, NodeCollection.ROOT, first)
            assertNotEquals(normalize(first.wire), normalize(duplicated.nodes.single().wire))
            val value = restored.copySelection(duplicated).export().getJSONArray("nodes").getJSONObject(0)
            assertEquals("R-ABC", value.getJSONArray("content").getJSONObject(0).getString("text"))
            val ids = restored.snapshot.getJSONArray("blocks").let { values -> (0 until values.length()).map { values.getJSONObject(it).getString("id") } }
            assertEquals(listOf("middle", "last", "first"), ids.take(3))
        } finally { reopened?.close(pendingStateRetained = true); a.close(pendingStateRetained = true); b.close(pendingStateRetained = true) }
    }
}
