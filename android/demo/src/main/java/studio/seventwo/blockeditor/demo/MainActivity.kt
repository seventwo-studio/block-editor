package studio.seventwo.blockeditor.demo

import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.compose.foundation.layout.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.input.PasswordVisualTransformation
import androidx.compose.ui.unit.dp
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.coroutines.CancellationException
import studio.seventwo.blockeditor.BlockEditor
import studio.seventwo.blockeditor.MergeRepair
import org.json.JSONArray
import org.json.JSONObject
import java.io.File
import java.util.UUID

class MainActivity : ComponentActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        setContent { MaterialTheme { LocalDemo() } }
    }
}

@Composable private fun LocalDemo() {
    val context = LocalContext.current
    val preferences = remember { context.getSharedPreferences("local-demo", android.content.Context.MODE_PRIVATE) }
    var endpoint by remember { mutableStateOf(preferences.getString("endpoint", "http://10.0.2.2:4319/rooms/shared-demo")!!) }
    var token by remember { mutableStateOf("") }
    var connection by remember { mutableStateOf<LocalRelayConnection?>(null) }
    var online by remember { mutableStateOf(true) }
    var status by remember { mutableStateOf("Enter the local relay token") }
    var opening by remember { mutableStateOf(false) }
    val scope = rememberCoroutineScope()
    val directory = File(context.filesDir, "local-drafts")
    DisposableEffect(connection) { val current = connection; onDispose { current?.close() } }
    LaunchedEffect(connection, online) {
        val current = connection ?: return@LaunchedEffect
        current.connected = online
        while (online) {
            try { current.exchange(); status = "Connected; ${current.pending} unacknowledged changes; ${current.peerCount} other clients" }
            catch (error: CancellationException) { throw error }
            catch (error: Exception) { status = if (current.recovery != null) "Synchronization paused for recovery" else "Retrying: ${error.message}" }
            delay(500)
        }
        status = "Offline; edits remain on this client"
    }
    Column(Modifier.fillMaxSize().padding(24.dp)) {
        Text("Local editor lab", style = MaterialTheme.typography.headlineSmall)
        Text(status)
        OutlinedTextField(token, { token = it; connection?.setToken(it) }, label = { Text("Local demo token") }, visualTransformation = PasswordVisualTransformation())
        val current = connection
        if (current == null) {
            OutlinedTextField(endpoint, { endpoint = it }, label = { Text("Server room URL") })
            Button(enabled = !opening, onClick = { scope.launch {
                opening = true
                try {
                    val opened = LocalRelayConnection.open(endpoint, token, LocalDraft.file(directory, endpoint))
                    preferences.edit().putString("endpoint", endpoint).apply()
                    online = opened.connected; connection = opened
                }
                catch (error: CancellationException) { throw error }
                catch (error: Exception) { status = error.message ?: "Could not open editor" }
                finally { opening = false }
            } }) { Text(if (opening) "Opening…" else "Open editor") }
        } else {
            Text(current.saveStatus)
            Row { Switch(checked = online, onCheckedChange = { online = it }); Text("Connected to local server") }
            current.recovery?.let { recovery ->
                RecoveryPanel(recovery, repair = { identity ->
                    try {
                        val wrapper = JSONObject().put("id", UUID.randomUUID().toString()).put("type", "toggle")
                            .put("summary", JSONArray().put(JSONObject().put("type", "text").put("text", "Recovered block").put("marks", JSONArray())))
                            .put("children", JSONArray())
                        current.session.repairMerge(listOf(MergeRepair.Wrap(identity, wrapper, "children")))
                    } finally { current.refreshRecovery() }
                }, export = {
                    File(context.filesDir, "recovery-archives/recovery-${UUID.randomUUID()}.json").also { current.exportRecovery(it) }
                }, retry = { online = true; current.connected = true })
            }
            BlockEditor(current.session, Modifier.weight(1f), readOnly = current.recovery != null,
                onError = { current.refreshRecovery() })
        }
    }
}
