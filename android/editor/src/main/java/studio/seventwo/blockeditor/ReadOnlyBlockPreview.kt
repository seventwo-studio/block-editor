package studio.seventwo.blockeditor

import androidx.compose.foundation.layout.*
import androidx.compose.foundation.text.selection.SelectionContainer
import androidx.compose.material3.*
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import org.json.JSONObject

/** Render existing nested content; creation/restructuring remains shared-command work. */
@Composable internal fun ReadOnlyBlockPreview(block: JSONObject, asset: @Composable (JSONObject) -> Unit) {
    Column(Modifier.fillMaxWidth()) {
        when (block.optString("type")) {
            "toggle" -> {
                SelectionContainer { Text(plainText(block.optJSONArray("summary")), style = MaterialTheme.typography.titleMedium) }
                val children = block.optJSONArray("children")
                Column(Modifier.padding(start = 16.dp)) {
                    if (children != null) for (index in 0 until children.length()) ReadOnlyBlockPreview(children.getJSONObject(index), asset)
                }
            }
            "table" -> {
                val rows = block.optJSONArray("rows")
                if (rows != null) for (index in 0 until rows.length()) Row(Modifier.fillMaxWidth()) {
                    val cells = rows.getJSONObject(index).getJSONArray("cells")
                    for (cell in 0 until cells.length()) SelectionContainer(Modifier.weight(1f).padding(4.dp)) {
                        Text(plainText(cells.getJSONObject(cell).optJSONArray("content")))
                    }
                }
            }
            "list" -> ReadOnlyItems(block, block.optString("style"))
            "image" -> asset(block)
            "divider" -> HorizontalDivider()
            "code" -> SelectionContainer { Text(block.optString("code")) }
            "math" -> SelectionContainer { Text(block.optString("expression")) }
            else -> SelectionContainer { Text(plainText(block.optJSONArray("content"))) }
        }
    }
}

@Composable private fun ReadOnlyItems(owner: JSONObject, style: String, field: String = "items") {
    val items = owner.optJSONArray(field) ?: return
    for (index in 0 until items.length()) {
        val item = items.getJSONObject(index)
        Row {
            if (style == "todo") Checkbox(checked = item.optBoolean("checked"), onCheckedChange = {}, enabled = false)
            else Text(if (style == "ordered") "${index + 1}. " else "• ")
            Column(Modifier.weight(1f)) {
                SelectionContainer { Text(plainText(item.optJSONArray("content"))) }
                Column(Modifier.padding(start = 16.dp)) { ReadOnlyItems(item, style, "children") }
            }
        }
    }
}
