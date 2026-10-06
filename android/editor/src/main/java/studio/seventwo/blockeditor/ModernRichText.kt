package studio.seventwo.blockeditor

import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.AnnotatedString
import androidx.compose.ui.text.SpanStyle
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextDecoration
import androidx.compose.ui.text.input.OffsetMapping
import androidx.compose.ui.text.input.TransformedText
import androidx.compose.ui.text.input.VisualTransformation
import org.json.JSONArray

/** Presentation only. Original UTF-16 offsets and atomic reference labels stay
 * aligned with the shared engine; edits still pass its checked atom boundaries. */
internal class ModernRichTransformation(private val inline: JSONArray) : VisualTransformation {
    override fun filter(text: AnnotatedString): TransformedText {
        val display = AnnotatedString.Builder(text); var offset = 0
        for (index in 0 until inline.length()) {
            val node = inline.getJSONObject(index)
            val visible = if (node.optString("type") == "text") node.optString("text") else node.optString("label", node.optString("date", node.optString("expression", node.optString("name"))))
            val end = (offset + visible.length).coerceAtMost(text.length)
            if (offset < end) {
                if (node.optString("type") != "text") display.addStyle(SpanStyle(color = Color(0xff315c8b), background = Color(0xffe9eef4)), offset, end)
                val marks = node.optJSONArray("marks") ?: JSONArray()
                for (markIndex in 0 until marks.length()) {
                    val mark = marks.getJSONObject(markIndex)
                    val style = when (mark.optString("type")) {
                        "bold" -> SpanStyle(fontWeight = FontWeight.Bold)
                        "italic" -> SpanStyle(fontStyle = FontStyle.Italic)
                        "strikethrough" -> SpanStyle(textDecoration = TextDecoration.LineThrough)
                        "code" -> SpanStyle(fontFamily = FontFamily.Monospace, background = Color(0xffeeeeec))
                        "link" -> SpanStyle(color = Color(0xff315c8b), textDecoration = TextDecoration.Underline)
                        "semantic-color" -> SpanStyle(color = modernRoleColor(mark.optString("value")))
                        "semantic-background" -> SpanStyle(background = modernRoleColor(mark.optString("value")).copy(alpha = .15f))
                        else -> SpanStyle()
                    }
                    display.addStyle(style, offset, end)
                }
            }
            offset = end
        }
        return TransformedText(display.toAnnotatedString(), OffsetMapping.Identity)
    }
}
internal fun modernRoleColor(role: String): Color = Color(when (role) {
    "green" -> 0xff35664e; "blue" -> 0xff315c8b; "purple" -> 0xff6c4d87; "amber" -> 0xff805f28; "red" -> 0xff8e4440; else -> 0xff252724
})
