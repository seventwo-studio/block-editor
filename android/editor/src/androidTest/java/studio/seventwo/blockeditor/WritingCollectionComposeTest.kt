package studio.seventwo.blockeditor

import android.view.inputmethod.EditorInfo
import android.view.inputmethod.InputConnection
import androidx.activity.ComponentActivity
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.SideEffect
import androidx.compose.runtime.mutableStateOf
import androidx.compose.ui.ExperimentalComposeUiApi
import androidx.compose.ui.platform.InterceptPlatformTextInput
import androidx.compose.ui.platform.PlatformTextInputInterceptor
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.Modifier
import androidx.compose.ui.semantics.SemanticsActions
import androidx.compose.ui.semantics.SemanticsProperties
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.createAndroidComposeRule
import androidx.compose.ui.text.TextRange
import kotlinx.coroutines.awaitCancellation
import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test

/** Rendered collection controls and actual Compose InputConnection, not installed keyboard acceptance. */
@OptIn(ExperimentalComposeUiApi::class, ExperimentalTestApi::class)
class WritingCollectionComposeTest {
    @get:Rule val compose = createAndroidComposeRule<ComponentActivity>()
    private fun field(identity: NodeIdentity) = compose.onNodeWithTag("writing-text:${identity.wire}")
    private fun text(session: WritingSession, identity: NodeIdentity) = plainText(writingNodeValue(session, identity).getJSONArray("content"))

    @Test fun renderedNestedEnterFinalizesCompositionAndRetainsPostSplitTyping() {
        val seed = JSONArray("""[{"id":"toggle","type":"toggle","summary":[],"children":[{"id":"p","type":"paragraph","consumer":"owner-meta","content":[{"type":"text","text":"AB","marks":[{"type":"bold"}]},{"type":"entity-ref","entityType":"task","entityId":"t","label":"Task","consumer":"ref-meta"}]}]}]""")
        lateinit var a: WritingSession; lateinit var b: WritingSession; lateinit var original: NodeIdentity
        var connection: InputConnection? = null
        val visible = mutableStateOf(true)
        val interceptor = PlatformTextInputInterceptor { request, _ ->
            val native = request.createInputConnection(EditorInfo()); connection = native
            try { awaitCancellation() } finally { native.closeConnection(); if (connection === native) connection = null }
        }
        compose.runOnUiThread {
            a = WritingSession.createV6("compose-nested-enter", "a", "six", seed)
            b = WritingSession.createV6("compose-nested-enter", "b", "six", seed)
            original = a.node(NodeAddress("toggle", listOf("children", "p")))
        }
        try {
            compose.setContent { InterceptPlatformTextInput(interceptor) { MaterialTheme {
                val state = rememberWritingBlockEditorState(a, { assertTrue(it.isEmpty()) }, { throw it })
                if (visible.value) WritingBlockEditor(state)
            } } }
            field(original).performScrollTo().performClick().performTextInputSelection(TextRange(1))
            compose.waitUntil { connection != null }
            compose.runOnIdle { assertTrue(checkNotNull(connection).setComposingText("東京", 1)) }
            compose.runOnIdle {
                val peer = b.node(NodeAddress("toggle", listOf("children", "p")))
                b.replaceText(b.textAddress(peer), 6, 6, "R"); a.receive(b.changes())
                assertEquals("ABTask", text(a, original)); assertEquals(1, a.exportDeferredChanges().size)
            }
            val staleEnter = checkNotNull(compose.onNodeWithTag("writing-enter").fetchSemanticsNode().config[SemanticsActions.OnClick].action)
            compose.onNodeWithTag("writing-enter").performScrollTo().performClick()
            val tail = compose.runOnIdle {
                assertEquals("A東京", text(a, original)); assertTrue(a.exportDeferredChanges().isEmpty())
                a.collectionNodes(NodeCollection.children(a.node(NodeAddress("toggle"))))[1]
            }
            val focused = compose.onNode(hasSetTextAction() and isFocused())
            focused.assertTextContains("BTaskR")
            assertEquals(TextRange(0), focused.fetchSemanticsNode().config[SemanticsProperties.TextSelectionRange])
            focused.performTextInput("X😀")
            compose.runOnIdle {
                assertEquals("X😀BTaskR", text(a, tail)); assertTrue(writingNodeValue(a, tail).toString().contains("ref-meta"))
                val before = a.save().export().toString(); staleEnter(); assertEquals(before, a.save().export().toString())
                val reopened = WritingSession.restore(a.save(), "a")
                try {
                    reopened.undo(); assertEquals("BTaskR", text(reopened, tail))
                    reopened.undo(); assertEquals("A東京BTaskR", text(reopened, original))
                    reopened.redo(); reopened.redo(); assertEquals("X😀BTaskR", text(reopened, tail))
                } finally { reopened.close() }
            }
        } finally { compose.runOnIdle { visible.value = false }; compose.waitForIdle(); compose.runOnIdle { a.close(); b.close() } }
    }

    @Test fun renderedChecklistContinuationCheckboxAndRetainedReadOnlyAction() {
        val seed = JSONArray("""[{"id":"list","type":"list","style":"todo","consumer":"list-meta","items":[{"id":"i","checked":false,"content":[{"type":"text","text":"AB","marks":[{"type":"italic"}]}],"children":[]}]}]""")
        lateinit var a: WritingSession; lateinit var original: NodeIdentity
        val visible = mutableStateOf(true); val readOnly = mutableStateOf(false)
        var connection: InputConnection? = null
        lateinit var state: WritingBlockEditorState
        val interceptor = PlatformTextInputInterceptor { request, _ ->
            val native = request.createInputConnection(EditorInfo()); connection = native
            try { awaitCancellation() } finally { native.closeConnection(); if (connection === native) connection = null }
        }
        compose.runOnUiThread { a = WritingSession.createV5("compose-list-enter", "a", "five", seed); original = a.node(NodeAddress("list", listOf("items", "i"))) }
        try {
            compose.setContent { InterceptPlatformTextInput(interceptor) { MaterialTheme {
                state = rememberWritingBlockEditorState(a, { assertTrue(it.isEmpty()) }, { throw it })
                SideEffect { state.readOnly = readOnly.value }
                if (visible.value) WritingBlockEditor(state)
            } } }
            field(original).performScrollTo().performClick().performTextInputSelection(TextRange(1))
            compose.waitUntil { connection != null }
            compose.runOnIdle { assertTrue(checkNotNull(connection).setComposingText("東", 1)) }
            val origin = writingCanonical(original.wire)
            compose.onNodeWithTag("writing-up:$origin").assertIsNotEnabled()
            compose.onNodeWithTag("writing-down:$origin").assertIsNotEnabled()
            compose.onNodeWithTag("writing-indent:$origin").assertIsNotEnabled()
            compose.onNodeWithTag("writing-outdent:$origin").assertIsNotEnabled()
            val disabled = checkNotNull(compose.onNodeWithTag("writing-indent:$origin").fetchSemanticsNode().config[SemanticsActions.OnClick].action)
            compose.runOnIdle {
                val before = a.save().export().toString(); val draft = state.pendingDrafts().single()
                disabled(); assertEquals(before, a.save().export().toString())
                assertEquals(draft.text, state.pendingDrafts().single().text)
                assertTrue(checkNotNull(connection).setComposingText("", 1)); assertTrue(checkNotNull(connection).finishComposingText())
            }
            compose.onNodeWithTag("writing-enter").performScrollTo().performClick()
            val tail = compose.runOnIdle { val nodes = a.collectionNodes(NodeCollection.items(a.node(NodeAddress("list")))); assertEquals(2, nodes.size); nodes[1] }
            compose.onNode(hasSetTextAction() and isFocused()).assertTextContains("B")
            val tag = "writing-check:${writingCanonical(tail.wire)}"
            compose.onNodeWithTag(tag).assertContentDescriptionEquals("B")
            val stale = checkNotNull(compose.onNodeWithTag(tag).fetchSemanticsNode().config[SemanticsActions.OnClick].action)
            compose.onNodeWithTag(tag).performScrollTo().performClick()
            compose.onNodeWithTag(tag).assertContentDescriptionEquals("B")
            compose.runOnIdle { assertTrue(writingNodeValue(a, tail).getBoolean("checked")); readOnly.value = true }
            compose.waitForIdle()
            compose.runOnIdle { val before = a.save().export().toString(); stale(); assertEquals(before, a.save().export().toString()) }
            compose.onNodeWithTag(tag).assertIsNotEnabled()
            compose.runOnIdle {
                val reopened = WritingSession.restore(a.save(), "a")
                try { reopened.undo(); assertFalse(writingNodeValue(reopened, tail).getBoolean("checked")); reopened.undo(); assertEquals("AB", text(reopened, original)); reopened.redo(); reopened.redo(); assertTrue(writingNodeValue(reopened, tail).getBoolean("checked")) }
                finally { reopened.close() }
            }
        } finally { compose.runOnIdle { visible.value = false }; compose.waitForIdle(); compose.runOnIdle { a.close() } }
    }

    @Test fun disposedChecklistAndDeleteCallbacksStayRevokedAfterOriginReturns() {
        val seed = JSONArray("""[{"id":"left","type":"list","style":"todo","items":[{"id":"i","checked":false,"consumer":"keep","content":[{"type":"text","text":"東京😀","marks":[]}],"children":[]},{"id":"j","checked":false,"content":[],"children":[]}]},{"id":"right","type":"list","style":"todo","items":[{"id":"k","checked":false,"content":[],"children":[]}]}]""")
        lateinit var a: WritingSession; lateinit var b: WritingSession; lateinit var original: NodeIdentity
        val visible = mutableStateOf(true)
        val interceptor = PlatformTextInputInterceptor { request, _ -> val native = request.createInputConnection(EditorInfo()); try { awaitCancellation() } finally { native.closeConnection() } }
        compose.runOnUiThread {
            a = WritingSession.createV6("compose-disposed-controls", "a", "six", seed)
            b = WritingSession.createV6("compose-disposed-controls", "b", "six", seed)
            original = a.node(NodeAddress("left", listOf("items", "i")))
        }
        try {
            compose.setContent { InterceptPlatformTextInput(interceptor) { MaterialTheme {
                val state = rememberWritingBlockEditorState(a, { assertTrue(it.isEmpty()) }, { throw it })
                if (visible.value) WritingBlockEditor(state)
            } } }
            val key = writingCanonical(original.wire)
            val oldCheck = checkNotNull(compose.onNodeWithTag("writing-check:$key").fetchSemanticsNode().config[SemanticsActions.OnClick].action)
            val oldDelete = checkNotNull(compose.onNodeWithTag("writing-delete:$key").fetchSemanticsNode().config[SemanticsActions.OnClick].action)
            compose.runOnIdle {
                b.moveSelection(WritingSelection(nodes = listOf(original)), NodeCollection.items(b.node(NodeAddress("right"))))
                a.receive(b.changes())
            }
            compose.waitForIdle() // Old left/items/i composition has been disposed.
            compose.runOnIdle { assertEquals(NodeAddress("right", listOf("items", "i")), a.nodeAddress(original)) }
            compose.runOnIdle {
                b.moveSelection(WritingSelection(nodes = listOf(original)), NodeCollection.items(b.node(NodeAddress("left"))))
                a.receive(b.changes())
            }
            compose.waitForIdle()
            compose.runOnIdle {
                assertEquals(NodeAddress("left", listOf("items", "i")), a.nodeAddress(original))
                val before = a.save().export().toString(); val receipts = a.syncState().export().toString()
                oldCheck(); oldDelete()
                assertEquals(before, a.save().export().toString()); assertEquals(receipts, a.syncState().export().toString())
                assertFalse(writingNodeValue(a, original).getBoolean("checked"))
            }
            compose.onNodeWithTag("writing-check:$key").performScrollTo().performClick()
            compose.runOnIdle { assertTrue(writingNodeValue(a, original).getBoolean("checked")); assertEquals("keep", writingNodeValue(a, original).getString("consumer")) }
            compose.onNodeWithTag("writing-delete:$key").performScrollTo().performClick()
            compose.runOnIdle {
                assertFalse(a.collectionNodes(NodeCollection.items(a.node(NodeAddress("left")))).any { writingCanonical(it.wire) == key })
                val reopened = WritingSession.restore(a.save(), "a")
                try { reopened.undo(); assertEquals("東京😀", text(reopened, original)); assertTrue(writingNodeValue(reopened, original).getBoolean("checked")); reopened.undo(); assertFalse(writingNodeValue(reopened, original).getBoolean("checked")) }
                finally { reopened.close() }
            }
        } finally { compose.runOnIdle { visible.value = false }; compose.waitForIdle(); compose.runOnIdle { a.close(); b.close() } }
    }

    @Test fun renderedTableInsertionAndAssetCallbackKeepSharedMetadataInert() {
        val seed = JSONArray("""[{"id":"table","type":"table","consumer":"table-meta","rows":[{"id":"r","cells":[{"id":"c","content":[{"type":"text","text":"Cell","marks":[]}],"consumer":"cell-meta"}]}]},{"id":"image","type":"image","src":"https://assets.invalid/inert","consumer":{"asset":"keep"}}]""")
        lateinit var a: WritingSession; lateinit var table: NodeIdentity
        val visible = mutableStateOf(true)
        val interceptor = PlatformTextInputInterceptor { request, _ -> val native = request.createInputConnection(EditorInfo()); try { awaitCancellation() } finally { native.closeConnection() } }
        compose.runOnUiThread { a = WritingSession.createV4("compose-table-assets", "a", "four", seed); table = a.node(NodeAddress("table")) }
        try {
            compose.setContent { InterceptPlatformTextInput(interceptor) { MaterialTheme {
                val state = rememberWritingBlockEditorState(a, { assertTrue(it.isEmpty()) }, { throw it })
                if (visible.value) WritingBlockEditor(state, renderAsset = { metadata ->
                    metadata.getJSONObject("consumer").put("asset", "renderer-local")
                    Text(metadata.getString("src"), Modifier.testTag("inert-host-asset"))
                })
            } } }
            val row = compose.runOnIdle { a.collectionNodes(NodeCollection.rows(table)).first() }
            compose.onNodeWithTag("writing-add-cell:${writingCanonical(row.wire)}").performScrollTo().performClick()
            compose.runOnIdle { assertEquals(2, a.collectionNodes(NodeCollection.cells(row)).size); assertEquals("cell-meta", writingNodeValue(a, a.node(NodeAddress("table", listOf("rows", "r", "cells", "c")))).getString("consumer")) }
            compose.onNodeWithTag("inert-host-asset").performScrollTo().assertTextEquals("https://assets.invalid/inert")
            compose.runOnIdle {
                assertEquals("keep", writingNodeValue(a, a.node(NodeAddress("image"))).getJSONObject("consumer").getString("asset"))
                assertFalse(writingNodeValue(a, a.node(NodeAddress("image"))).has("caption"))
                val reopened = WritingSession.restore(a.save(), "a")
                try { reopened.undo(); assertEquals(1, reopened.collectionNodes(NodeCollection.cells(row)).size); reopened.redo(); assertEquals(2, reopened.collectionNodes(NodeCollection.cells(row)).size) }
                finally { reopened.close() }
            }
        } finally { compose.runOnIdle { visible.value = false }; compose.waitForIdle(); compose.runOnIdle { a.close() } }
    }
}
