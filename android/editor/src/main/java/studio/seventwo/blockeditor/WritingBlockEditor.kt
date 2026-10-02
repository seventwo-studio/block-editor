package studio.seventwo.blockeditor

import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.itemsIndexed
import androidx.compose.material3.Checkbox
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalFocusManager
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.unit.dp
import org.json.JSONArray
import org.json.JSONObject
import java.io.Closeable
import java.util.UUID

/** Additive collection surface. The original paragraph state keeps its root-only default. */
class WritingBlockEditorState(val session: WritingSession, scope: kotlinx.coroutines.CoroutineScope,
    retainDrafts: (List<WritingInputDraft>) -> Unit, reportError: (Exception) -> Unit = {},
) : Closeable {
    internal val surface = WritingParagraphEditorState.forCollections(session, scope, retainDrafts, reportError)
    var readOnly: Boolean
        get() = surface.readOnly
        set(value) { surface.readOnly = value }
    var pastePolicy: WritingPastePolicy
        get() = surface.pastePolicy
        set(value) { surface.pastePolicy = value }
    fun pendingDrafts() = surface.pendingDrafts()
    override fun close() = surface.close()
}

@Composable fun rememberWritingBlockEditorState(session: WritingSession,
    retainDrafts: (List<WritingInputDraft>) -> Unit, reportError: (Exception) -> Unit = {},
): WritingBlockEditorState {
    val currentRetain by rememberUpdatedState(retainDrafts)
    val currentError by rememberUpdatedState(reportError)
    val scope = rememberCoroutineScope()
    return remember(session, scope) { WritingBlockEditorState(session, scope, { currentRetain(it) }, { currentError(it) }) }
}

internal fun writingNodeValue(session: WritingSession, identity: NodeIdentity): JSONObject {
    val address = session.nodeAddress(identity)
    return fieldValue(session.snapshot, address.blockID, address.path) as? JSONObject ?: error("Shared node is retired")
}

internal fun writingParentCollection(session: WritingSession, identity: NodeIdentity): NodeCollection {
    val address = session.nodeAddress(identity)
    if (address.path.isEmpty()) return NodeCollection.ROOT
    val field = address.path[address.path.size - 2]
    val owner = session.node(NodeAddress(address.blockID, address.path.dropLast(2)))
    return writingCollection(owner, field)
}

internal fun writingCollection(owner: NodeIdentity, field: String): NodeCollection = when (field) {
    "children" -> NodeCollection.children(owner)
    "items" -> NodeCollection.items(owner)
    "rows" -> NodeCollection.rows(owner)
    "cells" -> NodeCollection.cells(owner)
    else -> error("Unsupported shared collection")
}

internal fun writingFirstPosition(session: WritingSession, identity: NodeIdentity?): WritingPosition? {
    if (identity == null) return null
    val value = writingNodeValue(session, identity)
    val type = value.optString("type")
    if (value.opt("content") is JSONArray && (type.isEmpty() || type in setOf("paragraph", "heading", "quote", "callout")))
        return session.position(session.textAddress(identity), 0)
    if (type == "code" && value.opt("code") is String) return session.position(session.textAddress(identity, "code"), 0)
    if (type == "math" && value.opt("expression") is String) return session.position(session.textAddress(identity, "expression"), 0)
    if (type == "toggle") return if (value.opt("summary") is JSONArray) session.position(session.textAddress(identity, "summary"), 0) else null
    val field = when {
        type == "list" -> "items"
        type == "table" -> "rows"
        value.has("cells") -> "cells"
        else -> return null
    }
    return writingFirstPosition(session, session.collectionNodes(writingCollection(identity, field)).firstOrNull())
}

private enum class WritingKind { BLOCK, ITEM, ROW, CELL }
private class WritingControlLease { var attached = true }

internal fun writingSiblingIndex(session: WritingSession, identity: NodeIdentity): Pair<Int, Int> {
    val siblings = session.collectionNodes(writingParentCollection(session, identity))
    return siblings.indexOfFirst { writingCanonical(it.wire) == writingCanonical(identity.wire) } to siblings.size
}
internal fun writingMayOutdent(session: WritingSession, identity: NodeIdentity): Boolean {
    val address = session.nodeAddress(identity)
    if (address.path.dropLast(1).lastOrNull() != "children") return false
    val owner = session.node(NodeAddress(address.blockID, address.path.dropLast(2)))
    return writingNodeValue(session, owner).optString("type").isEmpty()
}
private fun emptyRich() = JSONArray()
private fun freshID(prefix: String) = "$prefix-${UUID.randomUUID()}"
private fun paragraph() = JSONObject().put("id", freshID("p")).put("type", "paragraph").put("content", emptyRich())
private fun item(style: String?) = JSONObject().put("id", freshID("item")).put("content", emptyRich())
    .put("children", JSONArray()).also { if (style == "todo") it.put("checked", false) }
private fun cell() = JSONObject().put("id", freshID("cell")).put("content", emptyRich())
private fun row(count: Int = 1) = JSONObject().put("id", freshID("row"))
    .put("cells", JSONArray().also { values -> repeat(maxOf(1, count)) { values.put(cell()) } })

/** Metadata handed to renderAsset is an inert defensive copy. This surface never loads URLs or downloads assets. */
@Composable fun WritingBlockEditor(state: WritingBlockEditorState, modifier: Modifier = Modifier,
    renderAsset: @Composable (JSONObject) -> Unit = { Text(it.optString("type", "Block")) },
) {
    val surface = state.surface
    val focus = LocalFocusManager.current
    val revoke = { focus.clearFocus(force = true) }
    DisposableEffect(state) { surface.attachSurface(); onDispose { surface.detachSurface() } }
    val snapshot = state.session.snapshot
    val roots = remember(state.session, snapshot) { state.session.collectionNodes(NodeCollection.ROOT) }
    val blocked = state.readOnly || surface.inputs.focusRequest != null
    fun command(action: () -> Unit) {
        if (state.readOnly) return
        try { action() } catch (error: Exception) { surface.reportError(error) }
    }
    LazyColumn(modifier) {
        item {
        Row {
            TextButton(enabled = !blocked && snapshot.optBoolean("canUndo"),
                onClick = { command { surface.inputs.history(revoke, false) } }, modifier = Modifier.testTag("writing-undo")) { Text("Undo") }
            TextButton(enabled = !blocked && snapshot.optBoolean("canRedo"),
                onClick = { command { surface.inputs.history(revoke, true) } }, modifier = Modifier.testTag("writing-redo")) { Text("Redo") }
        }
        Row {
            TextButton(enabled = !blocked, onClick = { command { surface.inputs.append(revoke, { JSONArray().put(paragraph()) }, NodeCollection.ROOT) } }, modifier = Modifier.testTag("writing-add-paragraph")) { Text("Add paragraph") }
            TextButton(enabled = !blocked, onClick = { command {
                val value = JSONObject().put("id", freshID("list")).put("type", "list").put("style", "todo")
                    .put("items", JSONArray().put(item("todo")))
                surface.inputs.append(revoke, { JSONArray().put(value) }, NodeCollection.ROOT)
            } }, modifier = Modifier.testTag("writing-add-checklist")) { Text("Add checklist") }
            TextButton(enabled = !blocked, onClick = { command {
                val value = JSONObject().put("id", freshID("toggle")).put("type", "toggle").put("summary", emptyRich()).put("children", JSONArray())
                surface.inputs.append(revoke, { JSONArray().put(value) }, NodeCollection.ROOT)
            } }, modifier = Modifier.testTag("writing-add-toggle")) { Text("Add toggle") }
            TextButton(enabled = !blocked, onClick = { command {
                val value = JSONObject().put("id", freshID("table")).put("type", "table").put("rows", JSONArray().put(row()))
                surface.inputs.append(revoke, { JSONArray().put(value) }, NodeCollection.ROOT)
            } }, modifier = Modifier.testTag("writing-add-table")) { Text("Add table") }
        }
        }
        itemsIndexed(roots, key = { _, identity -> writingCanonical(identity.wire) }) { index, identity ->
            WritingNode(state, identity, WritingKind.BLOCK, null, index, roots.size, renderAsset)
        }
    }
}

@Composable private fun WritingCollection(state: WritingBlockEditorState, collection: NodeCollection,
    kind: WritingKind, style: String?, renderAsset: @Composable (JSONObject) -> Unit,
) {
    val snapshot = state.session.snapshot
    val nodes = remember(state.session, snapshot, writingCanonical(collection.wire)) { state.session.collectionNodes(collection) }
    Column {
        nodes.forEachIndexed { index, identity -> key(writingCanonical(identity.wire)) { WritingNode(state, identity, kind, style, index, nodes.size, renderAsset) } }
    }
}

@Composable private fun WritingRichField(state: WritingBlockEditorState, identity: NodeIdentity,
    field: String = "content", label: String = "Paragraph", blockConversions: Boolean = true,
) {
    // Optional absent rich fields have no shared field birth to edit. Keep the
    // valid node inert instead of inventing a platform text array or epoch.
    if (writingNodeValue(state.session, identity).opt(field) is JSONArray ||
        (field in setOf("code", "expression") && writingNodeValue(state.session, identity).opt(field) is String))
        WritingTextField(state.session, state.surface.inputs, identity, state.readOnly, state.surface::reportError,
            field, label, blockConversions)
    else Text(label)
}

@Composable private fun WritingNode(state: WritingBlockEditorState, identity: NodeIdentity,
    kind: WritingKind, style: String?, siblingIndex: Int, siblingCount: Int, renderAsset: @Composable (JSONObject) -> Unit,
) {
    val session = state.session
    val inputs = state.surface.inputs
    val node = writingNodeValue(session, identity)
    val captured = session.nodeAddress(identity)
    val origin = writingCanonical(identity.wire)
    val focus = LocalFocusManager.current
    val lease = remember(state, origin) { WritingControlLease() }
    DisposableEffect(lease) { onDispose { lease.attached = false } }
    val canUp = siblingIndex > 0
    val canDown = siblingIndex >= 0 && siblingIndex + 1 < siblingCount
    val canIndent = kind == WritingKind.ITEM && canUp
    val canOutdent = kind == WritingKind.ITEM && writingMayOutdent(session, identity)
    val blocked = state.readOnly || inputs.focusRequest != null
    val revoke = { focus.clearFocus(force = true) }
    fun action(command: () -> Unit) {
        // A retained control cannot target a reused label or an old native location.
        if (!lease.attached || state.readOnly || runCatching { session.nodeAddress(identity) == captured }.getOrDefault(false).not()) return
        try { command() } catch (error: Exception) { state.surface.reportError(error) }
    }
    fun add(field: String, value: () -> JSONObject) = action {
        val collection = writingCollection(identity, field)
        inputs.append(revoke, { JSONArray().put(value()) }, collection)
    }
    Column(Modifier.padding(start = 12.dp).testTag("writing-node:$origin")) {
        Row {
            TextButton(enabled = !blocked && canUp, onClick = { if (canUp) action { inputs.move(revoke, identity, -1) } }, modifier = Modifier.testTag("writing-up:$origin")) { Text("Up") }
            TextButton(enabled = !blocked && canDown, onClick = { if (canDown) action { inputs.move(revoke, identity, 1) } }, modifier = Modifier.testTag("writing-down:$origin")) { Text("Down") }
            TextButton(enabled = !blocked, onClick = { action { inputs.duplicate(revoke, identity) } }, modifier = Modifier.testTag("writing-duplicate:$origin")) { Text("Duplicate") }
            TextButton(enabled = !blocked, onClick = { action { inputs.delete(revoke, identity) } }, modifier = Modifier.testTag("writing-delete:$origin")) { Text("Delete") }
        }
        when (kind) {
            WritingKind.BLOCK -> when (node.optString("type")) {
                "paragraph", "heading", "quote", "callout" -> WritingRichField(state, identity)
                "toggle" -> {
                    WritingRichField(state, identity, field = "summary", label = "Toggle summary", blockConversions = false)
                    TextButton(enabled = !blocked, onClick = { add("children", ::paragraph) }, modifier = Modifier.testTag("writing-add-child:$origin")) { Text("Add child") }
                    WritingCollection(state, NodeCollection.children(identity), WritingKind.BLOCK, null, renderAsset)
                }
                "list" -> {
                    val currentStyle = node.getString("style")
                    Text("List: $currentStyle")
                    Row {
                        for (target in listOf("unordered", "ordered", "todo"))
                            TextButton(enabled = !blocked, onClick = { action { inputs.listStyle(revoke, identity, target) } },
                                modifier = Modifier.testTag("writing-list-$target:$origin")) { Text(target) }
                    }
                    TextButton(enabled = !blocked, onClick = { add("items") { item(currentStyle) } }, modifier = Modifier.testTag("writing-add-item:$origin")) { Text("Add item") }
                    WritingCollection(state, NodeCollection.items(identity), WritingKind.ITEM, currentStyle, renderAsset)
                }
                "code" -> WritingRichField(state, identity, field = "code", label = "Code", blockConversions = false)
                "math" -> WritingRichField(state, identity, field = "expression", label = "Math expression", blockConversions = false)
                "image" -> {
                    renderAsset(NativeJsonTransport.copy(node))
                    WritingRichField(state, identity, field = "caption", label = "Image caption", blockConversions = false)
                }
                "table" -> {
                    TextButton(enabled = !blocked, onClick = { add("rows") {
                        val rows = session.collectionNodes(NodeCollection.rows(identity))
                        row(rows.firstOrNull()?.let { session.collectionNodes(NodeCollection.cells(it)).size } ?: 1)
                    } }, modifier = Modifier.testTag("writing-add-row:$origin")) { Text("Add row") }
                    WritingCollection(state, NodeCollection.rows(identity), WritingKind.ROW, null, renderAsset)
                }
                else -> renderAsset(NativeJsonTransport.copy(node))
            }
            WritingKind.ITEM -> {
                if (style == "todo") Checkbox(checked = node.optBoolean("checked"), enabled = !blocked,
                    onCheckedChange = { next -> action { inputs.checked(revoke, identity, next) } }, modifier = Modifier.testTag("writing-check:$origin").semantics {
                        contentDescription = plainText(node.optJSONArray("content")).ifBlank { "Checklist item" }
                    })
                WritingRichField(state, identity, label = "List item")
                Row {
                    TextButton(enabled = !blocked && canIndent, onClick = { if (canIndent) action { inputs.indent(revoke, identity) } }, modifier = Modifier.testTag("writing-indent:$origin")) { Text("Indent") }
                    TextButton(enabled = !blocked && canOutdent, onClick = { if (canOutdent) action { inputs.outdent(revoke, identity) } }, modifier = Modifier.testTag("writing-outdent:$origin")) { Text("Outdent") }
                }
                TextButton(enabled = !blocked, onClick = { add("children") { item(style) } }, modifier = Modifier.testTag("writing-add-child:$origin")) { Text("Add nested item") }
                WritingCollection(state, NodeCollection.children(identity), WritingKind.ITEM, style, renderAsset)
            }
            WritingKind.ROW -> {
                TextButton(enabled = !blocked, onClick = { add("cells", ::cell) }, modifier = Modifier.testTag("writing-add-cell:$origin")) { Text("Add cell") }
                WritingCollection(state, NodeCollection.cells(identity), WritingKind.CELL, null, renderAsset)
            }
            WritingKind.CELL -> WritingRichField(state, identity, label = "Table cell", blockConversions = false)
        }
    }
}
