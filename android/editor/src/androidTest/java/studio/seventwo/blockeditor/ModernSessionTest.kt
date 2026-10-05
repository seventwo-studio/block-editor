package studio.seventwo.blockeditor

import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test

/** Focused real-JNI consumer proof, separate from native UI and complete platform acceptance. */
class ModernSessionTest {
    private fun document(id: String) = ModernDocument.restore(JSONObject("""{
        "format":"seventwo.block-editor.document","formatVersion":1,"documentID":"$id","title":"Title",
        "appearance":{"fontFamily":"sans","fontSize":"default","pageWidth":"readable","consumer":{"value":"keep"}},
        "blocks":[{"id":"p","type":"paragraph","content":[{"type":"text","text":"abcd"}]},
        {"id":"image","type":"image","src":"asset://pending","alt":"old"}],"consumer":{"id":"opaque"}
    }"""))
    private fun content(session: ModernSession) = session.snapshot.document.blocks.first().export().getJSONArray("content").getJSONObject(0).getString("text")
    private fun applied(result: ModernResult) { assertEquals(ModernResultStatus.APPLIED, result.status); assertNotNull(result.transaction) }

    @Test fun modernTypedConsumerRetainsPeerInputArchivesAndExplicitHostBoundaries() {
        val sessions = mutableListOf<ModernSession>()
        fun create(id: String, actor: String) = ModernSession.create(document(id), actor, "epoch").also { sessions.add(it) }
        fun restore(session: ModernSession, actor: String) = ModernSession.restore(session.save(), actor).also { sessions.add(it) }
        val field = ModernField(ModernNodeID.baseline("p"), "content")
        try {
            val a = create("kotlin-modern", "a"); val b = create("kotlin-modern", "b")
            assertEquals(ModernCommandName.entries.toSet(), a.capabilities().commands.toSet())
            val initial = a.snapshot
            initial.export().getJSONObject("document").put("title", "corrupt"); assertEquals("Title", a.snapshot.document.title)
            val range = a.captureTextRange(field, 3, 1)
            applied(b.execute(ModernCommand.ReplaceText(b.captureTextRange(field, 2, 2), "X")))
            val releaseA = a.holdRemoteChanges(); val releaseB = a.holdRemoteChanges()
            a.receive(b.changes()); assertEquals("abcd", content(a)); assertEquals(1, a.deferredChanges().size)
            releaseA(); releaseA(); assertEquals("abcd", content(a)); releaseB(); releaseB(); assertEquals("abXcd", content(a))
            var published = false
            val unsubscribe = a.subscribe { published = content(a) == "a😀Xd" }
            applied(a.execute(ModernCommand.ReplaceText(range, "😀"))); unsubscribe(); assertTrue(published)
            assertEquals("a😀Xd", content(a)); assertEquals("abcd", initial.document.blocks.first().export().getJSONArray("content").getJSONObject(0).getString("text"))
            b.receive(a.changes()); b.receive(a.changes()); assertEquals(content(a), content(b))
            val reopened = restore(a, "a"); reopened.restoreHistorySelection(a.exportHistorySelection())
            applied(reopened.execute(ModernCommand.Undo)); assertEquals("abXcd", content(reopened))
            applied(reopened.execute(ModernCommand.Redo)); assertEquals("a😀Xd", content(reopened))
            val report = mutableListOf<Throwable>(); reopened.onListenerError = { report.add(it) }
            val stopBroken = reopened.subscribe { error("observer failure") }
            applied(reopened.execute(ModernCommand.Appearance.FontFamily("kotlin-modern", ModernFontFamily.SERIF))); stopBroken()
            assertEquals(1, report.size); assertEquals("keep", reopened.snapshot.document.appearance.export().getJSONObject("consumer").getString("value"))
            reopened.setComposing(true)
            assertEquals(ModernResultStatus.UNAVAILABLE, reopened.execute(ModernCommand.ReplaceTitle(reopened.captureTextRange(ModernField(ModernNodeID.document("kotlin-modern"), "title"), 0, 5), "New")).status)
            reopened.setComposing(false)
            val target = ModernDeleteTarget(ranges = listOf(reopened.captureTextRange(field, 1, 3)))
            val copied = reopened.copy(target); assertEquals("😀", copied.plainText)
            val cut = reopened.prepareCut(target)
            assertEquals(ModernResultStatus.UNAVAILABLE, reopened.finishCut(cut, false).status); assertEquals("a😀Xd", content(reopened))
            applied(reopened.finishCut(cut, true)); assertEquals(ModernResultStatus.NOOP, reopened.finishCut(cut, true).status); assertEquals("aXd", content(reopened)); reopened.forgetCut(cut.preparationID)
            applied(reopened.execute(ModernCommand.Paste(ModernPasteTarget.Range(reopened.captureTextRange(field, 1, 1)), copied))); assertEquals("a😀Xd", content(reopened))
            val request = reopened.beginAsyncBlock(ModernNodeID.baseline("image"), "provider")
            val providerArchive = reopened.exportAsyncRequests(); val providerReopen = restore(reopened, "a")
            val metadata = ModernPayload.restore(JSONObject().put("alt", "ready"))
            assertEquals(ModernResultStatus.UNAVAILABLE, providerReopen.execute(ModernCommand.CompleteAsyncBlock(request, metadata)).status)
            providerReopen.restoreAsyncRequests(providerArchive); assertEquals("old", providerReopen.snapshot.document.blocks[1].export().getString("alt"))
            val replacement = providerReopen.beginAsyncBlock(ModernNodeID.baseline("image"), "new-provider")
            assertEquals(ModernResultStatus.UNAVAILABLE, providerReopen.execute(ModernCommand.CompleteAsyncBlock(request, metadata)).status)
            applied(providerReopen.execute(ModernCommand.CompleteAsyncBlock(replacement, metadata))); assertEquals("ready", providerReopen.snapshot.document.blocks[1].export().getString("alt")); providerReopen.forgetAsyncBlock(replacement)

            val x = create("kotlin-recovery", "x"); val y = create("kotlin-recovery", "y")
            val own = x.execute(ModernCommand.InsertBlock(x.captureBoundary(), ModernPayload.restore(JSONObject("""{"id":"same","type":"paragraph","content":[{"type":"text","text":"X"}]}""")))).also { applied(it) }.transaction!!
            applied(y.execute(ModernCommand.InsertBlock(y.captureBoundary(), ModernPayload.restore(JSONObject("""{"id":"same","type":"paragraph","content":[{"type":"text","text":"Y"}]}""")))))
            val accepted = x.save().export().toString(); val receipt = x.snapshot.syncState.export().toString()
            try { x.receive(y.changes()); fail("Identity conflict must retain recovery") } catch (failure: ModernRecoveryException) {
                assertEquals(MergeRecoveryReason.IDENTITY_CONFLICT, failure.recovery.reason); assertNotNull(x.snapshot.recovery)
                assertEquals(accepted, x.save().export().toString()); assertEquals(receipt, x.snapshot.syncState.export().toString())
                val recovered = restore(x, "x")
                try { recovered.restoreRecovery(failure.recovery); fail("Restored union remains unresolved") } catch (_: ModernRecoveryException) { }
                recovered.repairUndo(listOf(own)); assertEquals(3, recovered.snapshot.document.blocks.size)
                assertEquals("Y", recovered.snapshot.document.blocks.last().export().getJSONArray("content").getJSONObject(0).getString("text"))
            }
            val closeRelease = a.holdRemoteChanges(); a.close(); closeRelease(); a.close()
            try { a.save(); fail("Closed handle must reject") } catch (_: IllegalStateException) { }
        } finally { sessions.asReversed().forEach { it.close() } }
    }
}
