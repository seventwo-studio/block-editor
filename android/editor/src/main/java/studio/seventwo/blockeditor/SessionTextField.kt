package studio.seventwo.blockeditor

import androidx.compose.foundation.focusGroup
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.focus.onFocusChanged
import androidx.compose.ui.input.key.*
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.input.OffsetMapping
import androidx.compose.ui.text.input.TransformedText
import androidx.compose.ui.text.input.VisualTransformation
import org.json.JSONArray
import org.json.JSONObject
import java.net.URI
import java.util.Locale

@Composable internal fun SessionTextField(
    session: EditorSession, blockID: String, path: List<String>, label: String, readOnly: Boolean,
    reportError: (Exception) -> Unit, composing: (String, Boolean) -> Unit,
    modifier: Modifier = Modifier, textStyle: TextStyle = MaterialTheme.typography.bodyLarge,
) {
    val currentError by rememberUpdatedState(reportError)
    val compositionChanged by rememberUpdatedState(composing)
    val input = remember(session, blockID, path) { CollaborativeTextInput(session, blockID, path) { currentError(it) } }
    val inputKey = "$blockID:${path.joinToString("/")}"
    var focused by remember(input) { mutableStateOf(false) }
    val focus = remember(input) { FocusRequester() }
    var linkRange by remember(input) { mutableStateOf<Pair<JSONObject, JSONObject>?>(null) }
    var linkURL by remember(input) { mutableStateOf("") }
    var linkError by remember(input) { mutableStateOf<String?>(null) }
    DisposableEffect(input) { onDispose { input.close(); compositionChanged(inputKey, false) } }
    SideEffect { compositionChanged(inputKey, input.value.composition != null) }
    val nodes = fieldValue(session.snapshot, blockID, path) as? JSONArray
    val formattable = nodes != null
    fun format(markType: String) {
        if (readOnly || input.value.composition != null || input.value.selection.collapsed || !formattable) return
        try {
            val selection = input.value.selection
            val active = selectionHasMark(nodes, selection.min, selection.max, markType)
            session.edit("format", JSONObject().put("address", NodeAddress(blockID, path).wire())
                .put("start", selection.min).put("end", selection.max).put("markType", markType)
                .put("mark", if (active) JSONObject.NULL else JSONObject().put("type", markType)))
            focus.requestFocus()
        } catch (error: Exception) { currentError(error) }
    }
    Column(modifier.onFocusChanged { focused = it.hasFocus }.focusGroup()) {
        OutlinedTextField(value = input.value, onValueChange = input::update, readOnly = readOnly,
            modifier = Modifier.fillMaxWidth().focusRequester(focus)
                .testTag("editor-text:$inputKey").semantics { contentDescription = label }
                .onPreviewKeyEvent { event ->
                    if (event.type != KeyEventType.KeyDown || !(event.isCtrlPressed || event.isMetaPressed) || event.isAltPressed) false
                    else when (event.key) {
                        Key.B -> { format("bold"); !readOnly && formattable && !input.value.selection.collapsed && input.value.composition == null }
                        Key.I -> { format("italic"); !readOnly && formattable && !input.value.selection.collapsed && input.value.composition == null }
                        else -> false
                    }
                },
            label = { Text(label) }, textStyle = textStyle,
            visualTransformation = VisualTransformation { text ->
                // Composition has no shared marks yet; never alter text or UTF-16 offsets.
                TransformedText(if (input.value.composition == null && plainText(nodes) == text.text) styledInline(nodes) else text, OffsetMapping.Identity)
            })
        if (focused && !readOnly && formattable && !input.value.selection.collapsed && input.value.composition == null) {
            Row(Modifier.horizontalScroll(rememberScrollState())) {
                for ((title, type) in listOf("Bold" to "bold", "Italic" to "italic", "Strike" to "strikethrough", "Code" to "code")) {
                    TextButton(onClick = { format(type) }, modifier = Modifier.testTag("editor-format:$inputKey:$type")
                        .semantics { contentDescription = "Toggle $title for selection" }) { Text(title) }
                }
                TextButton(onClick = {
                    try {
                        val selection = input.value.selection
                        linkRange = session.position(blockID, selection.min, path) to session.position(blockID, selection.max, path)
                        linkURL = ""; linkError = null
                    } catch (error: Exception) { currentError(error) }
                }) { Text("Link") }
            }
            linkRange?.let { range ->
                OutlinedTextField(linkURL, { linkURL = it; linkError = null }, label = { Text("Link URL") },
                    isError = linkError != null, modifier = Modifier.fillMaxWidth().onPreviewKeyEvent { event ->
                        if (event.type == KeyEventType.KeyDown && event.key == Key.Escape) {
                            linkRange = null; focus.requestFocus(); true
                        } else false
                    })
                linkError?.let { Text(it, color = MaterialTheme.colorScheme.error) }
                Row {
                    fun applyLink(remove: Boolean) {
                        try {
                            val mark = if (remove) JSONObject.NULL else {
                                val href = linkURL.trim()
                                val uri = URI(href)
                                val scheme = uri.scheme?.lowercase(Locale.ROOT)
                                require(scheme in setOf("http", "https", "mailto") &&
                                    (if (scheme == "mailto") !uri.schemeSpecificPart.isNullOrBlank() else !uri.host.isNullOrBlank())) {
                                    "Use an http, https or mailto link"
                                }
                                JSONObject().put("type", "link").put("href", href)
                            }
                            val start = session.resolvePosition(range.first)
                            val end = session.resolvePosition(range.second)
                            check(start < end) { "Select text again before applying a link" }
                            session.edit("format", JSONObject().put("address", NodeAddress(blockID, path).wire())
                                .put("start", start).put("end", end).put("markType", "link").put("mark", mark))
                            linkRange = null; focus.requestFocus()
                        } catch (error: Exception) { linkError = error.message; currentError(error) }
                    }
                    TextButton(onClick = { applyLink(false) }) { Text("Apply link") }
                    TextButton(onClick = { applyLink(true) }) { Text("Remove link") }
                    TextButton(onClick = { linkRange = null; focus.requestFocus() }) { Text("Cancel") }
                }
            }
        }
    }
}

internal fun fieldValue(snapshot: JSONObject, blockID: String, path: List<String>): Any? {
    val blocks = snapshot.getJSONArray("blocks")
    var field: Any? = (0 until blocks.length()).map { blocks.getJSONObject(it) }.find { it.optString("id") == blockID }
    for (part in path) field = when (val parent = field) {
        is JSONObject -> parent.opt(part)
        is JSONArray -> (0 until parent.length()).mapNotNull { parent.optJSONObject(it) }.find { it.optString("id") == part }
        else -> null
    }
    return field
}
