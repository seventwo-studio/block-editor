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
    val inputs = LocalEditorInputs.current
    val address = NodeAddress(blockID, path)
    val identity = remember(session, session.snapshot, blockID, path) {
        if (session.syncState().optInt("version", 1) >= 2) session.node(NodeAddress(blockID, path.dropLast(1))) else null
    }
    val originKey = inputs.key(identity, address)
    key(originKey) {
        val currentError by rememberUpdatedState(reportError)
        val currentReadOnly by rememberUpdatedState(readOnly)
        val compositionChanged by rememberUpdatedState(composing)
        val inputKey = "$blockID:${path.joinToString("/")}"
        val bindingRevision = inputs.bindingRevision(originKey)
        val binding = remember(inputs, originKey, inputKey, bindingRevision) { inputs.bind(originKey, identity, address) }
        val input = binding.input
        var focused by remember(input) { mutableStateOf(false) }
        val focus = remember(input) { FocusRequester() }
        var linkRange by remember(input) { mutableStateOf<Pair<JSONObject, JSONObject>?>(null) }
        var linkURL by remember(input) { mutableStateOf("") }
        var linkError by remember(input) { mutableStateOf<String?>(null) }
        DisposableEffect(binding) {
            inputs.attach(binding)
            onDispose { inputs.detach(binding); compositionChanged(inputKey, false) }
        }
        val request = inputs.focusRequest
        LaunchedEffect(input, request) {
            if (request?.first == originKey && binding.current()) {
                focus.requestFocus()
                inputs.consumedFocus(request)
            }
        }
        SideEffect { compositionChanged(inputKey, input.requiresCommit) }
        val nodes = fieldValue(session.snapshot, blockID, path) as? JSONArray
        val formattable = nodes != null
        fun authoringAddress(): NodeAddress? {
            if (!binding.current() || currentReadOnly || input.requiresCommit) return null
            val live = input.liveAddress() ?: return null
            // Reject the old view even before Compose has detached it after a move.
            if (live != address || fieldValue(session.snapshot, live.blockID, live.path) !is JSONArray) return null
            return live
        }
        fun format(markType: String) {
            val target = authoringAddress() ?: return
            if (input.value.selection.collapsed) return
            try {
                val selection = input.value.selection
                val currentNodes = fieldValue(session.snapshot, target.blockID, target.path) as? JSONArray
                val active = selectionHasMark(currentNodes, selection.min, selection.max, markType)
                session.edit("format", JSONObject().put("address", target.wire())
                    .put("start", selection.min).put("end", selection.max).put("markType", markType)
                    .put("mark", if (active) JSONObject.NULL else JSONObject().put("type", markType)))
                focus.requestFocus()
            } catch (error: Exception) { currentError(error) }
        }
        Column(modifier.onFocusChanged { focused = it.hasFocus }.focusGroup()) {
            // Revoke the actual Foundation input node as well as its callback.
            // A retained semantics/InputConnection node reads its latest callback;
            // reusing that node would silently attach the old native lease again.
            key(bindingRevision) {
                OutlinedTextField(value = input.value, onValueChange = { value ->
                    if (currentReadOnly) binding.select(value) else binding.update(value)
                }, readOnly = readOnly,
                modifier = Modifier.fillMaxWidth().focusRequester(focus).onFocusChanged { inputs.focusChanged(binding, it.isFocused) }
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
            }
            if (focused && !readOnly && formattable && !input.value.selection.collapsed && input.value.composition == null) {
                Row(Modifier.horizontalScroll(rememberScrollState())) {
                    for ((title, type) in listOf("Bold" to "bold", "Italic" to "italic", "Strike" to "strikethrough", "Code" to "code")) {
                        TextButton(onClick = { format(type) }, modifier = Modifier.testTag("editor-format:$inputKey:$type")
                            .semantics { contentDescription = "Toggle $title for selection" }) { Text(title) }
                    }
                    TextButton(onClick = {
                        val target = authoringAddress() ?: return@TextButton
                        if (input.value.selection.collapsed) return@TextButton
                        try {
                            val selection = input.value.selection
                            linkRange = session.position(target.blockID, selection.min, target.path) to session.position(target.blockID, selection.max, target.path)
                            linkURL = ""; linkError = null
                        } catch (error: Exception) { currentError(error) }
                    }) { Text("Link") }
                }
            }
            // The captured range owns this edit until it is applied or cancelled.
            // Moving focus to its URL field must not depend on the live text selection.
            if (!readOnly && formattable && input.value.composition == null) {
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
                            val target = authoringAddress() ?: return
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
                                session.edit("format", JSONObject().put("address", target.wire())
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
