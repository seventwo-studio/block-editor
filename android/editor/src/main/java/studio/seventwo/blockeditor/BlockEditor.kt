package studio.seventwo.blockeditor

import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalFocusManager
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.liveRegion
import androidx.compose.ui.semantics.LiveRegionMode
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.unit.dp
import org.json.JSONArray
import org.json.JSONObject
import java.util.UUID

/** Native authoring surface; the host supplies assets, permissions and storage. */
@Composable fun BlockEditor(session: EditorSession, modifier: Modifier = Modifier,
                            asset: @Composable (JSONObject) -> Unit = { Text(it.optString("alt", "Image")) }) {
    EditorSurface(session, modifier, false, {}, null, null, asset)
}

/** Read-only content remains selectable; hosts can surface recovery after failed edits. */
@Composable fun BlockEditor(session: EditorSession, modifier: Modifier = Modifier, readOnly: Boolean,
                            onError: (Exception) -> Unit = {},
                            asset: @Composable (JSONObject) -> Unit = { Text(it.optString("alt", "Image")) }) {
    EditorSurface(session, modifier, readOnly, onError, null, null, asset)
}

/** Hosts resolve a picked asset and apply its metadata through shared commands. */
@Composable fun BlockEditor(session: EditorSession, modifier: Modifier = Modifier, readOnly: Boolean,
                            onAssetRequest: (NodeAddress, JSONObject) -> Unit,
                            onAssetInsertRequest: (() -> Unit)? = null,
                            onError: (Exception) -> Unit = {},
                            asset: @Composable (JSONObject) -> Unit = { Text(it.optString("alt", "Image")) }) {
    EditorSurface(session, modifier, readOnly, onError, onAssetRequest, onAssetInsertRequest, asset)
}

@Composable private fun EditorSurface(session: EditorSession, modifier: Modifier, readOnly: Boolean,
                                     onError: (Exception) -> Unit,
                                     onAssetRequest: ((NodeAddress, JSONObject) -> Unit)?,
                                     onAssetInsertRequest: (() -> Unit)?,
                                     asset: @Composable (JSONObject) -> Unit) {
    var error by remember(session) { mutableStateOf<String?>(null) }
    val composing = remember(session) { mutableStateMapOf<String, Boolean>() }
    val currentReadOnly by rememberUpdatedState(readOnly)
    fun report(e: Exception) { error = e.message; onError(e) }
    val currentReport by rememberUpdatedState<(Exception) -> Unit>(::report)
    val scope = rememberCoroutineScope()
    val inputs = remember(session) { EditorInputs(session, scope) { currentReport(it) } }
    val focusManager = LocalFocusManager.current
    DisposableEffect(inputs) { onDispose { inputs.close() } }
    fun perform(action: () -> Unit) {
        if (currentReadOnly || composing.isNotEmpty()) return
        try { inputs.perform(action); error = null } catch (e: Exception) { report(e) }
    }
    fun history(action: () -> Unit) {
        if (currentReadOnly) return
        try {
            inputs.performHistory({ focusManager.clearFocus(force = true) }, action)
            error = null
        } catch (e: Exception) { report(e) }
    }
    val array = session.snapshot.getJSONArray("blocks")
    val blocks = (0 until array.length()).map { array.getJSONObject(it) }
    val targets = remember(session, session.snapshot) {
        val identities = if (session.syncState().optInt("version", 1) >= 2) session.nodes(NodeCollection.ROOT) else emptyList()
        blocks.mapIndexed { index, block ->
            val id = block.getString("id")
            id to RenderedNodeTarget(session, NodeAddress(id), identities.getOrNull(index))
        }.toMap()
    }
    val canAct = !readOnly && composing.isEmpty()
    val canHistory = !readOnly && inputs.canPerformHistory()
    val listState = rememberLazyListState()
    LaunchedEffect(readOnly) { if (readOnly) inputs.cancelFocusRestoration() }
    LaunchedEffect(inputs.focusRequest) {
        val address = inputs.requestedAddress() ?: return@LaunchedEffect
        val index = blocks.indexOfFirst { it.optString("id") == address.blockID }
        if (index >= 0) listState.scrollToItem(index)
    }
    CompositionLocalProvider(LocalEditorInputs provides inputs) {
        Column(modifier) {
            Row {
                TextButton(enabled = canHistory && session.snapshot.getBoolean("canUndo"), onClick = { history { session.undo() } }) { Text("Undo") }
                TextButton(enabled = canHistory && session.snapshot.getBoolean("canRedo"), onClick = { history { session.redo() } }) { Text("Redo") }
                TextButton(enabled = canAct, onClick = { perform {
                    session.edit("insert", JSONObject().put("after", blocks.lastOrNull()?.getString("id") ?: JSONObject.NULL)
                        .put("block", JSONObject().put("id", UUID.randomUUID().toString()).put("type", "paragraph").put("content", JSONArray())))
                } }) { Text("Paragraph") }
                onAssetInsertRequest?.let { request ->
                    TextButton(enabled = canAct, onClick = { perform(request) }) { Text("Image") }
                }
            }
            error?.let { Text(it, color = MaterialTheme.colorScheme.error,
                modifier = Modifier.semantics { liveRegion = LiveRegionMode.Polite }) }
            LazyColumn(Modifier.weight(1f), state = listState) {
                items(blocks, key = { it.getString("id") }) { block ->
                    val id = block.getString("id")
                    val target = targets.getValue(id)
                    key(target.key) {
                    Column(Modifier.fillMaxWidth().padding(8.dp)) {
                        EditableBlockContent(session, id, block, emptyList(), readOnly, canAct,
                            ::report, { key, active -> if (active) composing[key] = true else composing.remove(key) }, onAssetRequest, asset)
                        BlockActions(id, emptyList(), canAct, blocks.indexOf(block), blocks.size, ::report,
                            canPerform = { target.current() && (target.identity == null || runCatching {
                                session.nodes(NodeCollection.ROOT).map { it.wire.toString() } == targets.values.mapNotNull { it.identity?.wire?.toString() }
                            }.getOrDefault(false)) },
                            move = { destination ->
                                val after = if (destination == 0) null else blocks[if (destination > blocks.indexOf(block)) destination else destination - 1].getString("id")
                                if (target.identity != null) {
                                    val adjacent = after?.let { targets.getValue(it) }
                                    if (adjacent != null) check(adjacent.current()) { "Move target changed; choose the action again" }
                                    session.moveNode(target.identity, NodeCollection.ROOT, adjacent?.identity)
                                }
                                else session.edit("move", JSONObject().put("blockID", id).put("after", after ?: JSONObject.NULL))
                            }, delete = {
                                if (target.identity != null) session.deleteNode(target.identity)
                                else session.edit("delete", JSONObject().put("blockID", id))
                            })
                    }
                    }
                }
            }
        }
    }
}

/** One menu gives touch, keyboard and accessibility users the same commands. */
@Composable internal fun BlockActions(blockID: String, path: List<String>, enabled: Boolean,
                                     index: Int, count: Int, report: (Exception) -> Unit,
                                     move: (Int) -> Unit, delete: () -> Unit,
                                     indent: (() -> Unit)? = null, outdent: (() -> Unit)? = null,
                                     canPerform: () -> Boolean = { true }) {
    var expanded by remember(blockID, path) { mutableStateOf(false) }
    LaunchedEffect(enabled) { if (!enabled) expanded = false }
    val inputs = LocalEditorInputs.current
    val currentEnabled by rememberUpdatedState(enabled)
    val currentIndex by rememberUpdatedState(index)
    val currentCount by rememberUpdatedState(count)
    val lease = remember(blockID, path) { mutableStateOf(true) }
    DisposableEffect(lease) { onDispose { lease.value = false } }
    fun perform(action: () -> Unit) {
        expanded = false
        if (!currentEnabled || !lease.value || !canPerform()) return
        try { inputs.perform(action) } catch (error: Exception) { report(error) }
    }
    Box {
        TextButton(enabled = enabled, onClick = { if (currentEnabled && lease.value) expanded = true },
            modifier = Modifier.testTag("editor-actions:$blockID:${path.joinToString("/")}")
                .semantics { contentDescription = if (path.isEmpty()) "Block actions" else "Nested item actions" }) { Text("⋯") }
        DropdownMenu(expanded && enabled, onDismissRequest = { expanded = false }) {
            DropdownMenuItem(text = { Text("Move up") }, enabled = index > 0, onClick = { if (currentIndex > 0 && currentIndex < currentCount) perform { move(currentIndex - 1) } })
            DropdownMenuItem(text = { Text("Move down") }, enabled = index < count - 1, onClick = { if (currentIndex >= 0 && currentIndex < currentCount - 1) perform { move(currentIndex + 1) } })
            indent?.let { DropdownMenuItem(text = { Text("Indent") }, enabled = index > 0, onClick = { if (currentIndex > 0 && currentIndex < currentCount) perform(it) }) }
            outdent?.let { DropdownMenuItem(text = { Text("Outdent") }, onClick = { perform(it) }) }
            DropdownMenuItem(text = { Text("Delete") }, onClick = { perform(delete) })
        }
    }
}

internal fun plainText(nodes: JSONArray?): String = if (nodes == null) "" else (0 until nodes.length()).joinToString("") {
    val node = nodes.getJSONObject(it)
    when (node.optString("type")) {
        "text" -> node.optString("text")
        "mention", "entity-ref" -> node.optString("label")
        "date" -> node.optString("date")
        "emoji" -> ":${node.optString("name")}:"
        "inline-math" -> node.optString("expression")
        else -> ""
    }
}
