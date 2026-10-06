package studio.seventwo.blockeditor

import android.graphics.Bitmap
import androidx.compose.foundation.Image
import androidx.compose.foundation.layout.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.unit.dp
import kotlinx.coroutines.launch
import org.json.JSONObject
import org.json.JSONArray

/** The host resolves admitted references after its own authorization checks. */
sealed class ModernMediaPresentation {
    data class Available(val label: String, val bitmap: Bitmap? = null) : ModernMediaPresentation()
    data class Denied(val reason: String) : ModernMediaPresentation()
    data class Offline(val reason: String) : ModernMediaPresentation()
    data class Unavailable(val reason: String) : ModernMediaPresentation()
}
data class ModernLinkSuggestion(val id: String, val type: String, val label: String, val availability: String = "available")

@Composable internal fun ModernMediaView(state: ModernBlockEditorState, node: ModernNodeID, value: JSONObject, open: ((String) -> Unit)?) {
    var presentation by remember(node.export().toString()) { mutableStateOf<ModernMediaPresentation?>(null) }
    var retry by remember { mutableIntStateOf(0) }
    var preview by remember { mutableStateOf<Float?>(null) }
    var captured by remember { mutableStateOf<ModernMediaTarget?>(null) }
    val scope = rememberCoroutineScope(); val source = value.optString("src", value.optString("url"))
    LaunchedEffect(source, retry) {
        presentation = null
        try { presentation = state.resolveMedia?.invoke(node, ModernPayload.restore(value)) ?: ModernMediaPresentation.Unavailable("Application resolution required") }
        catch (failure: kotlinx.coroutines.CancellationException) { throw failure }
        catch (failure: Throwable) { presentation = ModernMediaPresentation.Unavailable(failure.toString()) }
    }
    Column {
        when (val result = presentation) {
            null -> Text("Resolving attachment…")
            is ModernMediaPresentation.Available -> if (value.optString("type") == "image" && result.bitmap != null) {
                Image(result.bitmap.asImageBitmap(), value.optString("alt", result.label), Modifier.widthIn(max = (preview ?: value.optDouble("width", 320.0).toFloat()).dp).fillMaxWidth())
            } else TextButton(onClick = { open?.invoke(source) }) { Text(result.label) }
            is ModernMediaPresentation.Denied -> Text("Access denied: ${result.reason}")
            is ModernMediaPresentation.Offline -> Text("Offline: ${result.reason}")
            is ModernMediaPresentation.Unavailable -> Text("${value.optString("alt", value.optString("name", source))}: ${result.reason}")
        }
        TextButton(enabled = state.resolveMedia != null, onClick = { retry++ }) { Text("Retry resolution") }
        if (value.optString("type") == "image") {
            val oldWidth = value.optDouble("width", 320.0).coerceAtLeast(1.0); val oldHeight = value.optDouble("height", oldWidth)
            Slider(enabled = !state.host.readOnly, value = preview ?: oldWidth.toFloat().coerceIn(64f, 960f), valueRange = 64f..960f,
                onValueChange = { if (captured == null) captured = state.session.captureMediaTarget(node); preview = it },
                onValueChangeFinished = { val target = captured; val width = preview; captured = null; preview = null
                    if (target != null && width != null) state.execute(ModernCommand.MediaProperties(target, ModernPayload.restore(modernObject("width" to width.toInt(), "height" to (oldHeight * width / oldWidth).toInt().coerceAtLeast(1)))))
                })
        }
        state.replaceMedia?.let { provider -> TextButton(enabled = !state.host.readOnly && state.host.active, onClick = { scope.launch {
            try { state.host.runProvider(node, provider) } catch (failure: Throwable) { state.reportError(failure) }
        } }) { Text("Replace attachment") } }
        state.host.providerRecords.filter { it.target.export().getJSONObject("origin").getJSONObject("node").toString() == node.export().toString() && it.status != "applied" }.forEach { record ->
            Text(record.reason ?: record.status)
            if (record.result != null) TextButton(enabled = !state.host.readOnly, onClick = { scope.launch { try { state.host.retryResult(record.target) } catch (failure: Throwable) { state.reportError(failure) } } }) { Text("Retry retained result") }
        }
    }
}

@Composable internal fun ModernLinkPicker(state: ModernBlockEditorState, range: ModernTextRange) {
    var suggestions by remember(range.export().toString()) { mutableStateOf<List<ModernLinkSuggestion>>(emptyList()) }
    var failure by remember { mutableStateOf<String?>(null) }
    var loading by remember { mutableStateOf(false) }
    LaunchedEffect(state.linkURL, state.internalLink) {
        if (!state.internalLink) return@LaunchedEffect
        loading = true; failure = null
        try { suggestions = state.suggestLinks?.invoke(state.linkURL) ?: emptyList() }
        catch (error: kotlinx.coroutines.CancellationException) { throw error }
        catch (error: Throwable) { failure = error.toString() }
        finally { loading = false }
    }
    fun cancel() { state.linkTarget = null; state.focus = range.end }
    AlertDialog(onDismissRequest = ::cancel, title = { Text(if (state.internalLink) "Find internal link" else "Link") }, text = {
        Column {
            TextField(value = state.linkURL, onValueChange = { state.linkURL = it }, label = { Text(if (state.internalLink) "Search references" else "URL") })
            if (loading) Text("Searching…")
            failure?.let { Text(it) }
            if (state.internalLink) suggestions.forEach { suggestion -> TextButton(enabled = suggestion.availability == "available", onClick = {
                val content = JSONArray().put(modernObject("type" to "entity-ref", "entityId" to suggestion.id, "entityType" to suggestion.type, "label" to suggestion.label))
                val payload = state.session.clipboardParts(JSONArray().put(modernObject("inline" to modernObject("_0" to content))))
                state.execute(ModernCommand.Paste(ModernPasteTarget.Range(range), payload)); cancel()
            }) { Text("${suggestion.label}${if (suggestion.availability == "available") "" else " — ${suggestion.availability}"}") } }
        }
    }, confirmButton = { if (!state.internalLink) Column {
        TextButton(onClick = { state.execute(ModernCommand.SetLink(range, state.linkURL)); cancel() }) { Text("Apply") }
        TextButton(enabled = state.suggestLinks != null, onClick = { state.internalLink = true }) { Text("Find internal link") }
        TextButton(onClick = { state.execute(ModernCommand.SetLink(range, null)); cancel() }) { Text("Remove link") }
    } }, dismissButton = { TextButton(onClick = ::cancel) { Text("Cancel") } })
}
