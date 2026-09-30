package studio.seventwo.blockeditor.demo

import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.compose.foundation.layout.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.input.PasswordVisualTransformation
import androidx.compose.ui.unit.dp
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.coroutines.CancellationException
import studio.seventwo.blockeditor.BlockEditor

class MainActivity : ComponentActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        setContent { MaterialTheme { LocalDemo() } }
    }
}

@Composable private fun LocalDemo() {
    var endpoint by remember { mutableStateOf("http://10.0.2.2:4319/rooms/shared-demo") }
    var token by remember { mutableStateOf("") }
    var connection by remember { mutableStateOf<LocalRelayConnection?>(null) }
    var online by remember { mutableStateOf(true) }
    var status by remember { mutableStateOf("Enter the local relay token") }
    var opening by remember { mutableStateOf(false) }
    val scope = rememberCoroutineScope()
    DisposableEffect(connection) { val current = connection; onDispose { current?.close() } }
    LaunchedEffect(connection, online) {
        val current = connection ?: return@LaunchedEffect
        current.connected = online
        while (online) {
            try { current.exchange(); status = "Connected; ${current.pending} unacknowledged changes; ${current.peerCount} other clients" }
            catch (error: CancellationException) { throw error }
            catch (error: Exception) { status = "Retrying: ${error.message}" }
            delay(500)
        }
        status = "Offline; edits remain on this client"
    }
    Column(Modifier.fillMaxSize().padding(24.dp)) {
        Text("Local editor lab", style = MaterialTheme.typography.headlineSmall)
        Text(status)
        val current = connection
        if (current == null) {
            OutlinedTextField(endpoint, { endpoint = it }, label = { Text("Server room URL") })
            OutlinedTextField(token, { token = it }, label = { Text("Local demo token") }, visualTransformation = PasswordVisualTransformation())
            Button(enabled = token.isNotBlank() && !opening, onClick = { scope.launch {
                opening = true
                try { connection = LocalRelayConnection.open(endpoint, token) }
                catch (error: CancellationException) { throw error }
                catch (error: Exception) { status = error.message ?: "Could not open editor" }
                finally { opening = false }
            } }) { Text(if (opening) "Opening…" else "Open editor") }
        } else {
            Row { Switch(checked = online, onCheckedChange = { online = it }); Text("Connected to local server") }
            BlockEditor(current.session, Modifier.weight(1f))
        }
    }
}
