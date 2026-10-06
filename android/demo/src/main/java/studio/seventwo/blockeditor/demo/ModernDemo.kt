package studio.seventwo.blockeditor.demo

import androidx.compose.foundation.layout.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.unit.dp
import kotlinx.coroutines.launch
import org.json.JSONArray
import org.json.JSONObject
import studio.seventwo.blockeditor.*
import java.io.File
import java.util.UUID

/** No relay service is needed for local protocol-7 editing and paired reopen. */
@Composable fun ModernDemo() {
    val context = LocalContext.current; val scope = rememberCoroutineScope()
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
    DisposableEffect(state) { val current = state; onDispose { current?.host?.setActive(false) } }
    Column(Modifier.fillMaxSize()) {
        Row(Modifier.fillMaxWidth().padding(8.dp)) {
            Text(status, Modifier.weight(1f))
            state?.let { editor -> TextButton(onClick = { scope.launch { try { editor.host.save(); status = "Saved with author history and recovery" } catch (error: Throwable) { failure = error.toString() } } }) { Text("Save locally") } }
            resume?.let { release -> TextButton(onClick = { try { release(); resume = null } catch (error: Throwable) { failure = error.toString() } }) { Text("Resume saved packets") } }
        }
        state?.let { ModernBlockEditor(it, Modifier.weight(1f), openReference = { target -> status = "Application navigation: $target" }) }
        failure?.let { Text("Could not complete the editor action: $it"); if (state == null) TextButton(onClick = { retry++ }) { Text("Retry opening") } }
    }
}
