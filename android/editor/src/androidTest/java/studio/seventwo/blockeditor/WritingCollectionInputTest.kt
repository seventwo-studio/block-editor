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

class WritingCollectionInputTest {
    private fun seed() = JSONArray("""[
      {"id":"toggle","type":"toggle","summary":[{"type":"text","text":"Summary","marks":[]}],"consumer":"toggle-meta","children":[
        {"id":"p","type":"paragraph","consumer":"paragraph-meta","content":[{"type":"text","text":"AB","marks":[{"type":"bold"}]},{"type":"entity-ref","entityType":"task","entityId":"t","label":"Task","consumer":"reference-meta"}]}]},
      {"id":"list","type":"list","style":"todo","consumer":"list-meta","items":[
        {"id":"i","checked":false,"consumer":"item-meta","content":[{"type":"text","text":"AB","marks":[{"type":"italic"}]}],"children":[]},
        {"id":"j","checked":true,"content":[{"type":"text","text":"Other","marks":[]}],"children":[]}]},
      {"id":"table","type":"table","consumer":"table-meta","rows":[{"id":"row","cells":[{"id":"cell","consumer":"cell-meta","content":[{"type":"text","text":"Cell","marks":[]}]}]}]},
      {"id":"image","type":"image","src":"https://assets.invalid/inert","caption":[{"type":"text","text":"Caption","marks":[]}],"consumer":{"asset":"host-only"}}
    ]""")
    private fun create(version: Int, document: String, actor: String) = when (version) {
        4 -> WritingSession.createV4(document, actor, "collections-$version", seed())
        5 -> WritingSession.createV5(document, actor, "collections-$version", seed())
        else -> WritingSession.createV6(document, actor, "collections-$version", seed())
    }
    private fun text(session: WritingSession, identity: NodeIdentity, field: String = "content") =
        plainText(writingNodeValue(session, identity).getJSONArray(field))
    private fun rejected(action: () -> Unit) { try { action(); fail("Expected rejection") } catch (_: IllegalStateException) { } }
    private fun owner(session: WritingSession, scope: CoroutineScope, editable: () -> Boolean = { true }) =
        WritingEditorInputs(session, scope, editable, {}, { throw it }, collections = true)

    @Test fun nestedCompositionDrainsPeerBeforeSplitAndUndoKeepsRichOrigins() {
        for (version in listOf(4, 5, 6)) {
            val a = create(version, "nested-enter-$version", "a"); val b = create(version, "nested-enter-$version", "b")
            val scope = CoroutineScope(SupervisorJob() + Dispatchers.Unconfined)
            val inputs = owner(a, scope)
            val original = a.node(NodeAddress("toggle", listOf("children", "p")))
            val binding = inputs.bind(original); inputs.attach(binding); inputs.focusChanged(binding, true)
            try {
                binding.update(TextFieldValue("A東BTask", TextRange(2), TextRange(1, 2)))
                val peer = b.node(NodeAddress("toggle", listOf("children", "p")))
                b.replaceText(b.textAddress(peer), 6, 6, "R"); a.receive(b.changes())
                assertEquals("ABTask", text(a, original)); assertEquals(1, a.exportDeferredChanges().size)
                inputs.enter(binding, { binding.update(TextFieldValue("A東京BTask", TextRange(3))) }, "tail")
                assertEquals("A東京", text(a, original)); assertTrue(a.exportDeferredChanges().isEmpty())
                val tail = a.node(NodeAddress("toggle", listOf("children", "tail")))
                assertEquals("BTaskR", text(a, tail)); assertEquals("paragraph-meta", writingNodeValue(a, original).getString("consumer"))
                assertTrue(writingNodeValue(a, tail).toString().contains("reference-meta"))
                val request = checkNotNull(inputs.focusRequest)
                assertEquals(0, a.resolvePosition(request.range.start).offset)
                val next = inputs.bind(tail); inputs.attach(next); inputs.consume(request, next); inputs.focusChanged(next, true)
                assertTrue("A successful split must not manufacture a native draft", inputs.exportDrafts().isEmpty())
                assertEquals(3, a.changes().export().getJSONArray("changes").length())
                val accepted = a.save().export().toString(); binding.update(TextFieldValue("stale")); assertEquals(accepted, a.save().export().toString())
                next.update(TextFieldValue("BTaskR", TextRange(0, 1)))
                inputs.format(next, {}, "italic", JSONObject().put("type", "italic"))
                assertTrue(inputs.exportDrafts().isEmpty())
                assertTrue(writingNodeValue(a, tail).getJSONArray("content").toString().contains("italic"))
                val reopened = WritingSession.restore(a.save(), "a")
                try {
                    reopened.undo(); assertEquals("BTaskR", text(reopened, tail))
                    reopened.undo(); assertEquals("A東京BTaskR", text(reopened, original)); b.receive(reopened.changes())
                    assertEquals(reopened.snapshot.getJSONArray("blocks").toString(), b.snapshot.getJSONArray("blocks").toString())
                    reopened.redo(); reopened.redo(); assertEquals("BTaskR", text(reopened, tail))
                    assertTrue(writingNodeValue(reopened, tail).getJSONArray("content").toString().contains("italic"))
                } finally { reopened.close() }
            } finally { inputs.close(); scope.cancel(); a.close(); b.close() }
        }
    }

    @Test fun checklistContinuationCheckingAndNestedIndentUseSharedHistory() {
        for (version in listOf(4, 5, 6)) {
            val a = create(version, "list-enter-$version", "a"); val scope = CoroutineScope(SupervisorJob() + Dispatchers.Unconfined)
            val inputs = owner(a, scope); val list = a.node(NodeAddress("list")); val original = a.node(NodeAddress("list", listOf("items", "i")))
            val binding = inputs.bind(original); inputs.attach(binding); inputs.focusChanged(binding, true)
            try {
                binding.update(TextFieldValue("AB", TextRange(1), TextRange(0, 1)))
                val marked = binding.input.value; val before = a.save().export().toString(); var revoked = 0
                rejected { inputs.move({ revoked++ }, original, -1) }
                rejected { inputs.indent({ revoked++ }, original) }
                rejected { inputs.outdent({ revoked++ }, original) }
                assertEquals(0, revoked); assertEquals(before, a.save().export().toString())
                assertEquals(marked, binding.input.value); assertTrue(binding.input.composing)
                inputs.enter(binding, { binding.update(TextFieldValue("AB", TextRange(1))) }, "tail")
                val tail = a.node(NodeAddress("list", listOf("items", "tail")))
                assertEquals("A", text(a, original)); assertEquals("B", text(a, tail))
                assertFalse(writingNodeValue(a, tail).optBoolean("checked"))
                val next = inputs.bind(tail); inputs.attach(next); inputs.consume(checkNotNull(inputs.focusRequest), next); inputs.focusChanged(next, true)
                inputs.checked({}, tail, true)
                assertTrue(writingNodeValue(a, tail).getBoolean("checked"))
                val checkedLease = inputs.bind(tail); inputs.attach(checkedLease); inputs.consume(checkNotNull(inputs.focusRequest), checkedLease); inputs.focusChanged(checkedLease, true)
                inputs.indent({}, tail)
                assertEquals(NodeAddress("list", listOf("items", "i", "children", "tail")), a.nodeAddress(tail))
                val nested = inputs.bind(tail); inputs.attach(nested); inputs.consume(checkNotNull(inputs.focusRequest), nested); inputs.focusChanged(nested, true)
                inputs.outdent({}, tail)
                assertEquals(NodeAddress("list", listOf("items", "tail")), a.nodeAddress(tail))
                assertEquals("item-meta", writingNodeValue(a, original).getString("consumer"))
                assertEquals("todo", writingNodeValue(a, list).getString("style"))
                val reopened = WritingSession.restore(a.save(), "a")
                try { reopened.undo(); assertTrue(reopened.nodeAddress(tail).path.contains("children")); reopened.redo(); assertEquals(a.nodeAddress(tail), reopened.nodeAddress(tail)) }
                finally { reopened.close() }
            } finally { inputs.close(); scope.cancel(); a.close() }
        }
    }

    @Test fun appendUsesPostDrainOrderAndDuplicateDeletePreservePeerSubtrees() {
        for (version in listOf(4, 5, 6)) {
            val a = create(version, "collection-actions-$version", "a"); val b = create(version, "collection-actions-$version", "b")
            val scope = CoroutineScope(SupervisorJob() + Dispatchers.Unconfined); val inputs = owner(a, scope)
            val parent = a.node(NodeAddress("toggle")); val source = a.node(NodeAddress("toggle", listOf("children", "p")))
            val binding = inputs.bind(source); inputs.attach(binding); inputs.focusChanged(binding, true)
            try {
                binding.update(TextFieldValue("A東BTask", TextRange(2), TextRange(1, 2)))
                val peerParent = b.node(NodeAddress("toggle")); val peerSource = b.node(NodeAddress("toggle", listOf("children", "p")))
                b.insertCollectionNodes(JSONArray().put(JSONObject("""{"id":"peer","type":"toggle","summary":[{"type":"text","text":"Peer 😀","marks":[]}],"children":[{"id":"child","type":"paragraph","content":[{"type":"text","text":"東京","marks":[]}],"consumer":"peer-child"}],"consumer":"peer-meta"}""")), NodeCollection.children(peerParent), peerSource)
                a.receive(b.changes())
                inputs.append({ binding.update(TextFieldValue("A東京BTask", TextRange(3))) },
                    { JSONArray().put(JSONObject("""{"id":"local","type":"paragraph","content":[]}""")) }, NodeCollection.children(parent))
                assertEquals(listOf("p", "peer", "local"), a.snapshot.getJSONArray("blocks").getJSONObject(0).getJSONArray("children").let { values -> (0 until values.length()).map { values.getJSONObject(it).getString("id") } })
                val local = a.node(NodeAddress("toggle", listOf("children", "local")))
                val next = inputs.bind(local); inputs.attach(next); inputs.consume(checkNotNull(inputs.focusRequest), next); inputs.focusChanged(next, true)
                inputs.duplicate({}, source)
                val copied = a.collectionNodes(NodeCollection.children(parent))[1]
                assertNotEquals(writingCanonical(source.wire), writingCanonical(copied.wire))
                assertEquals("paragraph-meta", writingNodeValue(a, copied).getString("consumer")); assertEquals("A東京BTask", text(a, copied))
                val copiedBinding = inputs.bind(copied); inputs.attach(copiedBinding); inputs.consume(checkNotNull(inputs.focusRequest), copiedBinding); inputs.focusChanged(copiedBinding, true)
                inputs.delete({}, copied)
                assertTrue(a.snapshot.toString().contains("peer-child")); assertTrue(a.snapshot.toString().contains("peer-meta"))
                val reopened = WritingSession.restore(a.save(), "a")
                try { reopened.undo(); assertEquals("A東京BTask", text(reopened, copied)); reopened.redo(); rejected { reopened.nodeAddress(copied) } }
                finally { reopened.close() }
            } finally { inputs.close(); scope.cancel(); a.close(); b.close() }
        }
    }

    @Test fun summaryCellAndCaptionUseIndependentFieldsAndSoftBreaks() {
        for (version in listOf(4, 5, 6)) {
            val a = create(version, "rich-fields-$version", "a"); val scope = CoroutineScope(SupervisorJob() + Dispatchers.Unconfined)
            val inputs = owner(a, scope)
            try {
                for ((address, field) in listOf(NodeAddress("toggle") to "summary", NodeAddress("table", listOf("rows", "row", "cells", "cell")) to "content", NodeAddress("image") to "caption")) {
                    val identity = a.node(address); val binding = inputs.bind(identity, field); inputs.attach(binding); inputs.focusChanged(binding, true)
                    val original = text(a, identity, field)
                    binding.update(TextFieldValue(original, TextRange(1)))
                    inputs.enter(binding, {}, "unused")
                    assertEquals(original.take(1) + "\n" + original.drop(1), text(a, identity, field))
                    assertEquals(address, a.nodeAddress(identity))
                    val next = inputs.bind(identity, field); inputs.attach(next); inputs.consume(checkNotNull(inputs.focusRequest), next)
                    inputs.focusChanged(next, true); inputs.focusChanged(next, false); inputs.detach(next); inputs.detach(binding)
                }
                assertEquals("https://assets.invalid/inert", writingNodeValue(a, a.node(NodeAddress("image"))).getString("src"))
                assertEquals(1, a.collectionNodes(NodeCollection.rows(a.node(NodeAddress("table")))).size)
            } finally { inputs.close(); scope.cancel(); a.close() }
        }
    }

    @Test fun emptyChecklistExitRetainsPeerChildrenAndRejectsProtectedScalarOverwrite() {
        for (version in listOf(4, 5, 6)) {
            val initial = JSONArray("""[{"id":"list","type":"list","style":"todo","listConsumer":"list-meta","items":[{"id":"i","checked":true,"consumer":"item-meta","content":[],"children":[{"id":"child","content":[{"type":"text","text":"kid","marks":[{"type":"bold"}]},{"type":"entity-ref","entityType":"task","entityId":"t","label":"Task","consumer":"ref-meta"}],"consumer":"child-meta"}]}]}]""")
            fun session(actor: String) = when (version) {
                4 -> WritingSession.createV4("empty-exit-$version", actor, "four", initial)
                5 -> WritingSession.createV5("empty-exit-$version", actor, "five", initial)
                else -> WritingSession.createV6("empty-exit-$version", actor, "six", initial)
            }
            val a = session("a"); val b = session("b")
            val scope = CoroutineScope(SupervisorJob() + Dispatchers.Unconfined); val inputs = owner(a, scope)
            val list = a.node(NodeAddress("list")); val original = a.node(NodeAddress("list", listOf("items", "i")))
            val child = b.node(NodeAddress("list", listOf("items", "i", "children", "child")))
            val binding = inputs.bind(original); inputs.attach(binding); inputs.focusChanged(binding, true)
            try {
                inputs.enter(binding, {}, "unused")
                b.replaceText(b.textAddress(child), 0, 0, "R😀"); a.receive(b.changes()); b.receive(a.changes())
                assertEquals("paragraph", writingNodeValue(a, list).getString("type"))
                assertEquals("item-meta", writingNodeValue(a, list).getString("consumer"))
                assertEquals("list-meta", writingNodeValue(a, list).getString("listConsumer"))
                assertEquals(NodeAddress("list", listOf("children", "child")), a.nodeAddress(child))
                assertEquals("R😀kidTask", text(a, child)); assertTrue(writingNodeValue(a, child).toString().contains("ref-meta"))
                assertEquals(writingCanonical(a.snapshot.getJSONArray("blocks")), writingCanonical(b.snapshot.getJSONArray("blocks")))
                val next = inputs.bind(list); inputs.attach(next); inputs.consume(checkNotNull(inputs.focusRequest), next); inputs.focusChanged(next, true)
                assertTrue(inputs.exportDrafts().isEmpty())
                val before = a.save().export().toString(); val receipts = a.syncState().export().toString()
                rejected { a.setNodeField(list, listOf("id"), "replacement") }
                rejected { a.setNodeField(list, listOf("content"), JSONArray()) }
                rejected { a.setNodeField(list, listOf("children"), JSONArray()) }
                assertEquals(before, a.save().export().toString()); assertEquals(receipts, a.syncState().export().toString())
                val reopened = WritingSession.restore(a.save(), "a")
                try {
                    reopened.undo(); assertEquals("list", writingNodeValue(reopened, list).getString("type"))
                    assertEquals(NodeAddress("list", listOf("items", "i")), reopened.nodeAddress(original))
                    assertEquals(NodeAddress("list", listOf("items", "i", "children", "child")), reopened.nodeAddress(child))
                    assertEquals("R😀kidTask", text(reopened, child)); reopened.redo()
                    assertEquals(writingCanonical(a.snapshot.getJSONArray("blocks")), writingCanonical(reopened.snapshot.getJSONArray("blocks")))
                } finally { reopened.close() }
            } finally { inputs.close(); scope.cancel(); a.close(); b.close() }
        }
    }

    @Test fun duplicatingAbsentSummaryKeepsOptionalFieldInertThroughUndoAndReopen() {
        for (version in listOf(4, 5, 6)) {
            val seed = JSONArray("""[{"id":"toggle","type":"toggle","children":[],"consumer":{"label":"東京😀"}}]""")
            val a = when (version) {
                4 -> WritingSession.createV4("absent-summary-$version", "a", "four", seed)
                5 -> WritingSession.createV5("absent-summary-$version", "a", "five", seed)
                else -> WritingSession.createV6("absent-summary-$version", "a", "six", seed)
            }
            val scope = CoroutineScope(SupervisorJob() + Dispatchers.Unconfined); val inputs = owner(a, scope)
            val origin = a.node(NodeAddress("toggle"))
            try {
                inputs.duplicate({}, origin)
                val roots = a.collectionNodes(NodeCollection.ROOT); assertEquals(2, roots.size)
                val copy = roots[1]; assertNotEquals(writingCanonical(origin.wire), writingCanonical(copy.wire))
                assertFalse(writingNodeValue(a, copy).has("summary")); assertNull(inputs.focusRequest)
                assertEquals("東京😀", writingNodeValue(a, copy).getJSONObject("consumer").getString("label"))
                assertEquals(1, a.changes().export().getJSONArray("changes").length())
                val reopened = WritingSession.restore(a.save(), "a")
                try {
                    reopened.undo(); assertEquals(1, reopened.collectionNodes(NodeCollection.ROOT).size)
                    reopened.redo(); assertEquals(2, reopened.collectionNodes(NodeCollection.ROOT).size)
                    assertFalse(writingNodeValue(reopened, copy).has("summary"))
                    assertEquals(writingCanonical(a.snapshot.getJSONArray("blocks")), writingCanonical(reopened.snapshot.getJSONArray("blocks")))
                } finally { reopened.close() }
            } finally { inputs.close(); scope.cancel(); a.close() }
        }
    }

    @Test fun movedReusedAndRevokedBindingsCannotMutateNestedOrigins() {
        for (version in listOf(4, 5, 6)) {
            val a = create(version, "nested-leases-$version", "a"); val b = create(version, "nested-leases-$version", "b")
            val scope = CoroutineScope(SupervisorJob() + Dispatchers.Unconfined); var editable = true
            val inputs = owner(a, scope) { editable }; val original = a.node(NodeAddress("toggle", listOf("children", "p")))
            val old = inputs.bind(original); inputs.attach(old); inputs.focusChanged(old, true)
            try {
                val peer = b.node(NodeAddress("toggle", listOf("children", "p")))
                b.moveSelection(WritingSelection(nodes = listOf(peer)), NodeCollection.ROOT, b.node(NodeAddress("image")))
                b.insertCollectionNodes(JSONArray().put(JSONObject("""{"id":"p","type":"paragraph","content":[{"type":"text","text":"Replacement","marks":[]}]}""")), NodeCollection.children(b.node(NodeAddress("toggle"))))
                a.receive(b.changes())
                val replacement = a.node(NodeAddress("toggle", listOf("children", "p")))
                assertNotEquals(writingCanonical(original.wire), writingCanonical(replacement.wire))
                val before = a.save().export().toString(); val receipt = a.syncState().export().toString()
                old.update(TextFieldValue("stale")); rejected { inputs.enter(old, {}, "bad") }
                assertEquals(before, a.save().export().toString()); assertEquals(receipt, a.syncState().export().toString())
                val live = inputs.bind(original); inputs.attach(live); inputs.focusChanged(live, true)
                editable = false; rejected { inputs.checked({}, a.node(NodeAddress("list", listOf("items", "i"))), true) }
                assertEquals(before, a.save().export().toString()); editable = true
                a.setAllowedBlockTypes(emptySet()); val limited = a.save().export().toString()
                rejected { inputs.append({}, { JSONArray().put(JSONObject("""{"id":"new","type":"paragraph","content":[]}""")) }, NodeCollection.ROOT) }
                assertEquals(limited, a.save().export().toString()); assertEquals("Replacement", text(a, replacement))
                inputs.close(); rejected { inputs.duplicate({}, original) }
            } finally { inputs.close(); scope.cancel(); a.close(); b.close() }
        }
    }
}
