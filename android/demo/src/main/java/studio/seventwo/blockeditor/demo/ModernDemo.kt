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
import java.security.MessageDigest
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.rememberScrollState

/** Development launch configuration; production authorization belongs to the app. */
data class ModernRelayDemoConfiguration(val endpoint: String, val key: String, val documentID: String, val actorID: String, val token: String)

/** No relay service is needed for local protocol-7 editing and paired reopen. */
@Composable fun ModernDemo(relayConfiguration: ModernRelayDemoConfiguration? = null) {
    val context = LocalContext.current; val scope = rememberCoroutineScope()
    var asset by remember { mutableStateOf<Pair<String, CompletableDeferred<ModernPayload>>?>(null) }
    var allowPlainLink by remember { mutableStateOf(false) }
    var previewURL by remember { mutableStateOf("") }
    val picker = rememberLauncherForActivityResult(ActivityResultContracts.OpenDocument()) { uri ->
        val original = asset ?: return@rememberLauncherForActivityResult
        if (uri == null) { original.second.completeExceptionally(kotlinx.coroutines.CancellationException("Asset selection cancelled")); asset = null }
        else scope.launch { try { original.second.complete(storeModernAsset(context, uri, original.first)) } catch (failure: Throwable) { original.second.completeExceptionally(failure) } finally { if (asset === original) asset = null } }
    }
    suspend fun chooseAsset(kind: String, plainLink: Boolean = false): ModernPayload {
        check(asset == null) { "Asset picker busy" }; val pending = CompletableDeferred<ModernPayload>(); asset = kind to pending
        allowPlainLink = plainLink
        if (kind != "embed") picker.launch(arrayOf(if (kind == "image") "image/*" else "*/*"))
        return pending.await()
    }
    val store = remember(relayConfiguration?.key, relayConfiguration?.documentID, relayConfiguration?.actorID) {
        val file = relayConfiguration?.let { config ->
            val identity = JSONArray(listOf(config.key, config.documentID, config.actorID)).toString().toByteArray(Charsets.UTF_8)
            "modern-relay-${MessageDigest.getInstance("SHA-256").digest(identity).joinToString("") { "%02x".format(it) }}.json"
        } ?: "modern-help.json"
        ModernHostStore(File(context.filesDir, file))
    }
    var relay by remember { mutableStateOf<ModernAndroidRelay?>(null) }
    var exported by remember { mutableStateOf<File?>(null) }
    var state by remember { mutableStateOf<ModernBlockEditorState?>(null) }
    var status by remember { mutableStateOf("Opening modern editor…") }
    var failure by remember { mutableStateOf<String?>(null) }
    var resume by remember { mutableStateOf<(() -> Unit)?>(null) }
    var retry by remember { mutableIntStateOf(0) }
    LaunchedEffect(retry) {
        try {
            val connection = relayConfiguration?.let { config -> ModernAndroidRelay.open(store, config.documentID, config.actorID, config.endpoint, config.key, config.token) }
            relay = connection
            val pair = if (connection == null) store.load() else null
            val host = connection?.host ?: if (pair != null) ModernAndroidHost.restore(pair, store).let { resume = it.second; it.first } else {
                val document = ModernDocument.restore(JSONObject().put("format", "seventwo.block-editor.document").put("formatVersion", 1)
                    .put("documentID", "modern-help-example").put("title", "Help")
                    .put("appearance", JSONObject().put("fontFamily", "sans").put("fontSize", "default").put("pageWidth", "readable"))
                    .put("blocks", JSONArray().put(JSONObject().put("id", "welcome").put("type", "paragraph").put("content", JSONArray()))))
                ModernAndroidHost(ModernSession.create(document, "reference-author", UUID.randomUUID().toString()), "reference-author", store)
            }
            if (connection != null) resume = connection.resumeDeferred
            state = ModernBlockEditorState(host) { failure = it.toString() }; failure = null; status = "Local modern editor"
        } catch (error: Throwable) { failure = error.toString() }
    }
    DisposableEffect(state) { val current = state; val currentRelay = relay; onDispose { current?.host?.setActive(false); currentRelay?.close(); asset?.second?.completeExceptionally(kotlinx.coroutines.CancellationException("Document closed")); asset = null } }
    Column(Modifier.fillMaxSize()) {
        Row(Modifier.fillMaxWidth().horizontalScroll(rememberScrollState()).padding(8.dp)) {
            Text(status)
            state?.let { editor -> TextButton(onClick = { scope.launch { try { editor.host.save(); status = "Saved with author history and recovery" } catch (error: Throwable) { failure = error.toString() } } }) { Text("Save locally") } }
            resume?.let { release -> TextButton(onClick = { try { release(); resume = null } catch (error: Throwable) { failure = error.toString() } }) { Text("Resume saved packets") } }
            relay?.let { connection ->
                Text("${connection.pendingChanges} pending · ${connection.peers.size} peers")
                Switch(checked = connection.connected, onCheckedChange = connection::setConnected)
                TextButton(enabled = !connection.exchanging, onClick = { scope.launch {
                    try { connection.exchange(); status = "Synchronization completed"; failure = null } catch (error: Throwable) { failure = error.toString() }
                } }) { Text("Synchronize") }
            }
        }
        relay?.let { connection -> Row(Modifier.fillMaxWidth().horizontalScroll(rememberScrollState())) {
            if (connection.host.session.snapshot.recovery != null) TextButton(onClick = { scope.launch { try {
                val changes = connection.host.session.changes(connection.receipt).export().getJSONArray("changes")
                val targets = (0 until changes.length()).map { changes.getJSONObject(it) }.filter {
                    it.getJSONObject("id").getString("actor") == connection.host.actorID && it.getJSONObject("body").has("edit")
                }.map { it.getJSONObject("id").let { id -> ModernChangeID(id.getString("actor"), id.getLong("counter")) } }
                connection.host.session.repairUndo(targets); connection.host.save(); failure = null
            } catch (error: Throwable) { failure = error.toString() } } }) { Text("Undo my rejected changes") }
            TextButton(onClick = { scope.launch { try {
                connection.host.save()
                val directory = File(context.filesDir, "recovery-archives").apply { mkdirs() }
                val file = File(directory, "modern-${UUID.randomUUID()}.json")
                val archive = connection.host.exportCheckpoint()
                kotlinx.coroutines.withContext(kotlinx.coroutines.Dispatchers.IO) { file.writeBytes(archive) }
                exported = file; status = "Complete recovery archive saved"
            } catch (error: Throwable) { failure = error.toString() } } }) { Text("Export recovery") }
        } }
        exported?.let { file -> TextButton(onClick = {
            val uri = androidx.core.content.FileProvider.getUriForFile(context, "${context.packageName}.recovery", file)
            context.startActivity(android.content.Intent.createChooser(android.content.Intent(android.content.Intent.ACTION_SEND).setType("application/json")
                .putExtra(android.content.Intent.EXTRA_STREAM, uri).addFlags(android.content.Intent.FLAG_GRANT_READ_URI_PERMISSION), "Share recovery archive"))
        }) { Text("Share recovery archive") } }
        state?.let { editor -> ModernBlockEditor(editor, Modifier.weight(1f), openReference = { target -> status = "Application navigation: $target" },
            resolveMedia = { _, value -> resolveModernAsset(context, value) },
            replaceMedia = { target -> chooseAsset(target.export().getJSONObject("origin").getString("kind")) },
            suggestLinks = { query -> listOf(ModernLinkSuggestion("getting-started", "help", "Getting started")).filter { it.label.contains(query, true) || query.isEmpty() } },
            insertAssetSelection = { descriptor, boundary, range -> scope.launch {
                try {
                    val isCurrent = editor.host.captureInvocation()
                    var metadata = chooseAsset(descriptor.blockType, descriptor.blockType == "embed").export()
                    check(isCurrent()) { "Original document inactive" }
                    val plain = metadata.optBoolean("plainLink", false); metadata.remove("plainLink")
                    if (plain) { val url = metadata.getString("url"); metadata = JSONObject().put("content", JSONArray().put(JSONObject().put("type", "text").put("text", url).put("marks", JSONArray().put(JSONObject().put("type", "link").put("href", url))))) }
                    metadata.put("id", UUID.randomUUID().toString()).put("type", if (plain) "paragraph" else descriptor.blockType)
                    if (descriptor.blockType == "image") metadata.put("caption", JSONArray())
                    val payload = editor.session.clipboardParts(JSONArray().put(JSONObject().put("node", JSONObject().put("kind", "block").put("value", metadata))))
                    val target = ModernPasteTarget.Boundary(boundary, range?.let { ModernDeleteTarget(ranges = listOf(it)) })
                    editor.execute(ModernCommand.Paste(target, payload, policy = ModernPastePolicy(allowAssetMetadata = true))); editor.host.save()
                } catch (error: Throwable) { failure = error.toString() }
            } }
        ) }
        asset?.takeIf { it.first == "embed" }?.let { request -> AlertDialog(onDismissRequest = { request.second.completeExceptionally(kotlinx.coroutines.CancellationException()); asset = null },
            title = { Text("Application preview") }, text = { TextField(value = previewURL, onValueChange = { previewURL = it }, label = { Text("URL") }) },
            confirmButton = { Column {
                TextButton(onClick = { request.second.complete(ModernPayload.restore(JSONObject().put("url", previewURL).put("title", previewURL))); asset = null }) { Text("Use preview") }
                if (allowPlainLink) TextButton(onClick = { request.second.complete(ModernPayload.restore(JSONObject().put("url", previewURL).put("plainLink", true))); asset = null }) { Text("Use plain link") }
            } },
            dismissButton = { TextButton(onClick = { request.second.completeExceptionally(kotlinx.coroutines.CancellationException()); asset = null }) { Text("Cancel") } }) }
        failure?.let { Text("Could not complete the editor action: $it"); if (state == null) TextButton(onClick = { retry++ }) { Text("Retry opening") } }
    }
}
