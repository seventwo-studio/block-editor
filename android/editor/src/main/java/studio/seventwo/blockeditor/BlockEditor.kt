package studio.seventwo.blockeditor

import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.liveRegion
import androidx.compose.ui.semantics.LiveRegionMode
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.unit.dp
import org.json.JSONArray
import org.json.JSONObject
import java.util.UUID

/** Native authoring surface; the host supplies assets, permissions and storage. */
@Composable fun BlockEditor(session: EditorSession, modifier: Modifier = Modifier,
                            asset: @Composable (JSONObject) -> Unit = { Text(it.optString("alt", "Image")) }) {
    EditorSurface(session, modifier, false, {}, null, null, asset)
}

/** Read-only content remains selectable; hosts can surface recovery after failed edits. */
@Composable fun BlockEditor(session: EditorSession, modifier: Modifier = Modifier, readOnly: Boolean,
                            onError: (Exception) -> Unit = {},
                            asset: @Composable (JSONObject) -> Unit = { Text(it.optString("alt", "Image")) }) {
    EditorSurface(session, modifier, readOnly, onError, null, null, asset)
}

/** Hosts resolve a picked asset and apply its metadata through shared commands. */
@Composable fun BlockEditor(session: EditorSession, modifier: Modifier = Modifier, readOnly: Boolean,
                            onAssetRequest: (NodeAddress, JSONObject) -> Unit,
                            onAssetInsertRequest: (() -> Unit)? = null,
                            onError: (Exception) -> Unit = {},
                            asset: @Composable (JSONObject) -> Unit = { Text(it.optString("alt", "Image")) }) {
    EditorSurface(session, modifier, readOnly, onError, onAssetRequest, onAssetInsertRequest, asset)
}

@Composable private fun EditorSurface(session: EditorSession, modifier: Modifier, readOnly: Boolean,
                                     onError: (Exception) -> Unit,
                                     onAssetRequest: ((NodeAddress, JSONObject) -> Unit)?,
                                     onAssetInsertRequest: (() -> Unit)?,
                                     asset: @Composable (JSONObject) -> Unit) {
    var error by remember(session) { mutableStateOf<String?>(null) }
    val composing = remember(session) { mutableStateMapOf<String, Boolean>() }
    fun report(e: Exception) { error = e.message; onError(e) }
    fun perform(action: () -> Unit) { try { action(); error = null } catch (e: Exception) { report(e) } }
    val array = session.snapshot.getJSONArray("blocks")
    val blocks = (0 until array.length()).map { array.getJSONObject(it) }
    val canAct = !readOnly && composing.isEmpty()
    Column(modifier) {
        Row {
            TextButton(enabled = canAct && session.snapshot.getBoolean("canUndo"), onClick = { perform { session.undo() } }) { Text("Undo") }
            TextButton(enabled = canAct && session.snapshot.getBoolean("canRedo"), onClick = { perform { session.redo() } }) { Text("Redo") }
            TextButton(enabled = canAct, onClick = { perform {
                session.edit("insert", JSONObject().put("after", blocks.lastOrNull()?.getString("id") ?: JSONObject.NULL)
                    .put("block", JSONObject().put("id", UUID.randomUUID().toString()).put("type", "paragraph").put("content", JSONArray())))
            } }) { Text("Paragraph") }
            onAssetInsertRequest?.let { request ->
                TextButton(enabled = canAct, onClick = { perform(request) }) { Text("Image") }
            }
        }
        error?.let { Text(it, color = MaterialTheme.colorScheme.error,
            modifier = Modifier.semantics { liveRegion = LiveRegionMode.Polite }) }
        LazyColumn(Modifier.weight(1f)) {
            items(blocks, key = { it.getString("id") }) { block ->
                val id = block.getString("id")
                Column(Modifier.fillMaxWidth().padding(8.dp)) {
                    EditableBlockContent(session, id, block, emptyList(), readOnly, canAct,
                        ::report, { key, active -> if (active) composing[key] = true else composing.remove(key) }, onAssetRequest, asset)
                    BlockActions(id, emptyList(), canAct, blocks.indexOf(block), blocks.size, ::report,
                        move = { destination ->
                            val after = if (destination == 0) JSONObject.NULL else blocks[if (destination > blocks.indexOf(block)) destination else destination - 1].getString("id")
                            session.edit("move", JSONObject().put("blockID", id).put("after", after))
                        }, delete = { session.edit("delete", JSONObject().put("blockID", id)) })
                }
            }
        }
    }
}

/** One menu gives touch, keyboard and accessibility users the same commands. */
@Composable internal fun BlockActions(blockID: String, path: List<String>, enabled: Boolean,
                                     index: Int, count: Int, report: (Exception) -> Unit,
                                     move: (Int) -> Unit, delete: () -> Unit,
                                     indent: (() -> Unit)? = null, outdent: (() -> Unit)? = null) {
    var expanded by remember(blockID, path) { mutableStateOf(false) }
    LaunchedEffect(enabled) { if (!enabled) expanded = false }
    fun perform(action: () -> Unit) { expanded = false; try { action() } catch (error: Exception) { report(error) } }
    Box {
        TextButton(enabled = enabled, onClick = { expanded = true },
            modifier = Modifier.testTag("editor-actions:$blockID:${path.joinToString("/")}")
                .semantics { contentDescription = if (path.isEmpty()) "Block actions" else "Nested item actions" }) { Text("⋯") }
        DropdownMenu(expanded && enabled, onDismissRequest = { expanded = false }) {
            DropdownMenuItem(text = { Text("Move up") }, enabled = index > 0, onClick = { perform { move(index - 1) } })
            DropdownMenuItem(text = { Text("Move down") }, enabled = index < count - 1, onClick = { perform { move(index + 1) } })
            indent?.let { DropdownMenuItem(text = { Text("Indent") }, enabled = index > 0, onClick = { perform(it) }) }
            outdent?.let { DropdownMenuItem(text = { Text("Outdent") }, onClick = { perform(it) }) }
            DropdownMenuItem(text = { Text("Delete") }, onClick = { perform(delete) })
        }
    }
}

internal fun plainText(nodes: JSONArray?): String = if (nodes == null) "" else (0 until nodes.length()).joinToString("") {
    val node = nodes.getJSONObject(it)
    when (node.optString("type")) {
        "text" -> node.optString("text")
        "mention", "entity-ref" -> node.optString("label")
        "date" -> node.optString("date")
        "emoji" -> ":${node.optString("name")}:"
        "inline-math" -> node.optString("expression")
        else -> ""
    }
}
