package studio.seventwo.blockeditor

import androidx.compose.ui.text.TextRange
import androidx.compose.ui.text.input.TextFieldValue
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.cancel
import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test

/** Current owner leases plus actual typed JNI; separate from installed IME. */
class WritingAuthoringInputTest {
    private fun seed() = JSONArray("""[{"id":"p","type":"paragraph","host":"keep","content":[{"type":"text","text":"A","marks":[{"type":"bold"}]},{"type":"entity-ref","entityType":"person","entityId":"mira","label":"Mira","host":"opaque"},{"type":"text","text":"B","marks":[]}]}]""")
    private fun create(version: Int, document: String, actor: String) = when(version) {
        4 -> WritingSession.createV4(document, actor, "native-$version", seed())
        5 -> WritingSession.createV5(document, actor, "native-$version", seed())
        else -> WritingSession.createV6(document, actor, "native-$version", seed())
    }
    private fun rich(session: WritingSession) = session.snapshot.getJSONArray("blocks").getJSONObject(0).getJSONArray("content")
    private fun text(session: WritingSession) = plainText(rich(session))
    private fun rejected(action: () -> Unit) { try { action(); fail("Expected rejection") } catch (_: IllegalStateException) { } }
    private fun clipboard() = WritingClipboard.restore(JSONObject("""{"version":1,"parts":[{"inline":{"_0":[{"type":"text","text":"X😀","marks":[{"type":"italic"}]},{"type":"entity-ref","entityType":"task","entityId":"task","label":"Task","host":"clipboard-meta"}]}}]}"""))

    @Test fun markedFinalValueAndHeldPeerCommitBeforeTypedPasteAndSingleAuthorUndo() {
        for (version in listOf(4,5,6)) {
            val a=create(version,"native-paste-$version","a"); val b=create(version,"native-paste-$version","b")
            val scope=CoroutineScope(SupervisorJob()+Dispatchers.Unconfined)
            val owner=WritingEditorInputs(a,scope,{true},{ assertTrue(it.isEmpty()) },{throw it})
            val origin=a.node(NodeAddress("p")); val old=owner.bind(origin); owner.attach(old); owner.focusChanged(old,true)
            try {
                old.update(TextFieldValue("A東MiraB",TextRange(2),TextRange(1,2)))
                b.replaceText(b.textAddress(b.node(NodeAddress("p"))),6,6,"R");a.receive(b.changes())
                assertEquals("AMiraB",text(a));assertEquals(1,a.exportDeferredChanges().size)
                owner.paste(old,{old.update(TextFieldValue("A東京MiraB",TextRange(3)))},clipboard())
                assertEquals("A東京X😀TaskMiraBR",text(a));assertTrue(a.exportDeferredChanges().isEmpty())
                assertEquals(3,a.changes().export().getJSONArray("changes").length())
                assertTrue(rich(a).toString().contains("clipboard-meta"));assertTrue(rich(a).toString().contains("opaque"))
                assertEquals("keep",a.snapshot.getJSONArray("blocks").getJSONObject(0).getString("host"))
                assertEquals(writingCanonical(origin.wire),writingCanonical(a.node(NodeAddress("p")).wire))
                val request=checkNotNull(owner.focusRequest);assertEquals(10,a.resolvePosition(request.range.start).offset)
                val accepted=a.save().export().toString();old.update(TextFieldValue("stale"));assertEquals(accepted,a.save().export().toString())
                val restored=WritingSession.restore(a.save(),"a")
                try { restored.undo();assertEquals("A東京MiraBR",text(restored));b.receive(restored.changes());assertEquals(text(restored),text(b));restored.redo();assertEquals("A東京X😀TaskMiraBR",text(restored)) }
                finally {restored.close()}
            } finally {owner.close();scope.cancel();a.close();b.close()}
        }
    }

    @Test fun revokedReadOnlyAndClosedLeasesCannotRunPasteOrFormatting() {
        for(version in listOf(4,5,6)) {
            val a=create(version,"native-authority-$version","a");val scope=CoroutineScope(SupervisorJob()+Dispatchers.Unconfined);var editable=true
            val owner=WritingEditorInputs(a,scope,{editable},{assertTrue(it.isEmpty())},{throw it})
            val origin=a.node(NodeAddress("p"));val old=owner.bind(origin);owner.attach(old);owner.focusChanged(old,true)
            val live=owner.bind(origin);owner.attach(live);owner.focusChanged(live,true)
            var finalized=0
            try {
                val before=a.save().export().toString();val receipts=a.syncState().export().toString()
                rejected {owner.paste(old,{finalized++},clipboard())}
                editable=false;rejected {owner.paste(live,{finalized++},clipboard())};rejected {owner.format(live,{finalized++},"bold",JSONObject().put("type","bold"))}
                assertEquals(0,finalized);assertEquals(before,a.save().export().toString());assertEquals(receipts,a.syncState().export().toString())
                editable=true;a.setAllowedBlockTypes(emptySet())
                val limited=a.save().export().toString()
                val whole=WritingClipboard.restore(JSONObject("""{"version":1,"parts":[{"node":{"kind":"block","value":{"id":"h","type":"heading","level":2,"content":[{"type":"text","text":"Title","marks":[]}]}}}]}"""))
                rejected {owner.paste(live,{},whole)}
                assertEquals(limited,a.save().export().toString());assertNull(a.mergeRecovery())
                owner.close();rejected {owner.paste(live,{finalized++},clipboard())};assertEquals(0,finalized)
            } finally {owner.close();scope.cancel();a.close()}
        }
    }

    @Test fun formattingAndConversionUseFinalSelectionAndPreserveOriginPeerAndReopen() {
        for(version in listOf(4,5,6)) {
            val a=create(version,"native-format-$version","a");val b=create(version,"native-format-$version","b");val scope=CoroutineScope(SupervisorJob()+Dispatchers.Unconfined)
            val owner=WritingEditorInputs(a,scope,{true},{assertTrue(it.isEmpty())},{throw it});val origin=a.node(NodeAddress("p"))
            val old=owner.bind(origin);owner.attach(old);owner.focusChanged(old,true)
            try {
                old.update(TextFieldValue("A東京MiraB",TextRange(3,1),TextRange(1,3)))
                b.replaceText(b.textAddress(b.node(NodeAddress("p"))),6,6,"R");a.receive(b.changes())
                owner.format(old,{old.update(TextFieldValue("A東京MiraB",TextRange(3,1)))},"italic",JSONObject().put("type","italic"))
                assertEquals("A東京MiraBR",text(a));assertTrue(rich(a).toString().contains("italic"));assertTrue(rich(a).toString().contains("opaque"))
                val request=checkNotNull(owner.focusRequest);val fresh=owner.bind(origin);owner.attach(fresh);owner.consume(request,fresh);owner.focusChanged(fresh,true)
                assertEquals(TextRange(3,1),fresh.input.value.selection)
                owner.convert(fresh,{},WritingBlockTarget("heading",level=2))
                assertEquals("heading",a.snapshot.getJSONArray("blocks").getJSONObject(0).getString("type"));assertEquals("A東京MiraBR",text(a))
                assertEquals(writingCanonical(origin.wire),writingCanonical(a.node(NodeAddress("p")).wire))
                val restored=WritingSession.restore(a.save(),"a")
                try {restored.undo();assertEquals("paragraph",restored.snapshot.getJSONArray("blocks").getJSONObject(0).getString("type"));assertEquals("A東京MiraBR",text(restored));restored.redo();assertEquals("heading",restored.snapshot.getJSONArray("blocks").getJSONObject(0).getString("type"))}
                finally {restored.close()}
            } finally {owner.close();scope.cancel();a.close();b.close()}
        }
    }

    @Test fun typedCopyCutAndPlainImportKeepAtomicReferenceAndExplicitEpoch() {
        for(version in listOf(4,5,6)) {
            val a=create(version,"native-copy-$version","a");val scope=CoroutineScope(SupervisorJob()+Dispatchers.Unconfined)
            val owner=WritingEditorInputs(a,scope,{true},{assertTrue(it.isEmpty())},{throw it});val origin=a.node(NodeAddress("p"));val old=owner.bind(origin);owner.attach(old);owner.focusChanged(old,true)
            try {
                old.update(TextFieldValue("AMiraB",TextRange(5,1)))
                var copied:WritingClipboard?=null;owner.copy(old,{},{copied=it})
                assertTrue(checkNotNull(copied).export().toString().contains("opaque"));assertEquals(0,a.changes().export().getJSONArray("changes").length())
                val request=checkNotNull(owner.focusRequest);val fresh=owner.bind(origin);owner.attach(fresh);owner.consume(request,fresh);owner.focusChanged(fresh,true)
                owner.cut(fresh,{},{assertEquals(writingCanonical(copied!!.export()),writingCanonical(it.export()))})
                assertEquals("AB",text(a));assertEquals(1,a.changes().export().getJSONArray("changes").length())
                val restored=WritingSession.restore(a.save(),"a")
                try {restored.undo();assertEquals("AMiraB",text(restored));restored.redo();assertEquals("AB",text(restored))} finally {restored.close()}
                val plain=WritingNativeClipboard.plain(a,"東京\r\n😀").export()
                assertEquals(version,a.save().export().getInt("version"))
                assertEquals(if(version==4)1 else 2,plain.getJSONArray("parts").length())
            } finally {owner.close();scope.cancel();a.close()}
        }
    }
    @Test fun externalTypedDepthRejectsBeforeParsingWithoutLosingNativeDraftOrHeldPeer() {
        for (version in listOf(4, 5, 6)) {
            val a = create(version, "native-clipboard-depth-$version", "a")
            val b = create(version, "native-clipboard-depth-$version", "b")
            val scope = CoroutineScope(SupervisorJob() + Dispatchers.Unconfined)
            val owner = WritingEditorInputs(a, scope, { true }, { }, { throw it })
            val binding = owner.bind(a.node(NodeAddress("p")))
            owner.attach(binding); owner.focusChanged(binding, true)
            try {
                binding.update(TextFieldValue("A東京MiraB", TextRange(3), TextRange(1, 3)))
                b.replaceText(b.textAddress(b.node(NodeAddress("p"))), 6, 6, "R")
                a.receive(b.changes())
                val accepted = a.save().export().toString()
                val received = a.syncState().export().toString()
                for (malicious in listOf("[".repeat(129) + "0" + "]".repeat(129),
                    "{\"payload\":" + "[".repeat(129))) {
                    try { WritingNativeClipboard.decodeTyped(malicious); fail("Deep native JSON must reject before parsing") }
                    catch (failure: IllegalArgumentException) { assertEquals("Clipboard JSON exceeds the envelope depth limit", failure.message) }
                }
                val hiddenDepth = "[".repeat(300)
                for (malicious in listOf("{'payload':'\"', 'nested':" + hiddenDepth,
                    "{/*\"*/\"nested\":" + hiddenDepth,
                    "{#\"\n\"nested\":" + hiddenDepth,
                    "{bare\" token: " + hiddenDepth)) {
                    try { WritingNativeClipboard.decodeTyped(malicious); fail("Lenient quote/comment hiding must reject before parsing") }
                    catch (_: IllegalArgumentException) { }
                }
                val escaped = "\"" + "[{}]".repeat(150) + "\\"
                val value = JSONObject().put("version", 1).put("parts", JSONArray().put(JSONObject().put("inline",
                    JSONObject().put("_0", JSONArray().put(JSONObject().put("type", "text").put("text", escaped).put("marks", JSONArray()))))))
                val decoded = WritingNativeClipboard.decodeTyped(value.toString())
                assertEquals(writingCanonical(value), writingCanonical(decoded.export()))
                assertEquals(accepted, a.save().export().toString())
                assertEquals(received, a.syncState().export().toString())
                assertEquals(1, a.exportDeferredChanges().size)
                assertEquals("A東京MiraB", binding.input.value.text)
                assertEquals(TextRange(1, 3), binding.input.value.composition)
            } finally { owner.close(); scope.cancel(); a.close(); b.close() }
        }
    }

}
