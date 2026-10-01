package studio.seventwo.blockeditor

import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.text.selection.SelectionContainer
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.heading
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.unit.dp
import org.json.JSONArray
import org.json.JSONObject

/** Paths name scoped IDs, never array indices or reconstructed rich JSON. */
@Composable internal fun EditableBlockContent(
    session: EditorSession, rootID: String, block: JSONObject, path: List<String>,
    readOnly: Boolean, canAct: Boolean, report: (Exception) -> Unit,
    composing: (String, Boolean) -> Unit, onAssetRequest: ((NodeAddress, JSONObject) -> Unit)?,
    asset: @Composable (JSONObject) -> Unit,
) {
    val type = block.getString("type")
    if (readOnly && type in listOf("toggle", "table", "list")) {
        ReadOnlyBlockPreview(block, asset)
        return
    }
    @Composable fun field(name: String, label: String, style: androidx.compose.ui.text.TextStyle = MaterialTheme.typography.bodyLarge,
                          modifier: Modifier = Modifier) {
        SessionTextField(session, rootID, path + name, label, readOnly, report, composing, modifier, style)
    }
    when (type) {
        "paragraph" -> field("content", "Block text")
        "heading" -> field("content", "Heading", when (block.optInt("level", 1)) {
            1 -> MaterialTheme.typography.headlineLarge
            2 -> MaterialTheme.typography.headlineMedium
            else -> MaterialTheme.typography.headlineSmall
        }, Modifier.semantics { heading() })
        "quote" -> Row {
            Text("│", modifier = Modifier.padding(end = 8.dp))
            Box(Modifier.weight(1f)) { field("content", "Quote") }
        }
        "callout" -> Surface(color = MaterialTheme.colorScheme.surfaceContainer, shape = MaterialTheme.shapes.small) {
            Box(Modifier.padding(12.dp)) { field("content", "Callout") }
        }
        "code" -> field("code", "Code", MaterialTheme.typography.bodyLarge.copy(fontFamily = FontFamily.Monospace))
        "math" -> field("expression", "Math", MaterialTheme.typography.bodyLarge.copy(fontFamily = FontFamily.Monospace))
        "divider" -> HorizontalDivider()
        "image" -> Column {
            asset(block)
            if (block.has("alt")) field("alt", "Image description")
            if (block.has("caption")) field("caption", "Image caption")
            if (onAssetRequest != null) TextButton(enabled = canAct, onClick = {
                try { onAssetRequest(NodeAddress(rootID, path), JSONObject(block.toString())) } catch (error: Exception) { report(error) }
            }, modifier = Modifier.testTag("editor-asset:$rootID:${path.joinToString("/")}")) { Text("Edit image") }
        }
        "toggle" -> {
            var expanded by remember(session, rootID, path) { mutableStateOf(true) }
            Column {
                Row {
                    TextButton(enabled = canAct || readOnly, onClick = { expanded = !expanded }) {
                        Text(if (expanded) "Collapse toggle" else "Expand toggle")
                    }
                    Box(Modifier.weight(1f)) { field("summary", "Toggle summary") }
                }
                if (expanded) {
                    val children = block.optJSONArray("children") ?: JSONArray()
                    Column(Modifier.padding(start = 16.dp)) {
                        for (index in 0 until children.length()) {
                            val child = children.getJSONObject(index)
                            val childPath = path + listOf("children", child.getString("id"))
                            key(child.getString("id")) {
                                EditableBlockContent(session, rootID, child, childPath, readOnly, canAct, report, composing, onAssetRequest, asset)
                                ScopedActions(session, rootID, childPath, children, index, canAct, report)
                            }
                        }
                    }
                }
            }
        }
        "table" -> Column(Modifier.horizontalScroll(rememberScrollState())) {
            val rows = block.optJSONArray("rows") ?: JSONArray()
            for (rowIndex in 0 until rows.length()) {
                val row = rows.getJSONObject(rowIndex)
                val cells = row.getJSONArray("cells")
                key(row.getString("id")) {
                    Row {
                        for (cellIndex in 0 until cells.length()) {
                            val cell = cells.getJSONObject(cellIndex)
                            key(cell.getString("id")) {
                                SessionTextField(session, rootID,
                                    path + listOf("rows", row.getString("id"), "cells", cell.getString("id"), "content"),
                                    "Row ${rowIndex + 1} cell ${cellIndex + 1}", readOnly, report, composing,
                                    Modifier.width(200.dp).padding(4.dp),
                                    if (cell.optBoolean("header")) MaterialTheme.typography.titleMedium else MaterialTheme.typography.bodyLarge)
                            }
                        }
                    }
                }
            }
        }
        "list" -> EditableListItems(session, rootID, block.optJSONArray("items") ?: JSONArray(), path + "items",
            block.optString("style"), readOnly, canAct, report, composing)
        "embed" -> SelectionContainer { Text(block.optString("title", block.optString("url", "Embedded content"))) }
        else -> SelectionContainer { Text("$type content preserved") }
    }
}

@Composable private fun EditableListItems(session: EditorSession, rootID: String, items: JSONArray, path: List<String>,
                                         style: String, readOnly: Boolean, canAct: Boolean, report: (Exception) -> Unit,
                                         composing: (String, Boolean) -> Unit) {
    for (index in 0 until items.length()) {
        val item = items.getJSONObject(index)
        val itemPath = path + item.getString("id")
        key(item.getString("id")) {
            Column {
                Row {
                    if (style == "todo") Checkbox(item.optBoolean("checked"), enabled = canAct,
                        onCheckedChange = { checked ->
                            try { session.edit("setField", JSONObject().put("blockID", rootID).put("path", JSONArray(itemPath + "checked")).put("value", checked)) }
                            catch (error: Exception) { report(error) }
                        }, modifier = Modifier.testTag("editor-check:$rootID:${itemPath.joinToString("/")}")
                            .semantics { contentDescription = "Complete ${plainText(item.optJSONArray("content")).ifEmpty { "checklist item" }}" })
                    else Text(if (style == "ordered") "${index + 1}. " else "• ", Modifier.padding(top = 16.dp))
                    Box(Modifier.weight(1f)) {
                        SessionTextField(session, rootID, itemPath + "content", if (style == "todo") "Checklist item" else "List item",
                            readOnly, report, composing)
                    }
                }
                ScopedActions(session, rootID, itemPath, items, index, canAct, report, listItem = true)
                val children = item.optJSONArray("children") ?: JSONArray()
                if (children.length() > 0) Column(Modifier.padding(start = 16.dp)) {
                    EditableListItems(session, rootID, children, itemPath + "children", style, readOnly, canAct, report, composing)
                }
            }
        }
    }
}

@Composable private fun ScopedActions(session: EditorSession, rootID: String, path: List<String>, siblings: JSONArray,
                                     index: Int, enabled: Boolean, report: (Exception) -> Unit, listItem: Boolean = false) {
    // Scoped structural controls are available only in the structural collaboration epoch.
    val supported = remember(session) { session.syncState().optInt("version", 1) >= 2 }
    if (!supported) return
    fun identity() = session.node(NodeAddress(rootID, path))
    fun collection(): NodeCollection {
        val owner = session.node(NodeAddress(rootID, path.dropLast(2)))
        return when (path[path.size - 2]) {
            "items" -> NodeCollection.items(owner)
            else -> NodeCollection.children(owner)
        }
    }
    BlockActions(rootID, path, enabled, index, siblings.length(), report,
        move = { destination ->
            val afterIndex = if (destination > index) destination else destination - 1
            val after = if (afterIndex < 0) null else session.node(NodeAddress(rootID, path.dropLast(1) + siblings.getJSONObject(afterIndex).getString("id")))
            session.moveNode(identity(), collection(), after)
        }, delete = { session.deleteNode(identity()) },
        indent = if (listItem) ({ session.indent(identity()) }) else null,
        outdent = if (listItem && path[path.size - 2] == "children") ({ session.outdent(identity()) }) else null)
}
