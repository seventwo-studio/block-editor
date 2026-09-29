package studio.seventwo.blockeditor

import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import org.json.JSONArray
import org.json.JSONObject
import java.util.UUID

/** Basic native session surface; the host supplies asset rendering and handles storage. */
@Composable fun BlockEditor(session: EditorSession, modifier: Modifier = Modifier,
                            asset: @Composable (JSONObject) -> Unit = { Text(it.optString("alt", "Image")) }) {
    var error by remember(session) { mutableStateOf<String?>(null) }
    fun perform(action: () -> Unit) { try { action(); error = null } catch (e: Exception) { error = e.message } }
    val array = session.snapshot.getJSONArray("blocks")
    val blocks = (0 until array.length()).map { array.getJSONObject(it) }
    Column(modifier) {
        Row {
            TextButton(enabled = session.snapshot.getBoolean("canUndo"), onClick = { perform { session.undo() } }) { Text("Undo") }
            TextButton(enabled = session.snapshot.getBoolean("canRedo"), onClick = { perform { session.redo() } }) { Text("Redo") }
            TextButton(onClick = { perform {
                session.edit("insert", JSONObject().put("after", blocks.lastOrNull()?.getString("id"))
                    .put("block", JSONObject().put("id", UUID.randomUUID().toString()).put("type", "paragraph").put("content", JSONArray())))
            } }) { Text("Paragraph") }
        }
        error?.let { Text(it, color = MaterialTheme.colorScheme.error) }
        LazyColumn {
            items(blocks, key = { it.getString("id") }) { block ->
                Column(Modifier.fillMaxWidth().padding(8.dp)) {
                    val id = block.getString("id")
                    when (block.getString("type")) {
                        "paragraph", "heading", "quote", "callout" -> OutlinedTextField(
                            value = plainText(block.optJSONArray("content")),
                            onValueChange = { text -> perform { session.setText(id, text) } },
                            modifier = Modifier.fillMaxWidth(), label = { Text("Block text") })
                        "image" -> asset(block)
                        "divider" -> HorizontalDivider()
                        "code" -> Text(block.optString("code"))
                        "math" -> Text(block.optString("expression"))
                        else -> Text("${block.getString("type")} content preserved")
                    }
                    Row {
                        val index = blocks.indexOf(block)
                        TextButton(enabled = index > 0, onClick = { perform {
                            session.edit("move", JSONObject().put("blockID", id).put("after", if (index > 1) blocks[index - 2].getString("id") else JSONObject.NULL))
                        } }) { Text("Move up") }
                        TextButton(onClick = { perform { session.edit("delete", JSONObject().put("blockID", id)) } }) { Text("Delete") }
                    }
                }
            }
        }
    }
}

private fun plainText(nodes: JSONArray?): String = if (nodes == null) "" else (0 until nodes.length()).joinToString("") {
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
