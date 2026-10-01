package studio.seventwo.blockeditor

import androidx.compose.ui.text.AnnotatedString
import androidx.compose.ui.text.SpanStyle
import androidx.compose.ui.text.buildAnnotatedString
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextDecoration
import org.json.JSONArray

/** Mark presentation uses the same UTF-16 text as the shared engine and input. */
internal fun styledInline(nodes: JSONArray?): AnnotatedString = buildAnnotatedString {
    if (nodes != null) for (index in 0 until nodes.length()) {
        val node = nodes.getJSONObject(index)
        val start = length
        append(plainText(JSONArray().put(node)))
        val marks = node.optJSONArray("marks") ?: JSONArray()
        val types = (0 until marks.length()).map { marks.getJSONObject(it).optString("type") }.toSet()
        val decorations = buildList {
            if ("strikethrough" in types) add(TextDecoration.LineThrough)
            if ("link" in types) add(TextDecoration.Underline)
        }
        if (length > start) addStyle(SpanStyle(
            fontWeight = if ("bold" in types) FontWeight.Bold else null,
            fontStyle = if ("italic" in types) FontStyle.Italic else null,
            fontFamily = if ("code" in types) FontFamily.Monospace else null,
            textDecoration = if (decorations.isEmpty()) null else TextDecoration.combine(decorations),
        ), start, length)
    }
}

internal fun selectionHasMark(nodes: JSONArray?, start: Int, end: Int, type: String): Boolean {
    if (nodes == null || start >= end) return false
    var offset = 0
    var selected = false
    for (index in 0 until nodes.length()) {
        val node = nodes.getJSONObject(index)
        val next = offset + plainText(JSONArray().put(node)).length
        if (offset < end && next > start) {
            selected = true
            val marks = node.optJSONArray("marks") ?: return false
            if (!(0 until marks.length()).any { marks.getJSONObject(it).optString("type") == type }) return false
        }
        offset = next
    }
    return selected
}
