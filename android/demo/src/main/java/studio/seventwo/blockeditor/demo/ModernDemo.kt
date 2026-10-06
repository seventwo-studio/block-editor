package studio.seventwo.blockeditor.demo

import androidx.compose.foundation.layout.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.unit.dp
import kotlinx.coroutines.launch
import kotlinx.coroutines.CompletableDeferred
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import org.json.JSONArray
import org.json.JSONObject
import studio.seventwo.blockeditor.*
import java.io.File
import java.util.UUID

/** No relay service is needed for local protocol-7 editing and paired reopen. */
@Composable fun ModernDemo() {
    val context = LocalContext.current; val scope = rememberCoroutineScope()
    var asset by remember { mutableStateOf<Pair<String, CompletableDeferred<ModernPayload>>?>(null) }
    var previewURL by remember { mutableStateOf("") }
    val picker = rememberLauncherForActivityResult(ActivityResultContracts.OpenDocument()) { uri ->
        val original = asset ?: return@rememberLauncherForActivityResult
        if (uri == null) { original.second.completeExceptionally(kotlinx.coroutines.CancellationException("Asset selection cancelled")); asset = null }
        else scope.launch { try { original.second.complete(storeModernAsset(context, uri, original.first)) } catch (failure: Throwable) { original.second.completeExceptionally(failure) } finally { if (asset === original) asset = null } }
    }
    suspend fun chooseAsset(kind: String): ModernPayload {
        check(asset == null) { "Asset picker busy" }; val pending = CompletableDeferred<ModernPayload>(); asset = kind to pending
        if (kind != "embed") picker.launch(arrayOf(if (kind == "image") "image/*" else "*/*"))
        return pending.await()
    }
    val store = remember { ModernHostStore(File(context.filesDir, "modern-help.json")) }
    var state by remember { mutableStateOf<ModernBlockEditorState?>(null) }
    var status by remember { mutableStateOf("Opening modern editor…") }
    var failure by remember { mutableStateOf<String?>(null) }
    var resume by remember { mutableStateOf<(() -> Unit)?>(null) }
    var retry by remember { mutableIntStateOf(0) }
    LaunchedEffect(retry) {
        try {
            val pair = store.load()
            val host = if (pair != null) ModernAndroidHost.restore(pair, store).let { resume = it.second; it.first } else {
                val document = ModernDocument.restore(JSONObject().put("format", "seventwo.block-editor.document").put("formatVersion", 1)
                    .put("documentID", "modern-help-example").put("title", "Help")
                    .put("appearance", JSONObject().put("fontFamily", "sans").put("fontSize", "default").put("pageWidth", "readable"))
                    .put("blocks", JSONArray().put(JSONObject().put("id", "welcome").put("type", "paragraph").put("content", JSONArray()))))
                ModernAndroidHost(ModernSession.create(document, "reference-author", UUID.randomUUID().toString()), "reference-author", store)
            }
            state = ModernBlockEditorState(host) { failure = it.toString() }; failure = null; status = "Local modern editor"
        } catch (error: Throwable) { failure = error.toString() }
    }
    DisposableEffect(state) { val current = state; onDispose { current?.host?.setActive(false); asset?.second?.completeExceptionally(kotlinx.coroutines.CancellationException("Document closed")); asset = null } }
    Column(Modifier.fillMaxSize()) {
        Row(Modifier.fillMaxWidth().padding(8.dp)) {
            Text(status, Modifier.weight(1f))
            state?.let { editor -> TextButton(onClick = { scope.launch { try { editor.host.save(); status = "Saved with author history and recovery" } catch (error: Throwable) { failure = error.toString() } } }) { Text("Save locally") } }
            resume?.let { release -> TextButton(onClick = { try { release(); resume = null } catch (error: Throwable) { failure = error.toString() } }) { Text("Resume saved packets") } }
        }
        state?.let { editor -> ModernBlockEditor(editor, Modifier.weight(1f), openReference = { target -> status = "Application navigation: $target" },
            resolveMedia = { _, value -> resolveModernAsset(context, value) },
            replaceMedia = { target -> chooseAsset(target.export().getJSONObject("origin").getString("kind")) },
            suggestLinks = { query -> listOf(ModernLinkSuggestion("getting-started", "help", "Getting started")).filter { it.label.contains(query, true) || query.isEmpty() } },
            insertAssetSelection = { descriptor, boundary, range -> scope.launch {
                try {
                    val metadata = chooseAsset(descriptor.blockType).export()
                    check(editor.host.active && !editor.host.readOnly) { "Original document inactive" }
                    metadata.put("id", UUID.randomUUID().toString()).put("type", descriptor.blockType)
                    if (descriptor.blockType == "image") metadata.put("caption", JSONArray())
                    val payload = editor.session.clipboardParts(JSONArray().put(JSONObject().put("node", JSONObject().put("kind", "block").put("value", metadata))))
                    val target = range?.let { ModernPasteTarget.Range(it) } ?: ModernPasteTarget.Boundary(boundary)
                    editor.execute(ModernCommand.Paste(target, payload, policy = ModernPastePolicy(allowAssetMetadata = true))); editor.host.save()
                } catch (error: Throwable) { failure = error.toString() }
            } }
        ) }
        asset?.takeIf { it.first == "embed" }?.let { request -> AlertDialog(onDismissRequest = { request.second.completeExceptionally(kotlinx.coroutines.CancellationException()); asset = null },
            title = { Text("Application preview") }, text = { TextField(value = previewURL, onValueChange = { previewURL = it }, label = { Text("URL") }) },
            confirmButton = { TextButton(onClick = { request.second.complete(ModernPayload.restore(JSONObject().put("url", previewURL).put("title", previewURL))); asset = null }) { Text("Use preview") } },
            dismissButton = { TextButton(onClick = { request.second.completeExceptionally(kotlinx.coroutines.CancellationException()); asset = null }) { Text("Cancel") } }) }
        failure?.let { Text("Could not complete the editor action: $it"); if (state == null) TextButton(onClick = { retry++ }) { Text("Retry opening") } }
    }
}
