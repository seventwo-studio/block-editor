package studio.seventwo.blockeditor

import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test

/** Typed Kotlin consumer proof, separate from the shared raw JNI transcript. */
class WritingSessionTest {
    @Test fun typedWritingMathThresholdRetainsBothAtomsAndSeparateRecoveryAcrossRestart() {
        val rich = JSONObject("""{"id":"rich","type":"paragraph","host":"retained","content":[{"type":"text","text":"café 東京😀","marks":[{"type":"bold"}]},{"type":"entity-ref","entityType":"task","entityId":"outside","label":"Task","consumer":{"id":"reference-opaque"}}]}""")
        for (version in listOf(4, 5)) for (actor in listOf("a", "z")) for (length in listOf(9_998, 9_999)) {
            val math = JSONObject().put("id", "math").put("type", "math").put("expression", "x".repeat(length))
                .put("consumer", JSONObject("""{"id":"math-opaque","children":[{"id":"opaque-child"}]}"""))
            val seed = JSONArray().put(math).put(rich)
            fun create(writer: String) = if (version == 4) WritingSession.createV4("typed-threshold-$version", writer, "threshold-$version", seed)
                else WritingSession.createV5("typed-threshold-$version", writer, "threshold-$version", seed)
            fun expected(count: Int, suffix: String) = normalize(JSONArray().put(JSONObject(math.toString()).put("expression", "x".repeat(count) + suffix)).put(rich))
            fun pending(operation: () -> Unit): WritingRecovery {
                try { operation() } catch (failure: WritingRecoveryException) { return failure.recovery }
                throw AssertionError("Over-limit union must retain a proposal")
            }
            val a = create(actor); val b = create("m")
            var resumedA: WritingSession? = null; var resumedB: WritingSession? = null; var reopened: WritingSession? = null
            try {
                val address = WritingAddress("math", listOf("expression"))
                val positionA = a.replaceText(address, length, length, "A")
                val positionB = b.replaceText(address, length, length, "B")
                assertEquals(expected(length, "A"), blocks(a)); assertEquals(expected(length, "B"), blocks(b))
                val own = a.changes(); val remote = b.changes(); val suffix = if (actor == "z") "AB" else "BA"
                if (length == 9_998) {
                    a.receive(remote); b.receive(own); a.receive(remote); b.receive(own)
                    assertEquals(expected(9_998, suffix), blocks(a)); assertEquals(blocks(a), blocks(b))
                    assertNull(a.mergeRecovery()); assertNull(b.mergeRecovery())
                    assertEquals(if (actor == "z") 9_999 else 10_000, a.resolvePosition(positionA).offset)
                    assertEquals(if (actor == "z") 10_000 else 9_999, a.resolvePosition(positionB).offset)
                    val restored = WritingSession.restore(a.save(), actor); reopened = restored
                    restored.undo(); b.receive(restored.changes())
                    assertEquals(expected(9_998, "B"), blocks(restored)); assertEquals(blocks(restored), blocks(b))
                    restored.redo(); b.receive(restored.changes()); b.receive(restored.changes())
                    assertEquals(expected(9_998, suffix), blocks(restored)); assertEquals(blocks(restored), blocks(b))
                    continue
                }
                val acceptedA = a.save(); val acceptedB = b.save()
                val savedA = normalize(acceptedA.export()); val savedB = normalize(acceptedB.export())
                val receiptA = normalize(a.syncState().export()); val receiptB = normalize(b.syncState().export())
                val proposalA = pending { a.receive(remote) }; val proposalB = pending { b.receive(own) }
                assertEquals(MergeRecoveryReason.SCHEMA_CONSTRAINT, proposalA.reason)
                assertEquals(normalize(proposalA.export()), normalize(proposalB.export()))
                repeat(2) { assertEquals(normalize(proposalA.export()), normalize(pending { a.receive(remote) }.export())) }
                assertEquals(savedA, normalize(a.save().export())); assertEquals(savedB, normalize(b.save().export()))
                assertEquals(receiptA, normalize(a.syncState().export())); assertEquals(receiptB, normalize(b.syncState().export()))
                pending { a.undo() }; pending { a.replaceText(address, 0, 0, "blocked") }
                val restoredA = WritingSession.restore(acceptedA, actor); resumedA = restoredA
                val restoredB = WritingSession.restore(acceptedB, "m"); resumedB = restoredB
                pending { restoredA.restoreRecovery(WritingRecovery.restore(proposalA.export())) }
                pending { restoredB.restoreRecovery(WritingRecovery.restore(proposalB.export())) }
                assertEquals(savedA, normalize(restoredA.save().export())); assertEquals(savedB, normalize(restoredB.save().export()))
                assertEquals(receiptA, normalize(restoredA.syncState().export())); assertEquals(receiptB, normalize(restoredB.syncState().export()))
                val origin = restoredA.node(NodeAddress("math"))
                error("invalidChange") { restoredA.repairText(origin, "expression", "x".repeat(9_999) + suffix) }
                assertEquals(savedA, normalize(restoredA.save().export()))
                assertEquals(normalize(proposalA.export()), normalize(restoredA.mergeRecovery()!!.export()))
                restoredA.repairText(origin, "expression", "x".repeat(9_998) + suffix)
                assertEquals(expected(9_998, suffix), blocks(restoredA)); assertNull(restoredA.mergeRecovery())
                assertEquals(if (actor == "z") 9_999 else 10_000, restoredA.resolvePosition(positionA).offset)
                assertEquals(if (actor == "z") 10_000 else 9_999, restoredA.resolvePosition(positionB).offset)
                val forward = restoredA.changes().export(); val changes = forward.getJSONArray("changes")
                val reverse = JSONObject(forward.toString()).put("changes", JSONArray((0 until changes.length()).reversed().map { changes.getJSONObject(it) }))
                restoredB.receive(WritingBatch.restore(reverse)); restoredB.receive(restoredA.changes()); restoredB.receive(WritingBatch.restore(reverse))
                assertEquals(blocks(restoredA), blocks(restoredB)); assertNull(restoredB.mergeRecovery())
                val stopped = WritingSession.restore(restoredA.save(), actor); reopened = stopped
                val beforeUndo = normalize(stopped.save().export()); val beforeReceipt = normalize(stopped.syncState().export())
                val pendingUndo = pending { stopped.undo() }
                assertEquals(beforeUndo, normalize(stopped.save().export())); assertEquals(beforeReceipt, normalize(stopped.syncState().export()))
                assertEquals(4, pendingUndo.batch.export().getJSONArray("changes").length())
                stopped.repairRedo(2, actor); restoredB.receive(stopped.changes()); restoredB.receive(stopped.changes())
                assertEquals(expected(9_998, suffix), blocks(stopped)); assertEquals(blocks(stopped), blocks(restoredB))
                assertEquals(5, stopped.changes().export().getJSONArray("changes").length())
            } finally { a.close(); b.close(); resumedA?.close(); resumedB?.close(); reopened?.close() }
        }
    }

    @Test fun typedV5WholeBlockPasteKeepsConcurrentCutGroupsAndOneAuthorUndo() {
        val seed = JSONArray("""[{"id":"p","type":"paragraph","host":"boundary","content":[{"type":"text","text":"abcd","marks":[]}]}]""")
        val clipboard = WritingClipboard.restore(JSONObject("""{"version":1,"parts":[{"node":{"value":{"id":"input","type":"paragraph","content":[{"type":"text","text":"東京😀","marks":[{"type":"bold"}]},{"type":"entity-ref","entityType":"task","entityId":"consumer-task","label":"Task","consumer":{"id":"reference-opaque"}}],"consumer":{"id":"opaque-owner","children":[{"id":"opaque-child"}]}},"kind":"block"}}]}"""))
        for (actor in listOf("a", "z")) for (cut in listOf(1, 2)) {
            val documentID = "typed-splice-$actor-$cut"
            val a = WritingSession.createV5(documentID, actor, "five", seed)
            val b = WritingSession.createV5(documentID, "m", "five", seed)
            var reopened: WritingSession? = null
            try {
                val address = WritingAddress("p")
                val range = a.selectedText(address, cut, cut)
                val held = normalize(a.save().export())
                val release = a.deferRemoteChanges()
                try { a.pasteBlocks(clipboard, range); fail("Held input must block paste") }
                catch (_: IllegalStateException) { }
                assertEquals(held, normalize(a.save().export()))
                release()
                a.setComposing(true)
                error("compositionActive") { a.pasteBlocks(clipboard, range) }
                a.setComposing(false)
                assertEquals(held, normalize(a.save().export()))

                val caret = a.pasteBlocks(clipboard, range)
                assertEquals(1, a.changes().export().getJSONArray("changes").length())
                val importedID = "paste-$actor-1-1"
                val tailID = "paste-$actor-1-2"
                val imported = JSONObject(clipboard.export().getJSONArray("parts").getJSONObject(0)
                    .getJSONObject("node").getJSONObject("value").toString()).put("id", importedID)
                fun paragraph(id: String, text: String, host: Boolean = false) = JSONObject()
                    .put("id", id).put("type", "paragraph")
                    .put("content", JSONArray().put(JSONObject().put("type", "text").put("text", text).put("marks", JSONArray())))
                    .also { if (host) it.put("host", "boundary") }
                val expected = if (cut == 1) JSONArray().put(paragraph("p", "a", true)).put(imported)
                    .put(paragraph(tailID, "b", true)).put(paragraph("peer-tail", "cd"))
                    else JSONArray().put(paragraph("p", "a", true)).put(paragraph("peer-tail", "b"))
                        .put(imported).put(paragraph(tailID, "cd", true))
                b.splitParagraph(address, if (cut == 1) 2 else 1, if (cut == 1) 2 else 1, "peer-tail")
                val own = a.changes()
                val remote = b.changes()
                a.receive(remote)
                b.receive(own)
                a.receive(remote)
                b.receive(own)
                assertEquals(normalize(expected), blocks(a))
                assertEquals(blocks(a), blocks(b))
                assertEquals(0, a.resolvePosition(caret).offset)
                assertEquals(normalize(a.node(NodeAddress(tailID)).wire),
                    normalize(a.resolvePosition(caret).address.export().getJSONObject("identity")))
                val restored = WritingSession.restore(a.save(), actor)
                reopened = restored
                restored.undo()
                b.receive(restored.changes())
                val undo = if (cut == 1) JSONArray().put(paragraph("p", "ab", true)).put(paragraph("peer-tail", "cd"))
                    else JSONArray().put(paragraph("p", "a", true)).put(paragraph("peer-tail", "bcd"))
                assertEquals(normalize(undo), blocks(restored))
                assertEquals(blocks(restored), blocks(b))
                assertFalse(restored.snapshot.getBoolean("canUndo"))
                assertTrue(restored.snapshot.getBoolean("canRedo"))
                restored.redo()
                b.receive(restored.changes())
                b.receive(restored.changes())
                assertEquals(normalize(expected), blocks(restored))
                assertEquals(blocks(restored), blocks(b))
            } finally { a.close(); b.close(); reopened?.close() }
        }

        val zero = WritingSession.createV5("typed-splice-zero", "a", "five", seed)
        val four = WritingSession.createV4("typed-splice-zero", "old", "five", seed)
        try {
            val address = WritingAddress("p")
            val caret = zero.pasteBlocks(clipboard, zero.selectedText(address, 0, 2))
            val accepted = normalize(zero.save().export())
            val acceptedBlocks = blocks(zero)
            val suffix = zero.snapshot.getJSONArray("blocks").getJSONObject(1)
            assertEquals(2, zero.snapshot.getJSONArray("blocks").length())
            assertEquals("p", suffix.getString("id"))
            assertEquals("boundary", suffix.getString("host"))
            assertEquals("cd", suffix.getJSONArray("content").getJSONObject(0).getString("text"))
            assertEquals(normalize(zero.node(NodeAddress("p")).wire),
                normalize(zero.resolvePosition(caret).address.export().getJSONObject("identity")))
            assertEquals(1, zero.changes().export().getJSONArray("changes").length())
            val oldAccepted = normalize(four.save().export())
            error("unsupportedVersion(4)") { four.pasteBlocks(clipboard, four.selectedText(address, 0, 0)) }
            error("unsupportedVersion(4)") { zero.receive(four.changes()) }
            error("unsupportedVersion(5)") { four.receive(zero.changes()) }
            assertEquals(accepted, normalize(zero.save().export()))
            assertEquals(oldAccepted, normalize(four.save().export()))
            assertNull(zero.mergeRecovery())
            assertNull(four.mergeRecovery())
            val inline = zero.clipboardText("inline")
            error("invalidPath") { zero.pasteBlocks(inline, zero.selectedText(address, 0, 0)) }
            val across = zero.selection(zero.position(WritingAddress("paste-a-1-1"), 0), zero.position(address, 1))
            val crossBlockRange = WritingTextRange(JSONObject().put("start", across.text.first().start.export())
                .put("end", across.text.last().end.export()))
            error("invalidPath") { zero.pasteBlocks(clipboard, crossBlockRange) }
            assertEquals(accepted, normalize(zero.save().export()))
            zero.undo()
            assertEquals(normalize(seed), blocks(zero))
            zero.redo()
            assertEquals(acceptedBlocks, blocks(zero))
        } finally { zero.close(); four.close() }
    }

    @Test fun typedV5EpochRejectsMixedVersionsAndInheritsUnicodeUndoAndRecovery() {
        val seed = JSONArray("""[{"id":"p","type":"paragraph","host":"keep","content":[{"type":"text","text":"C","marks":[]}]}]""")
        val a = WritingSession.createV5("typed-five", "a", "explicit-five", seed)
        val b = WritingSession.createV5("typed-five", "b", "explicit-five", seed)
        val four = WritingSession.createV4("typed-five", "four", "explicit-five", seed)
        var reopened: WritingSession? = null
        try {
            val address = WritingAddress("p")
            a.replaceText(address, 0, 0, "東京"); val caret = a.replaceText(address, 2, 2, "X")
            assertEquals(3, a.resolvePosition(caret).offset)
            b.replaceText(address, 1, 1, "R"); a.receive(b.changes()); a.receive(b.changes()); b.receive(a.changes())
            val expected = normalize(JSONArray("""[{"id":"p","type":"paragraph","host":"keep","content":[{"type":"text","text":"東京XCR","marks":[]}]}]"""))
            assertEquals(expected, blocks(a)); assertEquals(expected, blocks(b))
            assertEquals(5, a.changes().export().getInt("version")); assertEquals(5, a.syncState().export().getInt("version"))
            val saved = a.save(); val accepted = normalize(saved.export()); val fourAccepted = normalize(four.save().export())
            error("unsupportedVersion(4)") { a.receive(four.changes()) }
            error("unsupportedVersion(5)") { four.receive(a.changes()) }
            assertEquals(accepted, normalize(a.save().export())); assertEquals(fourAccepted, normalize(four.save().export()))
            assertNull(a.mergeRecovery()); assertNull(four.mergeRecovery())
            try { WritingBatch.restore(saved.export().put("version", 6)); fail("Unknown version must be rejected") }
            catch (_: IllegalArgumentException) { }
            val restored = WritingSession.restore(saved, "a"); reopened = restored
            restored.undo(); assertEquals("東京CR", restored.snapshot.getJSONArray("blocks").getJSONObject(0).getJSONArray("content").getJSONObject(0).getString("text"))
            restored.redo(); assertEquals(expected, blocks(restored)); assertEquals(5, restored.save().export().getInt("version"))
        } finally { a.close(); b.close(); four.close(); reopened?.close() }

        val recoveryA = WritingSession.createV5("typed-five-recovery", "a", "five-recovery")
        val recoveryB = WritingSession.createV5("typed-five-recovery", "peer", "five-recovery")
        var resumed: WritingSession? = null
        fun recover(operation: () -> Unit): WritingRecovery {
            try { operation() } catch (failure: WritingRecoveryException) { return failure.recovery }
            throw AssertionError("Expected typed v5 recovery")
        }
        try {
            val math = recoveryA.insertCollectionNodes(JSONArray("""[{"id":"math","type":"math","expression":"x+y","extension":{"remote":false}}]"""), NodeCollection.ROOT).nodes.single()
            val birth = recoveryA.changes(); recoveryB.receive(birth)
            val mutation = JSONObject().put("setNodeField", JSONObject().put("identity", math.wire).put("path", JSONArray(listOf("extension", "remote"))).put("value", true))
            val body = JSONObject().put("edit", JSONObject().put("_0", JSONArray().put(JSONObject().put("structure", JSONObject().put("_0", mutation)))))
            val change = JSONObject().put("id", JSONObject().put("counter", 2).put("actor", "peer"))
                .put("observed", JSONArray().put(JSONObject().put("counter", 1).put("actor", "a"))).put("body", body)
            recoveryB.receive(WritingBatch.restore(birth.export().put("changes", JSONArray().put(change)))); recoveryA.receive(recoveryB.changes())
            val accepted = recoveryA.save(); val acceptedValue = normalize(accepted.export()); val receipts = normalize(recoveryA.syncState().export())
            val pending = recover { recoveryA.undo() }; assertEquals(MergeRecoveryReason.SCHEMA_CONSTRAINT, pending.reason)
            assertEquals(5, pending.batch.export().getInt("version")); assertEquals(3, pending.batch.export().getJSONArray("changes").length())
            assertEquals(acceptedValue, normalize(recoveryA.save().export())); assertEquals(receipts, normalize(recoveryA.syncState().export()))
            val restored = WritingSession.restore(accepted, "a"); resumed = restored
            recover { restored.restoreRecovery(WritingRecovery.restore(pending.export())) }
            error("invalidChange") { restored.repairText(math, "expression", "") }
            assertEquals(acceptedValue, normalize(restored.save().export())); assertEquals(normalize(pending.export()), normalize(restored.mergeRecovery()!!.export()))
            restored.repairText(math, "expression", "restored 😀"); assertNull(restored.mergeRecovery())
            val expected = normalize(JSONArray("""[{"id":"math","type":"math","expression":"restored 😀","extension":{"remote":true}}]"""))
            assertEquals(expected, blocks(restored)); assertEquals(4, restored.changes().export().getJSONArray("changes").length())
            recoveryB.receive(restored.changes()); assertEquals(expected, blocks(recoveryB))
        } finally { recoveryA.close(); recoveryB.close(); resumed?.close() }
    }

    @Test fun typedV4ClipboardPreservesUnicodeReferencesAndPeerUndoInOneAction() {
        for (actor in listOf("a", "z")) {
            val seed = JSONArray("""[{"id":"p","type":"paragraph","host":"retained","content":[{"type":"text","text":"ABC","marks":[]}]}]""")
            val a = WritingSession.createV4("typed-clipboard-$actor", actor, "clipboard-v4", seed)
            val b = WritingSession.createV4("typed-clipboard-$actor", "m", "clipboard-v4", seed)
            var reopened: WritingSession? = null
            try {
                val address = WritingAddress("p"); val range = a.selectedText(address, 1, 2)
                val clipboard = WritingClipboard.restore(JSONObject("""{"version":1,"parts":[{"inline":{"_0":[{"type":"text","text":"東京😀","marks":[{"type":"bold"}]},{"type":"entity-ref","entityType":"task","entityId":"external-id","label":"Task","consumer":{"id":"opaque"}}]}}]}"""))
                b.replaceText(address, 3, 3, " peer"); a.receive(b.changes())
                val release = a.deferRemoteChanges(); val held = normalize(a.save().export())
                try { a.pasteInline(clipboard, range); fail("Held remote input must block paste") }
                catch (_: IllegalStateException) { }
                assertEquals(held, normalize(a.save().export())); release()
                val count = a.changes().export().getJSONArray("changes").length()
                val caret = a.pasteInline(clipboard, range)
                assertEquals(9, a.resolvePosition(caret).offset)
                assertEquals(count + 1, a.changes().export().getJSONArray("changes").length())
                val expected = normalize(JSONArray("""[{"id":"p","type":"paragraph","host":"retained","content":[{"type":"text","text":"A","marks":[]},{"type":"text","text":"東京😀","marks":[{"type":"bold"}]},{"type":"entity-ref","entityType":"task","entityId":"external-id","label":"Task","consumer":{"id":"opaque"}},{"type":"text","text":"C peer","marks":[]}]}]"""))
                assertEquals(expected, blocks(a)); b.receive(a.changes()); b.receive(a.changes()); assertEquals(expected, blocks(b))
                val copied = a.copyClipboard(WritingSelection(text = listOf(a.selectedText(address, 1, 9)))).export()
                val copiedValues = copied.getJSONArray("parts").getJSONObject(0).getJSONObject("inline").getJSONArray("_0")
                val reference = copiedValues.getJSONObject(copiedValues.length() - 1)
                assertEquals("external-id", reference.getString("entityId")); assertEquals("opaque", reference.getJSONObject("consumer").getString("id"))
                val restored = WritingSession.restore(a.save(), actor); reopened = restored
                restored.undo(); assertFalse(restored.snapshot.getBoolean("canUndo"))
                assertEquals(normalize(JSONArray("""[{"id":"p","type":"paragraph","host":"retained","content":[{"type":"text","text":"ABC peer","marks":[]}]}]""")), blocks(restored))
                restored.redo(); assertEquals(expected, blocks(restored))
            } finally { a.close(); b.close(); reopened?.close() }
        }
    }


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

    @Test fun typedV4SequentialInputFollowsObservedUnicodeAndPreservesPeerUndo() {
        for (list in listOf(false, true)) for (actor in listOf("a", "z")) {
            val seed = if (list) JSONArray("""[{"id":"p","type":"list","style":"todo","host":"owner","items":[{"id":"i","content":[{"type":"text","text":"C","marks":[{"type":"bold"}]}],"checked":true,"host":"item"}]}]""")
                else JSONArray("""[{"id":"p","type":"paragraph","content":[{"type":"text","text":"C","marks":[{"type":"bold"}]}],"host":"original"}]""")
            val a = WritingSession.createV4("typed-boundary-$list-$actor", actor, "boundary-v4", seed)
            val b = WritingSession.createV4("typed-boundary-$list-$actor", "m", "boundary-v4", seed)
            var reopened: WritingSession? = null
            fun nodes(session: WritingSession): JSONArray {
                val roots = session.snapshot.getJSONArray("blocks")
                return if (list) roots.getJSONObject(0).getJSONArray("items") else roots
            }
            fun texts(session: WritingSession): List<String> {
                val items = nodes(session)
                return (0 until items.length()).map { index ->
                    val content = items.getJSONObject(index).getJSONArray("content")
                    (0 until content.length()).joinToString("") { content.getJSONObject(it).getString("text") }
                }
            }
            try {
                val address = if (list) WritingAddress("p", listOf("items", "i", "content")) else WritingAddress("p")
                a.replaceText(address, 0, 0, "東京")
                val caret = a.replaceText(address, 2, 2, "X")
                assertEquals(3, a.resolvePosition(caret).offset)
                assertEquals(listOf("東京XC"), texts(a))
                b.replaceText(address, 1, 1, "R"); val remote = b.changes()
                a.receive(remote); a.receive(remote); b.receive(a.changes())
                val restored = WritingSession.restore(a.save(), actor); reopened = restored
                assertEquals(listOf("東京XCR"), texts(restored)); assertEquals(blocks(b), blocks(restored))
                restored.undo(); assertEquals(listOf("東京CR"), texts(restored))
                restored.redo(); assertEquals(blocks(a), blocks(restored))
                val item = nodes(restored).getJSONObject(0)
                assertEquals(if (list) "item" else "original", item.getString("host"))
                if (list) assertEquals(true, item.getBoolean("checked"))
                val content = item.getJSONArray("content")
                for (run in 0 until content.length()) assertEquals(normalize(JSONArray("""[{"type":"bold"}]""")), normalize(content.getJSONObject(run).getJSONArray("marks")))
            } finally { reopened?.close(pendingStateRetained = true); a.close(pendingStateRetained = true); b.close(pendingStateRetained = true) }
        }
    }

    @Test fun typedV4SplitPinsCommittedPrefixAndKeepsRemoteTailThroughReopenedUndo() {
        for (list in listOf(false, true)) for (swap in listOf(false, true)) {
            val seed = if (list) JSONArray("""[{"id":"p","type":"list","style":"todo","items":[{"id":"i","content":[{"type":"text","text":"AB","marks":[{"type":"bold"}]}],"checked":true,"host":"item"}]}]""")
                else JSONArray("""[{"id":"p","type":"paragraph","content":[{"type":"text","text":"AB","marks":[{"type":"bold"}]}],"host":"original"}]""")
            val actor = if (swap) "b" else "a"
            val a = WritingSession.createV4("typed-pin-$list-$swap", actor, "pin-v4", seed)
            val b = WritingSession.createV4("typed-pin-$list-$swap", if (swap) "a" else "b", "pin-v4", seed)
            var reopened: WritingSession? = null
            fun texts(session: WritingSession): List<String> {
                val roots = session.snapshot.getJSONArray("blocks")
                val nodes = if (list) roots.getJSONObject(0).getJSONArray("items") else roots
                return (0 until nodes.length()).map { index ->
                    val content = nodes.getJSONObject(index).getJSONArray("content")
                    (0 until content.length()).joinToString("") { content.getJSONObject(it).getString("text") }
                }
            }
            try {
                val address = if (list) WritingAddress("p", listOf("items", "i", "content")) else WritingAddress("p")
                a.replaceText(address, 1, 1, "東京"); b.replaceText(address, 2, 2, "R")
                a.receive(b.changes())
                val caret = if (list) a.enterListItem(address, 3, 3, "tail") else a.splitParagraph(address, 3, 3, "tail")
                val resolved = a.resolvePosition(caret)
                assertEquals(0, resolved.offset)
                assertEquals(listOf("A東京", "BR"), texts(a))
                b.receive(a.changes()); assertEquals(blocks(a), blocks(b))
                b.replaceText(resolved.address, 1, 1, "X"); a.receive(b.changes()); a.receive(b.changes())
                val restored = WritingSession.restore(a.save(), actor); reopened = restored
                assertEquals(listOf("A東京", "BXR"), texts(restored))
                restored.undo(); assertEquals(listOf("A東京BXR"), texts(restored))
                restored.redo(); assertEquals(blocks(a), blocks(restored))
                val roots = restored.snapshot.getJSONArray("blocks")
                val nodes = if (list) roots.getJSONObject(0).getJSONArray("items") else roots
                for (index in 0 until nodes.length()) {
                    val content = nodes.getJSONObject(index).getJSONArray("content")
                    for (run in 0 until content.length()) assertEquals(normalize(JSONArray("""[{"type":"bold"}]""")), normalize(content.getJSONObject(run).getJSONArray("marks")))
                }
            } finally { reopened?.close(pendingStateRetained = true); a.close(pendingStateRetained = true); b.close(pendingStateRetained = true) }
        }
    }

    @Test fun typedV4MiddleEmptyExitPreservesItemOwnerAndRemoteUndo() {
        val seed = JSONArray("""[{"id":"list","type":"list","style":"todo","host":"root","items":[{"id":"first","content":[{"type":"text","text":"before","marks":[]}]},{"id":"empty","content":[],"checked":true,"host":"item"},{"id":"last","content":[{"type":"text","text":"after","marks":[]}]}]}]""")
        val a = WritingSession.createV4("typed-exit", "a", "exit-v4", seed)
        val b = WritingSession.createV4("typed-exit", "b", "exit-v4", seed)
        var reopened: WritingSession? = null
        try {
            val root = normalize(a.node(NodeAddress("list")).wire)
            val item = normalize(a.node(NodeAddress("list", listOf("items", "empty"))).wire)
            val field = WritingAddress("list", listOf("items", "empty", "content"))
            val caret = a.enterListItem(field, 0, 0, "tail")
            assertEquals(item, normalize(a.node(NodeAddress("empty")).wire))
            assertEquals(root, normalize(a.node(NodeAddress("list")).wire))
            assertEquals(0, a.resolvePosition(caret).offset)
            assertEquals(listOf("list", "empty", "tail"), (0 until a.snapshot.getJSONArray("blocks").length()).map { a.snapshot.getJSONArray("blocks").getJSONObject(it).getString("id") })
            b.replaceText(field, 0, 0, "peer")
            a.receive(b.changes()); b.receive(a.changes()); b.receive(a.changes())
            assertEquals(blocks(a), blocks(b))
            val restored = WritingSession.restore(a.save(), "a"); reopened = restored
            restored.undo()
            assertEquals(item, normalize(restored.node(NodeAddress("list", listOf("items", "empty"))).wire))
            assertEquals("peer", restored.snapshot.getJSONArray("blocks").getJSONObject(0).getJSONArray("items").getJSONObject(1).getJSONArray("content").getJSONObject(0).getString("text"))
            restored.redo(); assertEquals(blocks(a), blocks(restored))
        } finally { reopened?.close(pendingStateRetained = true); a.close(pendingStateRetained = true); b.close(pendingStateRetained = true) }
    }

    @Test fun typedV4OverlappingOwnerRepairRetainsBothHistoricalHeadWrites() {
        val seed = JSONArray("""[{"id":"left","type":"list","style":"todo","items":[{"id":"i","content":[{"type":"text","text":"keep😀","marks":[]}],"host":"item"}]},{"id":"right","type":"list","style":"ordered","items":[]}]""")
        val a = WritingSession.createV4("typed-owner", "a", "exit-v4", seed)
        val b = WritingSession.createV4("typed-owner", "b", "exit-v4", seed)
        var reopened: WritingSession? = null
        try {
            val item = b.node(NodeAddress("left", listOf("items", "i")))
            a.convertBlock(WritingAddress("left", listOf("items", "i", "content")), 0, WritingBlockTarget("paragraph"))
            b.moveSelection(WritingSelection(nodes = listOf(item)), NodeCollection.items(b.node(NodeAddress("right"))))
            b.convertBlock(WritingAddress("right", listOf("items", "i", "content")), 0, WritingBlockTarget("paragraph"))
            a.replaceText(WritingAddress("left"), 0, 0, "A"); b.replaceText(WritingAddress("right"), 0, 0, "B")
            val aa = a.changes(); val bb = b.changes(); val before = normalize(a.save().export())
            val recoveryA = try { a.receive(bb); throw AssertionError("Missing typed writing recovery") }
                catch (failure: WritingRecoveryException) { failure.recovery }
            val recoveryB = try { b.receive(aa); throw AssertionError("Missing typed writing recovery") }
                catch (failure: WritingRecoveryException) { failure.recovery }
            assertEquals(MergeRecoveryReason.SCHEMA_CONSTRAINT, recoveryA.reason)
            assertEquals(MergeRecoveryReason.SCHEMA_CONSTRAINT, recoveryB.reason)
            assertEquals(normalize(recoveryA.export()), normalize(checkNotNull(a.mergeRecovery()).export()))
            assertEquals(normalize(recoveryB.export()), normalize(checkNotNull(b.mergeRecovery()).export()))
            assertEquals(before, normalize(a.save().export()))
            a.repairUndo(1, "a"); b.receive(a.changes()); assertEquals(blocks(a), blocks(b))
            assertEquals("BAkeep😀", a.snapshot.getJSONArray("blocks").getJSONObject(1).getJSONArray("content").getJSONObject(0).getString("text"))
            val restored = WritingSession.restore(a.save(), "a"); reopened = restored
            assertEquals(blocks(a), blocks(restored))
        } finally { reopened?.close(pendingStateRetained = true); a.close(pendingStateRetained = true); b.close(pendingStateRetained = true) }
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
    @Test fun typedV4RejectedAuthorUndoRetainsRestartAndTextOrRedoRepair() {
        for (actor in listOf("a", "z")) for (repair in listOf("redo", "text")) {
            val rich = JSONObject("""{"id":"rich","type":"paragraph","host":"keep","content":[{"type":"text","text":"café 😀","marks":[{"type":"bold"}]},{"type":"entity-ref","entityType":"note","entityId":"external","label":"Reference"}]}""")
            val seed = JSONArray().put(rich)
            val a = WritingSession.createV4("typed-undo-$actor-$repair", actor, "undo-v4", seed)
            val b = WritingSession.createV4("typed-undo-$actor-$repair", "peer", "undo-v4", seed)
            var resumed: WritingSession? = null; var reopened: WritingSession? = null
            fun recovery(operation: () -> Unit): WritingRecovery {
                try { operation() } catch (failure: WritingRecoveryException) { return failure.recovery }
                throw AssertionError("Expected typed writing recovery")
            }
            try {
                val math = a.insertCollectionNodes(JSONArray("""[{"id":"math","type":"math","expression":"x+y","extension":{"remote":false,"later":0}}]"""), NodeCollection.ROOT).nodes.single()
                val birth = a.changes(); b.receive(birth)
                val creation = JSONObject().put("counter", 1).put("actor", actor)
                fun peer(counter: Int, key: String, value: Any, observed: JSONArray): WritingBatch {
                    val mutation = JSONObject().put("setNodeField", JSONObject().put("identity", math.wire).put("path", JSONArray(listOf("extension", key))).put("value", value))
                    val operation = JSONObject().put("structure", JSONObject().put("_0", mutation))
                    val edit = JSONObject().put("edit", JSONObject().put("_0", JSONArray().put(operation)))
                    val change = JSONObject().put("id", JSONObject().put("counter", counter).put("actor", "peer")).put("observed", observed).put("body", edit)
                    return WritingBatch.restore(birth.export().put("changes", JSONArray().put(change)))
                }
                b.receive(peer(2, "remote", true, JSONArray().put(creation))); a.receive(b.changes())
                val accepted = a.save(); val acceptedValue = normalize(accepted.export()); val receipts = normalize(a.syncState().wire)
                val initial = recovery { a.undo() }; assertEquals(MergeRecoveryReason.SCHEMA_CONSTRAINT, initial.reason); assertEquals(3, initial.export().getJSONObject("batch").getJSONArray("changes").length())
                recovery { a.redo() }
                b.receive(peer(3, "later", 7, JSONArray().put(creation).put(JSONObject().put("counter", 2).put("actor", "peer"))))
                val pending = recovery { a.receive(b.changes()) }; recovery { a.receive(b.changes()) }
                assertEquals(4, pending.export().getJSONObject("batch").getJSONArray("changes").length())
                assertEquals(acceptedValue, normalize(a.save().export())); assertEquals(receipts, normalize(a.syncState().wire))
                val restored = WritingSession.restore(accepted, actor); resumed = restored
                recovery { restored.restoreRecovery(pending) }
                val pendingBefore = normalize(restored.mergeRecovery()!!.export())
                error("invalidChange") { restored.repairRedo(2, "peer") }
                error("invalidPath") { restored.repairText(math, "children", "bad") }
                error("invalidRange") { restored.repairText(restored.node(NodeAddress("rich")), "content", "café 😀RefeXrence") }
                error("invalidChange") { restored.repairText(math, "expression", "") }
                assertEquals(acceptedValue, normalize(restored.save().export())); assertEquals(pendingBefore, normalize(restored.mergeRecovery()!!.export())); assertEquals(receipts, normalize(restored.syncState().wire))
                if (repair == "redo") restored.repairRedo(1, actor) else restored.repairText(math, "expression", "restored x+y 😀")
                val repairedMath = JSONObject().put("id", "math").put("type", "math").put("expression", if (repair == "redo") "x+y" else "restored x+y 😀").put("extension", JSONObject().put("remote", true).put("later", 7))
                val expected = normalize(JSONArray().put(repairedMath).put(rich))
                assertEquals(expected, blocks(restored)); assertEquals(5, restored.changes().export().getJSONArray("changes").length()); assertNull(restored.mergeRecovery())
                b.receive(restored.changes()); b.receive(restored.changes()); assertEquals(expected, blocks(b))
                reopened = WritingSession.restore(restored.save(), actor); assertEquals(expected, blocks(reopened!!))
            } finally { a.close(); b.close(); resumed?.close(); reopened?.close() }
        }
    }

}
