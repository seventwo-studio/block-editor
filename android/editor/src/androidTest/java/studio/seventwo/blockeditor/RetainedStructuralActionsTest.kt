package studio.seventwo.blockeditor

import androidx.activity.ComponentActivity
import androidx.compose.material3.MaterialTheme
import androidx.compose.runtime.mutableStateOf
import androidx.compose.ui.semantics.SemanticsActions
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.createAndroidComposeRule
import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Rule
import org.junit.Test

/** Exercise actual retained rendered actions before and after their source view changes. */
@OptIn(ExperimentalTestApi::class)
class RetainedStructuralActionsTest {
    @get:Rule val compose = createAndroidComposeRule<ComponentActivity>()

    @Test fun retainedParagraphRespectsReadOnly() = checkReadOnly("Paragraph")
    @Test fun retainedUndoRespectsReadOnly() = checkReadOnly("Undo")
    @Test fun retainedDeleteRespectsReadOnly() = checkReadOnly("Delete")

    private fun checkReadOnly(title: String) {
        lateinit var session: EditorSession
        val readOnly = mutableStateOf(false)
        compose.runOnUiThread {
            session = EditorSession.create("readonly-structure-$title", "local", JSONArray("""[
                {"id":"p","type":"paragraph","content":[{"type":"text","text":"Original","marks":[]}]}
            ]"""), collaborationVersion = 2)
            session.setText("p", "Original!")
        }
        try {
            compose.setContent { MaterialTheme { BlockEditor(session, readOnly = readOnly.value) } }
            if (title == "Delete") compose.onNodeWithTag("editor-actions:p:").performClick()
            val action = checkNotNull(compose.onNodeWithText(title, substring = false)
                .fetchSemanticsNode().config[SemanticsActions.OnClick].action)
            lateinit var before: String
            compose.runOnIdle { before = session.save().toString(); readOnly.value = true }
            compose.waitForIdle()
            compose.runOnIdle {
                action()
                assertEquals("Read-only $title callback must preserve document and complete history", before, session.save().toString())
            }
        } finally { compose.runOnIdle { session.close() } }
    }

    @Test fun retainedNestedDeleteRejectsMovedAndReusedOrigin() = checkOrigin("nested-delete")
    @Test fun retainedRootDeleteRejectsDeletedAndReusedOrigin() = checkOrigin("root-delete")
    @Test fun retainedImageRequestRejectsMovedAndReusedOrigin() = checkOrigin("image")
    @Test fun retainedChecklistRejectsMovedAndReusedOrigin() = checkOrigin("checklist")

    private fun checkOrigin(kind: String) {
        lateinit var local: EditorSession
        lateinit var remote: EditorSession
        var assetRequests = 0
        var movedOrigin: NodeIdentity? = null
        var insertedReplacement: NodeIdentity? = null
        var originalCollection: NodeCollection? = null
        val original = if (kind == "image")
            JSONObject("""{"id":"p","type":"image","src":"content://original","alt":"Original","caption":[]}""")
        else JSONObject("""{"id":"p","type":"paragraph","content":[{"type":"text","text":"Original","marks":[{"type":"bold"}]}]}""")
        val blocks = when (kind) {
            "root-delete" -> JSONArray().put(original)
            "checklist" -> JSONArray("""[
                {"id":"a","type":"list","style":"todo","items":[{"id":"p","checked":false,"content":[{"type":"text","text":"Original","marks":[]}],"children":[]}]},
                {"id":"b","type":"list","style":"todo","items":[]}
            ]""")
            else -> JSONArray().put(JSONObject().put("id", "a").put("type", "toggle").put("summary", JSONArray())
                .put("children", JSONArray().put(original)))
                .put(JSONObject().put("id", "b").put("type", "toggle").put("summary", JSONArray()).put("children", JSONArray()))
        }
        compose.runOnUiThread {
            local = EditorSession.create("retained-structure-$kind", "local", blocks, collaborationVersion = 2)
            remote = EditorSession.create("retained-structure-$kind", "remote", blocks, collaborationVersion = 2)
        }
        try {
            compose.setContent { MaterialTheme {
                BlockEditor(local, readOnly = false, onAssetRequest = { _, _ -> assetRequests++ })
            } }
            val tag = when (kind) {
                "root-delete" -> "editor-actions:p:"
                "nested-delete" -> "editor-actions:a:children/p"
                "image" -> "editor-asset:a:children/p"
                else -> "editor-check:a:items/p"
            }
            val node = compose.onNodeWithTag(tag)
            node.performScrollTo()
            val action = if (kind.endsWith("delete")) {
                node.performClick()
                checkNotNull(compose.onNodeWithText("Delete", substring = false).fetchSemanticsNode()
                    .config[SemanticsActions.OnClick].action)
            } else checkNotNull(node.fetchSemanticsNode().config[SemanticsActions.OnClick].action)
            lateinit var before: String
            fun invokeAndCheck(phase: String) {
                action()
                assertEquals("Retained $kind $phase must preserve all origins and author history", before, local.save().toString())
                assertEquals("Retained image action must never ask the host to resolve a replacement", 0, assetRequests)
            }
            compose.runOnIdle {
                if (kind == "root-delete") {
                    val origin = remote.node(NodeAddress("p"))
                    remote.deleteNode(origin)
                    remote.insertNode(JSONObject(original.toString()).put("content", JSONArray("""[{"type":"text","text":"Replacement","marks":[]}]""")), NodeCollection.ROOT)
                } else {
                    val field = if (kind == "checklist") "items" else "children"
                    val origin = remote.node(NodeAddress("a", listOf(field, "p")))
                    val destination = remote.node(NodeAddress("b"))
                    val owner = remote.node(NodeAddress("a"))
                    val destinationCollection = if (kind == "checklist") NodeCollection.items(destination) else NodeCollection.children(destination)
                    val sourceCollection = if (kind == "checklist") NodeCollection.items(owner) else NodeCollection.children(owner)
                    movedOrigin = origin; originalCollection = sourceCollection
                    remote.moveNode(origin, destinationCollection)
                    val replacement = if (kind == "checklist") JSONObject("""{"id":"p","checked":false,"content":[{"type":"text","text":"Replacement","marks":[]}],"children":[]}""")
                        else JSONObject(original.toString()).also {
                            if (kind == "image") it.put("src", "content://replacement").put("alt", "Replacement")
                            else it.put("content", JSONArray("""[{"type":"text","text":"Replacement","marks":[]}]"""))
                        }
                    insertedReplacement = remote.insertNode(replacement, sourceCollection)
                }
                local.receive(remote.changes())
                before = local.save().toString()
                invokeAndCheck("before Compose detach")
            }
            compose.waitForIdle()
            compose.runOnIdle { invokeAndCheck("after Compose detach") }
            if (kind != "root-delete") {
                // Returning the old origin must not reactivate its retired view's lease.
                compose.runOnIdle {
                    remote.deleteNode(checkNotNull(insertedReplacement))
                    remote.moveNode(checkNotNull(movedOrigin), checkNotNull(originalCollection))
                    local.receive(remote.changes()); before = local.save().toString()
                    invokeAndCheck("after origin returns, before Compose")
                }
                compose.waitForIdle()
                compose.runOnIdle { invokeAndCheck("after origin returns and Compose") }
                if (kind == "image") {
                    compose.onNodeWithTag(tag).performScrollTo().performClick()
                    compose.runOnIdle { assertEquals("Fresh live asset action remains available", 1, assetRequests) }
                } else if (kind == "checklist") {
                    compose.onNodeWithTag(tag).performScrollTo().performClick()
                    compose.runOnIdle {
                        assertEquals(true, local.snapshot.getJSONArray("blocks").getJSONObject(0).getJSONArray("items").getJSONObject(0).getBoolean("checked"))
                    }
                }
            }
        } finally { compose.runOnIdle { local.close(); remote.close() } }
    }
    @Test fun disabledFirstNestedMoveDoesNotAddAuthorHistory() = checkMove(false)
    @Test fun retainedMoveRejectsRemoteSiblingReorder() = checkMove(true)

    private fun checkMove(reorder: Boolean) {
        lateinit var local: EditorSession
        lateinit var remote: EditorSession
        val blocks = JSONArray("""[
            {"id":"a","type":"toggle","summary":[],"children":[
                {"id":"p","type":"paragraph","content":[{"type":"text","text":"First","marks":[]}]},
                {"id":"q","type":"paragraph","content":[{"type":"text","text":"Second","marks":[]}]}
            ]}
        ]""")
        compose.runOnUiThread {
            local = EditorSession.create("retained-move-$reorder", "local", blocks, collaborationVersion = 2)
            remote = EditorSession.create("retained-move-$reorder", "remote", blocks, collaborationVersion = 2)
        }
        try {
            compose.setContent { MaterialTheme { BlockEditor(local) } }
            compose.onNodeWithTag("editor-actions:a:children/p").performScrollTo().performClick()
            val button = compose.onNodeWithText(if (reorder) "Move down" else "Move up", substring = false)
            if (!reorder) button.assertIsNotEnabled()
            val action = checkNotNull(button.fetchSemanticsNode().config[SemanticsActions.OnClick].action)
            lateinit var before: String
            compose.runOnIdle {
                if (reorder) {
                    remote.moveNode(remote.node(NodeAddress("a", listOf("children", "p"))),
                        NodeCollection.children(remote.node(NodeAddress("a"))), remote.node(NodeAddress("a", listOf("children", "q"))))
                    local.receive(remote.changes())
                }
                before = local.save().toString(); action()
                assertEquals("Disabled or obsolete movement must preserve full author history", before, local.save().toString())
            }
            compose.waitForIdle()
            compose.runOnIdle { action(); assertEquals(before, local.save().toString()) }
        } finally { compose.runOnIdle { local.close(); remote.close() } }
    }

}
