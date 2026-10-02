package studio.seventwo.blockeditor

import androidx.compose.ui.text.TextRange
import androidx.compose.ui.text.input.TextFieldValue
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test

/** Actual typed JNI owner commands; physical input/accessibility needs separate installed acceptance. */
class WritingPlainInputTest {
    private fun seed() = JSONArray("""[{"id":"code","type":"code","code":"AB","language":"swift","consumer":{"keep":"code-meta"}},{"id":"math","type":"math","expression":"AB","consumer":{"keep":"math-meta"}},{"id":"toggle","type":"toggle","summary":[],"children":[]},{"id":"rich","type":"paragraph","content":[{"type":"text","text":"é😀","marks":[{"type":"bold"}]},{"type":"entity-ref","entityType":"task","entityId":"t","label":"Task","consumer":"ref-meta"}]}]""")
    private fun session(version: Int, id: String, actor: String = "a", blocks: JSONArray = seed()) = when (version) {
        4 -> WritingSession.createV4(id, actor, "plain-v4", blocks)
        5 -> WritingSession.createV5(id, actor, "plain-v5", blocks)
        else -> WritingSession.createV6(id, actor, "plain-v6", blocks)
    }
    private fun text(a: WritingSession, id: NodeIdentity, field: String) = writingNodeValue(a, id).getString(field)
    private fun rejected(action: () -> Unit) { try { action(); fail("Expected rejection") } catch (_: IllegalStateException) { } }
    private fun next(owner: WritingEditorInputs, a: WritingSession, id: NodeIdentity, field: String): WritingEditorInputs.Binding {
        val binding = owner.bind(id, field); owner.attach(binding)
        owner.focusRequest?.let { owner.consume(it, binding) }; owner.focusChanged(binding, true); return binding
    }

    @Test fun codeAndMathCompositionFinalizeIntoSharedSoftBreakAndPeerPreservingHistory() {
        for (version in listOf(4,5,6)) for ((name, field) in listOf("code" to "code", "math" to "expression")) {
            val a = session(version, "plain-compose-$name-$version"); val b = session(version, "plain-compose-$name-$version", "b")
            val scope = CoroutineScope(SupervisorJob() + Dispatchers.Unconfined)
            val owner = WritingEditorInputs(a, scope, { true }, { assertTrue(it.isEmpty()) }, { throw it }, collections = true)
            val identity = a.node(NodeAddress(name)); val binding = next(owner, a, identity, field)
            val richBefore = writingCanonical(writingNodeValue(a, a.node(NodeAddress("rich"))))
            try {
                binding.update(TextFieldValue("A東B", TextRange(2), TextRange(1,2)))
                val peer = b.node(NodeAddress(name)); b.replaceText(b.textAddress(peer, field), 2, 2, "R"); a.receive(b.changes())
                assertEquals("AB", text(a, identity, field)); assertEquals(1, a.exportDeferredChanges().size)
                owner.enter(binding, { binding.update(TextFieldValue("A東京B", TextRange(3))) }, "must-not-create")
                assertEquals("A東京\nBR", text(a, identity, field)); assertEquals(4, a.collectionNodes(NodeCollection.ROOT).size)
                assertEquals(4, a.resolvePosition(checkNotNull(owner.focusRequest).range.start).offset)
                assertEquals("$name-meta", writingNodeValue(a, identity).getJSONObject("consumer").getString("keep"))
                assertEquals(richBefore, writingCanonical(writingNodeValue(a, a.node(NodeAddress("rich")))))
                next(owner, a, identity, field); assertTrue(owner.exportDrafts().isEmpty())
                val accepted = a.save().export().toString(); binding.update(TextFieldValue("stale")); assertEquals(accepted, a.save().export().toString())
                b.receive(a.changes()); assertEquals(text(a, identity, field), text(b, peer, field))
                val reopened = WritingSession.restore(a.save(), "a")
                try {
                    reopened.undo(); assertEquals("A東京BR", text(reopened, identity, field))
                    reopened.undo(); assertEquals("ABR", text(reopened, identity, field))
                    reopened.redo(); reopened.redo(); assertEquals("A東京\nBR", text(reopened, identity, field))
                    assertEquals(richBefore, writingCanonical(writingNodeValue(reopened, reopened.node(NodeAddress("rich")))))
                } finally { reopened.close() }
            } finally { owner.close(); scope.cancel(); a.close(); b.close() }
        }
    }

    @Test fun plainPasteKeepsMultilineLiteralAndRejectsRichBeforeNativeFinalization() {
        for (version in listOf(4,5,6)) for ((name, field) in listOf("code" to "code", "math" to "expression")) {
            val a = session(version, "plain-paste-$name-$version"); val b = session(version, "plain-paste-$name-$version", "b")
            val scope = CoroutineScope(SupervisorJob() + Dispatchers.Unconfined)
            val owner = WritingEditorInputs(a, scope, { true }, { }, { throw it }, collections = true)
            val identity = a.node(NodeAddress(name)); val binding = next(owner, a, identity, field)
            try {
                binding.update(TextFieldValue("A東京B", TextRange(3), TextRange(1,3)))
                b.replaceText(b.textAddress(b.node(NodeAddress(name)), field), 2,2,"R"); a.receive(b.changes())
                val accepted = a.save().export().toString(); val receipt = a.syncState().export().toString(); var revoked = 0
                val rich = WritingClipboard.restore(JSONObject("""{"version":1,"parts":[{"inline":{"_0":[{"type":"text","text":"bold","marks":[{"type":"bold"}]}]}}]}"""))
                val reference = WritingClipboard.restore(JSONObject("""{"version":1,"parts":[{"inline":{"_0":[{"type":"entity-ref","entityType":"task","entityId":"t","label":"Task"}]}}]}"""))
                val structure = a.clipboardText("Whole", "multiline")
                for (clipboard in listOf(rich, reference, structure)) rejected { owner.paste(binding, { revoked++ }, clipboard) }
                rejected { owner.format(binding, { revoked++ }, "bold", JSONObject().put("type","bold")) }
                rejected { owner.convert(binding, { revoked++ }, WritingBlockTarget("paragraph")) }
                rejected { owner.markdownShortcut(binding, { revoked++ }) }
                rejected { owner.mergePrevious(binding, { revoked++ }) }
                assertEquals(0, revoked); assertEquals(accepted, a.save().export().toString()); assertEquals(receipt, a.syncState().export().toString())
                assertEquals(TextRange(1,3), binding.input.value.composition); assertEquals(1, a.exportDeferredChanges().size)
                val plain = WritingNativeClipboard.plain(a, "café😀\r\nx", plainField = true)
                owner.paste(binding, { binding.update(TextFieldValue("A東京B", TextRange(3))) }, plain)
                assertEquals("A東京café😀\nxBR", text(a, identity, field)); assertEquals(11, a.resolvePosition(checkNotNull(owner.focusRequest).range.start).offset)
                next(owner,a,identity,field); assertTrue(owner.exportDrafts().isEmpty())
                val reopened = WritingSession.restore(a.save(), "a")
                try { reopened.undo(); assertEquals("A東京BR", text(reopened,identity,field)); reopened.redo(); assertEquals(text(a,identity,field),text(reopened,identity,field)) }
                finally { reopened.close() }
            } finally { owner.close(); scope.cancel(); a.close(); b.close() }
        }
    }

    @Test fun plainReadOnlyMovedReusedAndClosedLeasesCannotWrite() {
        for (version in listOf(4,5,6)) for ((name, field) in listOf("code" to "code", "math" to "expression")) {
            val a = session(version,"plain-lease-$name-$version");val b=session(version,"plain-lease-$name-$version","b")
            val scope=CoroutineScope(SupervisorJob()+Dispatchers.Unconfined);var editable=true
            val owner=WritingEditorInputs(a,scope,{editable},{},{throw it},collections=true)
            val identity=a.node(NodeAddress(name));val binding=next(owner,a,identity,field)
            try {
                val initial=a.save().export().toString();editable=false;binding.update(TextFieldValue("readonly"));rejected{owner.softBreak(binding,{})};assertEquals(initial,a.save().export().toString());editable=true
                val peer=b.node(NodeAddress(name)); b.moveSelection(WritingSelection(nodes=listOf(peer)),NodeCollection.children(b.node(NodeAddress("toggle"))))
                val replacement=JSONObject().put("id",name).put("type",name).put(field,"Replacement");b.insertCollectionNodes(JSONArray().put(replacement),NodeCollection.ROOT)
                a.receive(b.changes());assertNotEquals(writingCanonical(identity.wire),writingCanonical(a.node(NodeAddress(name)).wire))
                val accepted=a.save().export().toString();binding.update(TextFieldValue("stale"));rejected{owner.softBreak(binding,{})};assertEquals(accepted,a.save().export().toString())
                val live=next(owner,a,identity,field);live.update(TextFieldValue("AB",TextRange(2)));owner.softBreak(live,{})
                assertEquals("AB\n",text(a,identity,field));assertEquals("Replacement",text(a,a.node(NodeAddress(name)),field))
                next(owner,a,identity,field);owner.close();val closed=a.save().export().toString();live.update(TextFieldValue("closed"));rejected{owner.softBreak(live,{})};assertEquals(closed,a.save().export().toString())
            } finally {owner.close();scope.cancel();a.close();b.close()}
        }
    }

    @Test fun failedRequiredMathDraftRetainsAcceptedAndDeferredHistoryUntilCorrected() {
        for(version in listOf(4,5,6)) {
            val seed=JSONArray("""[{"id":"m","type":"math","expression":"A","consumer":{"keep":"math-meta"}}]""")
            val a=session(version,"plain-math-failed-$version",blocks=seed);val b=session(version,"plain-math-failed-$version","b",seed)
            val scope=CoroutineScope(SupervisorJob()+Dispatchers.Unconfined);val errors=mutableListOf<Exception>();var diskAvailable=false
            val owner=WritingEditorInputs(a,scope,{true},{if(!diskAvailable)error("Disk unavailable")},{errors.add(it)},collections=true)
            val identity=a.node(NodeAddress("m"));val binding=next(owner,a,identity,"expression")
            try {
                binding.update(TextFieldValue("",TextRange(0),TextRange(0)))
                b.replaceText(b.textAddress(b.node(NodeAddress("m")),"expression"),1,1,"R");a.receive(b.changes())
                val accepted=a.save().export().toString();val receipt=a.syncState().export().toString()
                rejected{owner.enter(binding,{},"no-split")};assertEquals(accepted,a.save().export().toString());assertEquals(receipt,a.syncState().export().toString())
                val draft=owner.exportDrafts().single();assertEquals("",draft.text);assertEquals(1,draft.deferred.size);assertEquals(accepted,draft.accepted.export().toString());assertNotNull(binding.input.failedReason)
                rejected{owner.close()};assertEquals("",binding.input.value.text);assertEquals(1,a.exportDeferredChanges().size)
                val fresh=next(owner,a,identity,"expression");fresh.update(TextFieldValue("A",TextRange(1)));assertEquals("AR",text(a,identity,"expression"));assertTrue(a.exportDeferredChanges().isEmpty());assertTrue(owner.exportDrafts().isEmpty())
                diskAvailable=true;assertEquals("math-meta",writingNodeValue(a,identity).getJSONObject("consumer").getString("keep"));assertTrue(errors.isEmpty())
                val restored=WritingSession.restore(a.save(),"a");try{assertEquals("AR",text(restored,identity,"expression"))}finally{restored.close()}
            } finally {diskAvailable=true;owner.close();scope.cancel();a.close();b.close()}
        }
    }

    @Test fun emptyCodeIsEditableWhileMissingRequiredPlainFieldsRejectWithoutInventingData() {
        for(version in listOf(4,5,6)) {
            val seed=JSONArray("""[{"id":"c","type":"code","code":"","consumer":"empty"}]""")
            val a=session(version,"plain-empty-$version",blocks=seed);val scope=CoroutineScope(SupervisorJob()+Dispatchers.Unconfined)
            val owner=WritingEditorInputs(a,scope,{true},{assertTrue(it.isEmpty())},{throw it},collections=true);val identity=a.node(NodeAddress("c"));val binding=next(owner,a,identity,"code")
            try{
                binding.update(TextFieldValue("東京😀",TextRange(4)));assertEquals("東京😀",text(a,identity,"code"));val before=a.save().export().toString()
                for(type in listOf("code","math")) rejected{session(version,"missing-$type-$version",blocks=JSONArray().put(JSONObject().put("id","missing").put("type",type))).close()}
                assertEquals(before,a.save().export().toString());assertEquals("empty",writingNodeValue(a,identity).getString("consumer"))
                val reopened=WritingSession.restore(a.save(),"a");try{reopened.undo();assertEquals("",text(reopened,identity,"code"));reopened.redo();assertEquals("東京😀",text(reopened,identity,"code"))}finally{reopened.close()}
            }finally{owner.close();scope.cancel();a.close()}
        }
    }
}
