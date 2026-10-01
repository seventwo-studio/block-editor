package studio.seventwo.blockeditor.demo

import android.content.Intent
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.unit.dp
import androidx.core.content.FileProvider
import studio.seventwo.blockeditor.MergeRecovery
import studio.seventwo.blockeditor.NodeIdentity
import studio.seventwo.blockeditor.originalBlocksForWrapping
import java.io.File

@Composable internal fun RecoveryPanel(recovery: MergeRecovery, repair: (NodeIdentity) -> Unit,
                                       export: () -> File, retry: () -> Unit) {
    val choices = remember(recovery) { recovery.originalBlocksForWrapping() }
    var selected by remember(recovery) { mutableStateOf<String?>(null) }
    var expanded by remember { mutableStateOf(false) }
    var error by remember(recovery) { mutableStateOf<String?>(null) }
    var archive by remember(recovery) { mutableStateOf<File?>(null) }
    val context = LocalContext.current
    Card(Modifier.fillMaxWidth()) {
        Column(Modifier.heightIn(max = 320.dp).verticalScroll(rememberScrollState()).padding(12.dp)) {
            Text("Some edits need recovery", style = MaterialTheme.typography.titleMedium)
            Text("Accepted content is still available. Pending edits are kept separately; typing and undo wait until recovery.")
            Box {
                TextButton(onClick = { expanded = true }) { Text(choices.find { it.key == selected }?.label ?: "Choose a recorded block") }
                DropdownMenu(expanded = expanded, onDismissRequest = { expanded = false }) {
                    choices.forEach { choice ->
                        DropdownMenuItem(text = { Text(choice.label) }, onClick = { selected = choice.key; expanded = false })
                    }
                }
            }
            Button(enabled = selected != null, onClick = {
                try { choices.find { it.key == selected }?.let { repair(it.identity) }; error = null }
                catch (failure: Exception) { error = failure.message }
            }) { Text("Place selected block in a new toggle") }
            Text("This preserves the original block. Other conflicts may need a different repair; export keeps the complete pending history.", style = MaterialTheme.typography.bodySmall)
            TextButton(onClick = {
                try { archive = export(); error = null } catch (failure: Exception) { error = failure.message }
            }) { Text("Export recovery archive") }
            TextButton(onClick = retry) { Text("Retry synchronization") }
            archive?.let { file ->
                Text("Recovery archive saved locally")
                TextButton(onClick = {
                    try {
                        val uri = FileProvider.getUriForFile(context, "${context.packageName}.recovery", file)
                        val share = Intent(Intent.ACTION_SEND).setType("application/json").putExtra(Intent.EXTRA_STREAM, uri)
                            .addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                        context.startActivity(Intent.createChooser(share, "Share recovery archive"))
                    } catch (failure: Exception) { error = failure.message }
                }) { Text("Share recovery archive") }
            }
            error?.let { Text(it, color = MaterialTheme.colorScheme.error) }
        }
    }
}
