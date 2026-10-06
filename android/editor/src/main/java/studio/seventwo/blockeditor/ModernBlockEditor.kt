package studio.seventwo.blockeditor

import android.content.ClipboardManager
import android.content.Context
import androidx.compose.foundation.gestures.detectDragGesturesAfterLongPress
import androidx.compose.foundation.gestures.scrollBy
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Rect
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.layout.onGloballyPositioned
import androidx.compose.ui.layout.boundsInRoot
import kotlinx.coroutines.launch
import androidx.compose.foundation.background
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.relocation.BringIntoViewRequester
import androidx.compose.foundation.relocation.bringIntoViewRequester
import androidx.compose.ui.text.input.VisualTransformation
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.focus.onFocusChanged
import androidx.compose.ui.input.key.*
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.TextRange
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.input.TextFieldValue
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import org.json.JSONArray
import org.json.JSONObject
import java.util.UUID

class ModernBlockEditorState(val host: ModernAndroidHost, val reportError: (Throwable) -> Unit = {}) {
    val session get() = host.session
    var selection by mutableStateOf<ModernNodes?>(null)
    var textSelection by mutableStateOf<ModernTextRange?>(null)
    var textSpan by mutableStateOf<List<ModernTextRange>>(emptyList())
    var collapsed by mutableStateOf<Set<String>>(emptySet())
    fun reveal(node: ModernNodeID) {
        var current = node; val next = collapsed.toMutableSet()
        while (true) { val owner = (session.parentCollection(current) as? ModernCollection.Owned)?.owner ?: break; next.remove(owner.export().toString()); current = owner }
        collapsed = next; focus = session.position(session.field(node), 0)
    }
    fun extendText(next: ModernField, offset: Int) {
        val range = textSelection ?: return
        val start = if (textSpan.isEmpty()) range.start else textSpan.first().start
        textSpan = session.captureTextSpan(start, session.position(next, offset))
    }
    var focus by mutableStateOf<ModernPosition?>(null)
    var insertion by mutableStateOf<ModernBoundary?>(null)
    var insertionRange by mutableStateOf<ModernTextRange?>(null)
    var query by mutableStateOf("")
    var focusMode by mutableStateOf(false)
    var outline by mutableStateOf(false)
    var extending by mutableStateOf(false)
    var linkTarget by mutableStateOf<ModernTextRange?>(null)
    var linkURL by mutableStateOf("")
    val blockFrames = mutableMapOf<String, Triple<ModernNodeID, ModernCollection, Rect>>()
    var dragSelection by mutableStateOf<ModernNodes?>(null)
    var dragPosition: Offset? = null
    var dropBoundary: ModernBoundary? = null
    var dropNode by mutableStateOf<String?>(null)
    var dropBefore by mutableStateOf(false)
    var viewportFrame: Rect? = null
    var edgeScroll: ((Float) -> Unit)? = null
    fun previewDrop(point: Offset) {
        dragPosition = point
        val candidate = blockFrames.entries.filter { (_, value) -> value.third.contains(point) && dragSelection?.nodes?.none { it.export().toString() == value.first.export().toString() } == true }.minByOrNull { it.value.third.width * it.value.third.height }
        if (candidate == null) { dropNode = null; dropBoundary = null; return }
        val (node, collection, rect) = candidate.value; val before = point.y < rect.center.y
        try {
            val siblings = session.nodes(collection); val index = siblings.indexOfFirst { it.export().toString() == node.export().toString() }
            dropBoundary = session.captureBoundary(collection, if (before) siblings.getOrNull(index - 1) else node)
            dropNode = candidate.key; dropBefore = before
        } catch (_: Throwable) { dropNode = null; dropBoundary = null }
        viewportFrame?.let { frame -> when { point.y < frame.top + 64 -> edgeScroll?.invoke(-16f); point.y > frame.bottom - 64 -> edgeScroll?.invoke(16f) } }
    }
    fun cancelDrag() { dragSelection = null; dragPosition = null; dropBoundary = null; dropNode = null }
    var clipboard: ClipboardManager? = null
    var resolveMedia: (suspend (ModernNodeID, ModernPayload) -> ModernMediaPresentation)? = null
    var replaceMedia: (suspend (ModernAsyncTarget) -> ModernPayload)? = null
    var suggestLinks: (suspend (String) -> List<ModernLinkSuggestion>)? = null
    var internalLink by mutableStateOf(false)
    val composing = mutableSetOf<String>()
    fun composition(id: String, active: Boolean) { if (active) composing.add(id) else composing.remove(id); session.setComposing(composing.isNotEmpty()) }
    fun execute(command: ModernCommand, transferFocus: Boolean = true): ModernResult? = try {
        check(host.active && !host.readOnly)
        val result = session.execute(command)
        if (result.status == ModernResultStatus.APPLIED || result.status == ModernResultStatus.NOOP) {
            if (transferFocus && !(command is ModernCommand.TypingShortcut && result.status == ModernResultStatus.NOOP)) result.focusIntent?.export()?.optJSONObject("text")?.optJSONObject("_0")?.let { focus = ModernPosition.restore(it) }
        } else reportError(IllegalStateException(result.reason ?: result.status.wireValue))
        result
    } catch (failure: Throwable) { reportError(failure); null }
    fun select(node: ModernNodeID) {
        try {
            val siblings = session.nodes(session.parentCollection(node))
            val first = selection?.nodes?.firstOrNull()?.export()?.toString()
            val a = siblings.indexOfFirst { it.export().toString() == first }; val b = siblings.indexOfFirst { it.export().toString() == node.export().toString() }
            selection = session.captureNodes(if (extending && a >= 0 && b >= 0) siblings.subList(minOf(a, b), maxOf(a, b) + 1) else listOf(node))
        } catch (failure: Throwable) { reportError(failure) }
    }
    fun move(down: Boolean) {
        val selected = selection ?: return
        try {
            val collection = session.parentCollection(selected.nodes.first()); val siblings = session.nodes(collection)
            val index = siblings.indexOfFirst { it.export().toString() == selected.nodes.first().export().toString() }
            if (index < 0 || (!down && index == 0) || (down && index + selected.nodes.size >= siblings.size)) return
            val after = if (down) siblings[index + selected.nodes.size] else siblings.getOrNull(index - 2)
            execute(ModernCommand.Move(selected, session.captureBoundary(collection, after)))
            selection = session.captureNodes(selected.nodes)
        } catch (failure: Throwable) { reportError(failure) }
    }
    fun retainDraft(id: String, range: ModernTextRange, value: TextFieldValue, reason: String, replacement: String = value.text) {
        val retained = host.drafts.filter { it.optString("id") != id } + modernObject("id" to id, "target" to range, "text" to replacement, "nativeText" to value.text,
            "start" to value.selection.start, "end" to value.selection.end, "reason" to reason.take(1000))
        require(retained.size <= 64 && JSONArray(retained).toString().length <= 16_000_000)
        host.drafts = retained
    }
    fun forgetDraft(id: String) { host.drafts = host.drafts.filter { it.optString("id") != id } }
}

@Composable fun rememberModernBlockEditorState(host: ModernAndroidHost, reportError: (Throwable) -> Unit = {}): ModernBlockEditorState {
    val currentError by rememberUpdatedState(reportError)
    return remember(host) { ModernBlockEditorState(host) { currentError(it) } }
}

@Composable private fun ModernInput(state: ModernBlockEditorState, field: ModernField, label: String, style: TextStyle, submit: (() -> Unit)? = null) {
    val session = state.session; val id = remember(field.node.export().toString(), field.name) { UUID.randomUUID().toString() }
    var value by remember(id) { mutableStateOf(TextFieldValue(session.text(field))) }
    var anchors by remember(id) { mutableStateOf<ModernTextRange?>(null) }
    var pending by remember(id) { mutableStateOf(false) }
    var focused by remember(id) { mutableStateOf(false) }
    var release by remember(id) { mutableStateOf<(() -> Unit)?>(null) }
    var typing by remember(id) { mutableStateOf(UUID.randomUUID().toString()) }
    val original = remember(id) { session.captureTextRange(field, 0, session.text(field).length) }
    val request = remember(id) { FocusRequester() }; val bring = remember(id) { BringIntoViewRequester() }; val shared = session.text(field)
    val rich = remember(shared, session.snapshot.document.export().toString()) {
        if (field.name in listOf("code", "title")) JSONArray() else try {
            session.copy(ModernDeleteTarget(ranges = listOf(session.captureTextRange(field, 0, shared.length)))).export().getJSONArray("parts").optJSONObject(0)?.optJSONObject("inline")?.optJSONArray("_0") ?: JSONArray()
        } catch (_: Throwable) { JSONArray() }
    }
    LaunchedEffect(shared, session.snapshot.syncState.received) {
        if (value.composition == null && !pending) {
            val selection = if (focused && anchors != null) try {
                TextRange(session.resolvePosition(anchors!!.start).export().getInt("offset"), session.resolvePosition(anchors!!.end).export().getInt("offset"))
            } catch (_: Throwable) { value.selection } else value.selection
            value = value.copy(text = shared, selection = TextRange(selection.start.coerceIn(0, shared.length), selection.end.coerceIn(0, shared.length)))
        }
    }
    LaunchedEffect(state.focus) {
        val position = state.focus ?: return@LaunchedEffect
        if (position.export().getJSONObject("field").toString() == field.wire().toString()) {
            val offset = session.resolvePosition(position).export().getInt("offset")
            value = value.copy(text = session.text(field), selection = TextRange(offset), composition = null); request.requestFocus(); bring.bringIntoView(); state.focus = null
        }
    }
    DisposableEffect(id) { onDispose { if (value.composition != null) state.composition(id, false); release?.invoke() } }
    fun selected(next: TextFieldValue) {
        val previous = session.localSelection()?.export()?.optJSONObject("selection")?.optJSONObject("text")?.optJSONObject("_0")
        if (previous != null) {
            val oldStart = ModernPosition.restore(previous.getJSONObject("start")); val oldEnd = ModernPosition.restore(previous.getJSONObject("end"))
            if (oldStart.export().getJSONObject("field").toString() == field.wire().toString() && oldEnd.export().getJSONObject("field").toString() == field.wire().toString()
                && session.resolvePosition(oldStart).offset == next.selection.start && session.resolvePosition(oldEnd).offset == next.selection.end) {
                val scope = session.snapshot.syncState
                val captured = ModernTextRange.restore(modernObject("start" to oldStart, "end" to oldEnd, "observed" to JSONArray(scope.received.map { it.wire() })))
                anchors = captured; state.textSelection = captured; return
            }
        }
        val captured = session.captureTextRange(field, next.selection.start, next.selection.end)
        anchors = captured; state.textSelection = captured
        val wire = captured.export(); val observed = wire.getJSONArray("observed")
        val local = ModernLocalSelection.capture(captured.start.documentID, captured.start.epoch, (0 until observed.length()).map { ModernChangeID.read(observed.getJSONObject(it)) },
            ModernFocusIntent.text(captured.end), ModernSelectionIntent.text(ModernRange(captured.start, captured.end)))
        session.setLocalSelection(local)
    }
    fun boundary(event: KeyEvent): Boolean {
        if (value.selection.start != value.selection.end) return false
        val backward = event.key in listOf(Key.Backspace, Key.DirectionLeft, Key.DirectionUp)
        val forward = event.key in listOf(Key.Delete, Key.DirectionRight, Key.DirectionDown)
        try {
            val collection = if (field.name != "title") session.parentCollection(field.node) else ModernCollection.Blocks
            if (event.key == Key.Tab && collection is ModernCollection.Owned && collection.field in listOf(ModernCollectionField.ITEMS, ModernCollectionField.CHILDREN)) {
                state.execute(ModernCommand.ListStructure(ModernListTarget(session.captureListNodes(listOf(field.node))), if (event.isShiftPressed) ModernListOperation.Outdent else ModernListOperation.Indent)); return true
            }
            if (event.key != Key.Tab && (!backward && !forward || value.selection.start != if (backward) 0 else value.text.length)) return false
            if (event.key in listOf(Key.Backspace, Key.Delete) && field.name == "content") {
                val siblings = session.nodes(collection); val index = siblings.indexOfFirst { it.export().toString() == field.node.export().toString() }
                if (backward && collection is ModernCollection.Owned && collection.field in listOf(ModernCollectionField.ITEMS, ModernCollectionField.CHILDREN)) {
                    state.execute(if (value.text.isEmpty()) ModernCommand.SplitBlock(session.captureTextRange(field, 0, 0), UUID.randomUUID().toString()) else ModernCommand.ListStructure(ModernListTarget(session.captureListNodes(listOf(field.node))), ModernListOperation.Outdent)); return true
                }
                val other = siblings.getOrNull(index + if (backward) -1 else 1) ?: return false
                state.execute(ModernCommand.MergeBlocks(session.captureNodes(if (backward) listOf(other, field.node) else listOf(field.node, other)))); return true
            }
            val fields = session.logicalFields(collapsed = state.collapsed.map { ModernNodeID.restore(JSONObject(it)) }); val index = fields.indexOfFirst { it.wire().toString() == field.wire().toString() }
            val next = fields.getOrNull(index + if (backward || event.isShiftPressed) -1 else 1) ?: return false
            if (event.isShiftPressed && event.key != Key.Tab) state.extendText(next, if (backward) session.text(next).length else 0)
            else state.textSpan = emptyList()
            state.focus = session.position(next, if (backward) session.text(next).length else 0); return true
        } catch (failure: Throwable) { state.reportError(failure); return true }
    }
    BasicTextField(value = value, readOnly = state.host.readOnly || !state.host.active || pending,
        textStyle = style, visualTransformation = if (value.text == shared && field.name != "code") ModernRichTransformation(rich) else VisualTransformation.None, modifier = Modifier.bringIntoViewRequester(bring).fillMaxWidth().heightIn(min = 44.dp).focusRequester(request)
            .semantics { contentDescription = label }.onFocusChanged { focused = it.isFocused; if (focused && value.composition == null) try { selected(value) } catch (failure: Throwable) { state.reportError(failure) } }
            .onPreviewKeyEvent { event ->
                if (event.type != KeyEventType.KeyDown || value.composition != null || state.host.readOnly) false
                else if ((event.isCtrlPressed || event.isMetaPressed) && event.key == Key.Z) { state.execute(if (event.isShiftPressed) ModernCommand.Redo else ModernCommand.Undo); true }
                else if (field.name == "code" && event.key in listOf(Key.Enter, Key.Tab)) { state.execute(ModernCommand.ReplaceText(session.captureTextRange(field, value.selection.start, value.selection.end), if (event.key == Key.Tab) "\t" else "\n")); true }
                else if (event.isShiftPressed && event.key == Key.Enter && field.name != "title") { state.execute(ModernCommand.SoftBreak(session.captureTextRange(field, value.selection.start, value.selection.end))); true }
                else if (boundary(event)) true
                else if (event.key == Key.Enter && submit != null) { submit(); true }
                else if (event.key == Key.Tab && field.name == "code") { state.execute(ModernCommand.ReplaceText(session.captureTextRange(field, value.selection.start, value.selection.end), "\t")); true }
                else false
            }, keyboardOptions = KeyboardOptions(imeAction = if (submit == null) ImeAction.Default else ImeAction.Next), keyboardActions = KeyboardActions(onNext = { submit?.invoke() }),
        onValueChange = { next ->
            if (!state.host.active || pending) return@BasicTextField
            val hadComposition = value.composition != null
            if (next.composition != null) {
                if (!hadComposition) { release = session.holdRemoteChanges(); state.composition(id, true) }
                val target = session.captureTextRange(field, 0, session.text(field).length)
                value = next; state.retainDraft(id, target, next, "compositionActive")
                return@BasicTextField
            }
            if (hadComposition) state.composition(id, false)
            val old = session.text(field)
            try {
                if (old != next.text && !state.host.readOnly) {
                    var lower = 0; while (lower < minOf(old.length, next.text.length) && old[lower] == next.text[lower]) lower++
                    if (lower > 0 && lower < old.length && old[lower].isLowSurrogate()) lower--
                    var suffix = 0; while (suffix < minOf(old.length, next.text.length) - lower && old[old.length - 1 - suffix] == next.text[next.text.length - 1 - suffix]) suffix++
                    if (suffix > 0 && old.length - suffix < old.length && old[old.length - suffix].isLowSurrogate()) suffix--
                    val target = session.captureTextRange(field, lower, old.length - suffix)
                    state.retainDraft(id, target, next, "awaitingCommit", next.text.substring(lower, next.text.length - suffix))
                    val command = if (field.name == "title") ModernCommand.ReplaceTitle(target, next.text.substring(lower, next.text.length - suffix), typing) else ModernCommand.ReplaceText(target, next.text.substring(lower, next.text.length - suffix), typing)
                    val result = state.execute(command, transferFocus = false)
                    if (result == null || result.status !in listOf(ModernResultStatus.APPLIED, ModernResultStatus.NOOP)) { pending = true; value = next; return@BasicTextField }
                } else if (next.selection != value.selection) { session.endTypingGroup(); typing = UUID.randomUUID().toString() }
                value = next; selected(next); state.forgetDraft(id)
                if (old != next.text && session.availability(ModernCommandName.TYPING_SHORTCUT).available) state.execute(ModernCommand.TypingShortcut(session.captureTextRange(field, next.selection.start, next.selection.end)))
                if (old != next.text && field.name == "content" && state.suggestLinks != null && state.linkTarget == null) {
                    val marker = next.text.lastIndexOf("[[")
                    if (marker >= 0 && !next.text.substring(marker + 2).contains("]]")) {
                        state.linkTarget = session.captureTextRange(field, marker, next.text.length)
                        state.linkURL = next.text.substring(marker + 2); state.internalLink = true
                    }
                }
                if (old != next.text && field.name == "content" && next.text.startsWith("/") && !next.text.contains('\n') && state.insertion == null) {
                    // Capture once, before the picker takes native focus.
                    state.insertionRange = session.captureTextRange(field, 0, next.text.length)
                    state.insertion = session.captureBoundary(session.parentCollection(field.node), field.node)
                    state.query = next.text.drop(1)
                }
            } catch (failure: Throwable) { value = next; pending = true; state.retainDraft(id, original, next, "Target unavailable"); state.reportError(failure) }
            finally { val finish = release; release = null; finish?.invoke() }
        })
}

@Composable private fun ModernFormattingMenu(state: ModernBlockEditorState) {
    var opened by remember { mutableStateOf(false) }
    var captured by remember { mutableStateOf<List<ModernTextRange>>(emptyList()) }
    Box {
        TextButton(enabled = !state.host.readOnly, onClick = {
            captured = state.textSpan.ifEmpty { listOfNotNull(state.textSelection) }; opened = true
        }) { Text("Format") }
        DropdownMenu(expanded = opened, onDismissRequest = { opened = false }) {
            listOf("bold", "italic", "strikethrough", "code").forEach { mark ->
                val current = if (captured.isEmpty()) "off" else state.session.markState(captured, mark)
                DropdownMenuItem(text = { Text("$mark${if (current == "on") " ✓" else if (current == "mixed") " (mixed)" else ""}") }, enabled = captured.isNotEmpty(), onClick = {
                    val value = if (current == "on") null else ModernPayload.restore(modernObject("type" to mark))
                    state.execute(if (captured.size > 1) ModernCommand.FormatSpan(captured, mark, value) else ModernCommand.Format(captured.first(), mark, value))
                    opened = false
                })
            }
        }
    }
}

/** All authored operations are protocol-7 JNI commands. Device width and font
 * scale decide column presentation without writing the persisted split. */
@Composable fun ModernBlockEditor(state: ModernBlockEditorState, modifier: Modifier = Modifier,
    insertAsset: ((ModernInsertionDescriptor, ModernBoundary) -> Unit)? = null,
    openReference: ((String) -> Unit)? = null,
    resolveMedia: (suspend (ModernNodeID, ModernPayload) -> ModernMediaPresentation)? = null,
    replaceMedia: (suspend (ModernAsyncTarget) -> ModernPayload)? = null,
    suggestLinks: (suspend (String) -> List<ModernLinkSuggestion>)? = null,
    insertAssetSelection: ((ModernInsertionDescriptor, ModernBoundary, ModernTextRange?) -> Unit)? = null,
) {
    SideEffect { state.resolveMedia = resolveMedia; state.replaceMedia = replaceMedia; state.suggestLinks = suggestLinks }
    val session = state.session; val document = session.snapshot.document.export(); val appearance = document.getJSONObject("appearance")
    val size = when (appearance.getString("fontSize")) { "small" -> 15; "large" -> 20; else -> 17 }
    val family = when (appearance.getString("fontFamily")) { "serif" -> FontFamily.Serif; "monospace" -> FontFamily.Monospace; else -> FontFamily.SansSerif }
    val style = TextStyle(fontFamily = family, fontSize = size.sp, lineHeight = (size * 1.65).sp)
    val clipboard = LocalContext.current.getSystemService(Context.CLIPBOARD_SERVICE) as ClipboardManager
    SideEffect { state.clipboard = clipboard }
    fun titleEnter() {
        val blocks = document.getJSONArray("blocks")
        if (blocks.length() == 0) state.execute(ModernCommand.InsertBlock(session.captureBoundary(), ModernPayload.restore(modernObject("id" to UUID.randomUUID().toString(), "type" to "paragraph", "content" to JSONArray()))))
        else try { session.logicalFields(includingTitle = false).firstOrNull()?.let { state.focus = session.position(it, 0) } } catch (failure: Throwable) { state.reportError(failure) }
    }
    val documentScroll = rememberScrollState(); val dragScope = rememberCoroutineScope()
    SideEffect { state.edgeScroll = { amount -> dragScope.launch { documentScroll.scrollBy(amount) }; Unit } }
    Column(modifier.imePadding().navigationBarsPadding()) {
        if (!state.focusMode) Row(Modifier.horizontalScroll(rememberScrollState())) {
            TextButton(onClick = { state.outline = !state.outline }) { Text("Outline") }
            TextButton(onClick = { state.focusMode = true }) { Text("Focus") }
            ModernAppearanceControls(state, document.getString("documentID"), appearance)
        }
        if (state.outline && !state.focusMode) Row(Modifier.horizontalScroll(rememberScrollState())) {
            session.logicalFields(includingTitle = false).forEach { field ->
                if (field.name == "content") {
                    val address = session.resolvePosition(session.position(field, 0)).address.export()
                    fun find(values: JSONArray, path: List<String>): JSONObject? {
                        val id = path.firstOrNull() ?: return null
                        val node = (0 until values.length()).map { values.getJSONObject(it) }.firstOrNull { it.optString("id") == id } ?: return null
                        return if (path.size == 1) node else find(node.optJSONArray(path[1]) ?: return null, path.drop(2))
                    }
                    val paths = address.getJSONArray("path"); val node = find(document.getJSONArray("blocks"), listOf(address.getString("blockID")) + (0 until paths.length() - 1).map { paths.getString(it) })
                    if (node?.optString("type") == "heading") TextButton(onClick = { state.reveal(field.node) }) { Text(session.text(field).ifEmpty { "Heading" }) }
                }
            }
        }
        Column(Modifier.weight(1f).onGloballyPositioned { state.viewportFrame = it.boundsInRoot() }.verticalScroll(documentScroll).widthIn(max = if (appearance.getString("pageWidth") == "wide") 960.dp else 680.dp).align(Alignment.CenterHorizontally).padding(horizontal = 20.dp, vertical = 24.dp)) {
            ModernInput(state, ModernField(ModernNodeID.document(document.getString("documentID")), "title"), "Document title", style.copy(fontSize = (size * 2.1).sp, fontWeight = FontWeight.Bold), ::titleEnter)
            if (document.getJSONArray("blocks").length() == 0) ModernEmptyInput(state, style)
            ModernCollectionView(state, document.getJSONArray("blocks"), null, emptyList(), style, insertAsset, openReference)
            state.host.drafts.forEach { draft ->
                Text("Input retained: ${draft.optString("reason")}"); Text(draft.optString("nativeText", draft.getString("text")))
                TextButton(enabled = !state.host.readOnly, onClick = {
                    val target = ModernTextRange.restore(draft.getJSONObject("target")); val result = state.execute(if (target.start.export().getJSONObject("field").getString("name") == "title") ModernCommand.ReplaceTitle(target, draft.getString("text")) else ModernCommand.ReplaceText(target, draft.getString("text")))
                    if (result?.status in listOf(ModernResultStatus.APPLIED, ModernResultStatus.NOOP)) state.forgetDraft(draft.getString("id"))
                }) { Text("Retry retained text") }
            }
            state.host.retainedClipboard.forEach { entry -> Text("Clipboard retained: ${entry.optString("reason")}"); TextButton(enabled = !state.host.readOnly, onClick = {
                val target = ModernPasteTarget.restore(entry.getJSONObject("target")); val payload = ModernNativeClipboard.decode(entry, session); val result = state.execute(ModernCommand.Paste(target, payload))
                if (result?.status in listOf(ModernResultStatus.APPLIED, ModernResultStatus.NOOP)) state.host.retainedClipboard = state.host.retainedClipboard.filter { it.optString("id") != entry.getString("id") }
            }) { Text("Retry original paste") }
                TextButton(enabled = !state.host.readOnly, onClick = {
                    try {
                        val target = ModernPasteTarget.restore(entry.getJSONObject("target")); val payload = ModernNativeClipboard.decode(entry, session, true)
                        val result = state.execute(ModernCommand.Paste(target, payload, ModernPasteMode.PLAIN_TEXT))
                        if (result?.status in listOf(ModernResultStatus.APPLIED, ModernResultStatus.NOOP)) state.host.retainedClipboard = state.host.retainedClipboard.filter { it.optString("id") != entry.getString("id") }
                    } catch (failure: Throwable) { state.reportError(failure) }
                }) { Text("Paste retained plain text") }
            }
        }
        Row(Modifier.horizontalScroll(rememberScrollState())) {
            TextButton(onClick = { state.insertionRange = null; state.insertion = session.captureBoundary(after = session.nodes().lastOrNull()); state.query = "" }) { Text("Insert") }
            ModernFormattingMenu(state)
            TextButton(onClick = { state.linkTarget = state.textSelection; state.linkURL = ""; state.internalLink = false }) { Text("Link") }
            TextButton(enabled = session.snapshot.canUndo, onClick = { state.execute(ModernCommand.Undo) }) { Text("Undo") }
            ModernSecondaryActions(state, clipboard)
            if (state.focusMode) TextButton(onClick = { state.focusMode = false }) { Text("Leave focus") }
        }
        state.selection?.let { selected -> Row(Modifier.horizontalScroll(rememberScrollState())) {
            Text("${selected.nodes.size} selected")
            TextButton(onClick = { state.extending = !state.extending }) { Text(if (state.extending) "Finish range" else "Extend selection") }
            var converting by remember { mutableStateOf(false) }
            Box { TextButton(onClick = { converting = true }) { Text("Convert") }
                DropdownMenu(expanded = converting, onDismissRequest = { converting = false }) {
                    listOf(ModernBlockConversion.Paragraph, ModernBlockConversion.Heading(1), ModernBlockConversion.Quote, ModernBlockConversion.Callout(ModernCalloutVariant.INFO), ModernBlockConversion.List(ModernListStyle.UNORDERED), ModernBlockConversion.Code).forEach { conversion ->
                        DropdownMenuItem(text = { Text(conversion.wire().getString("type")) }, onClick = { state.execute(ModernCommand.ConvertBlocks(selected, conversion)); converting = false })
                    }
                }
            }
            var destinations by remember { mutableStateOf(false) }
            Box { TextButton(onClick = { destinations = true }) { Text("Move to") }
                DropdownMenu(expanded = destinations, onDismissRequest = { destinations = false }) {
                    DropdownMenuItem(text = { Text("Document end") }, onClick = { state.execute(ModernCommand.Move(selected, session.captureBoundary(after = session.nodes().lastOrNull()))); destinations = false })
                    val blocks = document.getJSONArray("blocks")
                    for (index in 0 until blocks.length()) { val block = blocks.getJSONObject(index)
                        if (block.optString("type") == "columns") { val columns = block.getJSONArray("columns")
                            for (column in 0 until columns.length()) { val container = columns.getJSONObject(column)
                                DropdownMenuItem(text = { Text("Column ${column + 1}") }, onClick = { val collection = ModernCollection.Owned(session.node(block.getString("id"), listOf("columns", container.getString("id"))), ModernCollectionField.CHILDREN); state.execute(ModernCommand.Move(selected, session.captureBoundary(collection, session.nodes(collection).lastOrNull()))); destinations = false })
                            }
                        }
                    }
                }
            }
            TextButton(onClick = { state.move(false) }) { Text("Move up") }; TextButton(onClick = { state.move(true) }) { Text("Move down") }
            TextButton(onClick = { state.execute(ModernCommand.Duplicate(selected, session.captureBoundary(session.parentCollection(selected.nodes.last()), selected.nodes.last()), selected.nodes.map { UUID.randomUUID().toString() })) }) { Text("Duplicate") }
            TextButton(onClick = { state.execute(ModernCommand.Delete(ModernDeleteTarget(selected))); state.selection = null }) { Text("Delete") }
            TextButton(onClick = { state.selection = null; state.extending = false; state.focus = state.textSelection?.end }) { Text("Cancel selection") }
        } }
    }
    state.insertion?.let { boundary -> AlertDialog(onDismissRequest = { state.focus = state.insertionRange?.end; state.insertion = null; state.insertionRange = null }, title = { Text("Insert block") },
        text = { Column(Modifier.verticalScroll(rememberScrollState())) {
            TextField(value = state.query, onValueChange = { state.query = it }, label = { Text("Search blocks") })
            session.insertionCatalog(state.query).forEach { descriptor -> TextButton(onClick = {
                if (descriptor.requiresHost) { if (insertAssetSelection != null) insertAssetSelection(descriptor, boundary, state.insertionRange) else insertAsset?.invoke(descriptor, boundary) }
                else {
                    val count = when (descriptor.blockType) { "list" -> 1; "table" -> 6; "columns" -> 2; else -> 0 }
                    val block = session.insertionValue(descriptor.id, UUID.randomUUID().toString(), List(count) { UUID.randomUUID().toString() }).export()
                    val range = state.insertionRange
                    if (range != null) state.execute(ModernCommand.Paste(ModernPasteTarget.Range(range), session.clipboardParts(JSONArray().put(modernObject("node" to modernObject("kind" to "block", "value" to block)))), focusInserted = true))
                    else if (descriptor.blockType == "columns") state.execute(ModernCommand.CreateColumns(ModernCreateColumnsTarget.Boundary(boundary), ModernPayload.restore(block)))
                    else state.execute(ModernCommand.InsertBlock(boundary, ModernPayload.restore(block)))
                }
                state.insertion = null; state.insertionRange = null
            }) { Column { Text(descriptor.title); Text(descriptor.description, style = MaterialTheme.typography.bodySmall) } } }
        } }, confirmButton = {}, dismissButton = { TextButton(onClick = { state.focus = state.insertionRange?.end; state.insertion = null; state.insertionRange = null }) { Text("Cancel") } }) }
    state.linkTarget?.let { range -> ModernLinkPicker(state, range) }

}

@Composable private fun ModernCollectionView(state: ModernBlockEditorState, values: JSONArray, rootID: String?, path: List<String>, style: TextStyle,
    insertAsset: ((ModernInsertionDescriptor, ModernBoundary) -> Unit)?, openReference: ((String) -> Unit)?) {
    for (index in 0 until values.length()) {
        val value = values.getJSONObject(index); val root = rootID ?: value.getString("id"); val current = if (rootID == null) emptyList() else path + value.getString("id")
        val node = state.session.node(root, current)
        key(node.export().toString()) {
            val nodeKey = node.export().toString()
            DisposableEffect(nodeKey) { onDispose { state.blockFrames.remove(nodeKey) } }
            Column {
                if (state.dropNode == nodeKey && state.dropBefore) HorizontalDivider(color = MaterialTheme.colorScheme.primary, thickness = 2.dp)
                Row(Modifier.fillMaxWidth().onGloballyPositioned { state.blockFrames[nodeKey] = Triple(node, state.session.parentCollection(node), it.boundsInRoot()) }.background(if (state.selection?.nodes?.any { it.export().toString() == node.export().toString() } == true) MaterialTheme.colorScheme.primaryContainer else androidx.compose.ui.graphics.Color.Transparent).padding(vertical = 6.dp)) {
            TextButton(onClick = { state.select(node) }, modifier = Modifier.width(44.dp).heightIn(min = 44.dp).pointerInput(nodeKey, state.host.readOnly) {
                if (!state.host.readOnly) detectDragGesturesAfterLongPress(onDragStart = { position ->
                    try { state.dragSelection = state.session.captureNodes(if (state.selection?.nodes?.any { it.export().toString() == nodeKey } == true) state.selection!!.nodes else listOf(node))
                        state.dragPosition = (state.blockFrames[nodeKey]?.third?.topLeft ?: Offset.Zero) + position
                    } catch (failure: Throwable) { state.reportError(failure) }
                }, onDragCancel = { state.cancelDrag() }, onDragEnd = {
                    val selection = state.dragSelection; val boundary = state.dropBoundary; state.cancelDrag()
                    if (selection != null && boundary != null) state.execute(ModernCommand.Move(selection, boundary))
                }) { change, amount -> change.consume(); state.dragPosition?.let { state.previewDrop(it + amount) } }
            }) { Text("⋮") }
            Column(Modifier.weight(1f)) {
                when (value.optString("type")) {
                    "columns" -> {
                        val columns = value.getJSONArray("columns")
                        var preview by remember(node.export().toString()) { mutableStateOf<Int?>(null) }
                        if (columns.length() == 2) BoxWithConstraints {
                            val split = preview ?: value.optInt("splitBasisPoints", 5000); val stacked = maxWidth < (style.fontSize.value * LocalDensity.current.fontScale * 40 + 24).dp
                            val latestColumns by rememberUpdatedState(columns); val latestStyle by rememberUpdatedState(style)
                            val contents = remember(node.export().toString()) { (0..1).map { index -> movableContentOf {
                                // Captured container IDs are immutable; shared values are
                                // refreshed by the recursive renderer on each snapshot.
                                val container = latestColumns.getJSONObject(index)
                                ModernCollectionView(state, container.getJSONArray("children"), root, current + "columns" + container.getString("id") + "children", latestStyle, insertAsset, openReference)
                            } } }
                            Column { if (stacked) Column { contents[0](); contents[1]() } else Row(horizontalArrangement = Arrangement.spacedBy(24.dp)) {
                                Column(Modifier.weight(split / 10000f)) { contents[0]() }; Column(Modifier.weight(1 - split / 10000f)) { contents[1]() }
                            }
                            Column(Modifier.padding(top = 8.dp)) { Slider(value = split.toFloat(), onValueChange = { preview = it.toInt() }, valueRange = 1000f..9000f, onValueChangeFinished = { state.execute(ModernCommand.ResizeColumns(ModernColumnTarget(node), preview ?: split)); preview = null }) } }
                        }
                    }
                    "table" -> Column(Modifier.horizontalScroll(rememberScrollState())) {
                        val rows = value.getJSONArray("rows")
                        for (r in 0 until rows.length()) { val row = rows.getJSONObject(r); val cells = row.getJSONArray("cells"); val rowNode = state.session.node(root, current + "rows" + row.getString("id"))
                            Row { for (c in 0 until cells.length()) { val cell = cells.getJSONObject(c); val cellNode = state.session.node(root, current + "rows" + row.getString("id") + "cells" + cell.getString("id")); val capturedCell = state.session.captureTableTarget(node, rowNode, cellNode)
                                Column(Modifier.width(160.dp).padding(8.dp)) {
                                    ModernInput(state, state.session.field(cellNode), if (cell.optBoolean("header")) "Table header" else "Table cell", style)
                                    TextButton(onClick = { state.execute(ModernCommand.TableStructure(capturedCell, ModernTableAction.INSERT_ROW, List(cells.length() + 1) { UUID.randomUUID().toString() })) }) { Text("Add row") }
                                    TextButton(onClick = { state.execute(ModernCommand.TableStructure(capturedCell, ModernTableAction.INSERT_COLUMN, List(rows.length()) { UUID.randomUUID().toString() })) }) { Text("Add column") }
                                    TextButton(enabled = rows.length() > 1, onClick = { state.execute(ModernCommand.TableStructure(capturedCell, ModernTableAction.REMOVE_ROW)) }) { Text("Remove row") }
                                    TextButton(enabled = cells.length() > 1, onClick = { state.execute(ModernCommand.TableStructure(capturedCell, ModernTableAction.REMOVE_COLUMN)) }) { Text("Remove column") }
                                    TextButton(onClick = { state.execute(ModernCommand.TableStructure(capturedCell, ModernTableAction.SET_HEADER, header = !cell.optBoolean("header"))) }) { Text(if (cell.optBoolean("header")) "Make body cell" else "Make header") }
                                }
                            } }
                        }
                    }
                    "list" -> {
                        val items = value.getJSONArray("items")
                        ModernListItems(state, items, root, current + "items", value.optString("style"), style)
                        if (items.length() == 0) TextButton(onClick = {
                            val collection = ModernCollection.Owned(node, ModernCollectionField.ITEMS)
                            val item = modernObject("id" to UUID.randomUUID().toString(), "content" to JSONArray(), "checked" to false)
                            val payload = state.session.clipboardParts(JSONArray().put(modernObject("node" to modernObject("kind" to "item", "value" to item))))
                            state.execute(ModernCommand.Paste(ModernPasteTarget.Boundary(state.session.captureListBoundary(collection)), payload))
                        }) { Text("Add list item") }
                    }
                    "toggle" -> {
                        val nodeKey = node.export().toString(); val expanded = !state.collapsed.contains(nodeKey)
                        TextButton(onClick = { if (expanded) state.focus = state.session.position(state.session.field(node, "summary"), 0); state.collapsed = if (expanded) state.collapsed + nodeKey else state.collapsed - nodeKey }) { Text(if (expanded) "Collapse" else "Expand") }
                        ModernInput(state, state.session.field(node, "summary"), "Toggle title", style) { state.collapsed = state.collapsed - nodeKey; state.execute(ModernCommand.InsertBlock(state.session.captureBoundary(ModernCollection.Owned(node, ModernCollectionField.CHILDREN)), state.session.insertionValue("paragraph", UUID.randomUUID().toString()))) }
                        if (expanded) { ModernCollectionView(state, value.optJSONArray("children") ?: JSONArray(), root, current + "children", style, insertAsset, openReference)
                            TextButton(onClick = { state.insertion = state.session.captureBoundary(ModernCollection.Owned(node, ModernCollectionField.CHILDREN)) }) { Text("Add inside toggle") } }
                    }
                    "code" -> {
                        var languages by remember { mutableStateOf(false) }
                        TextButton(onClick = { languages = true }) { Text(value.optString("language", "Plain text")) }
                        DropdownMenu(expanded = languages, onDismissRequest = { languages = false }) {
                            (listOf("") + state.session.capabilities().export().getJSONArray("codeLanguages").let { values -> (0 until values.length()).map { values.getString(it) } }).forEach { language -> DropdownMenuItem(text = { Text(language.ifEmpty { "Plain text" }) }, onClick = { state.execute(ModernCommand.CodeProperties(state.session.captureCodeTarget(node), language.ifEmpty { null })); languages = false }) }
                        }
                        TextButton(onClick = { try {
                            val field = state.session.field(node, "code"); val range = state.session.captureTextRange(field, 0, state.session.text(field).length)
                            val manager = state.clipboard
                            if (manager != null) ModernNativeClipboard.publish(manager, state.session.copy(ModernDeleteTarget(ranges = listOf(range))))
                        } catch (failure: Throwable) { state.reportError(failure) } }) { Text("Copy code") }
                        ModernInput(state, state.session.field(node, "code"), "Code", style.copy(fontFamily = FontFamily.Monospace))
                    }
                    "image" -> { ModernMediaView(state, node, value, openReference); ModernInput(state, state.session.field(node, "caption"), "Image caption", style) }
                    "file", "embed" -> ModernMediaView(state, node, value, openReference)
                    "divider" -> HorizontalDivider()
                    else -> if (value.opt("content") is JSONArray) ModernInput(state, state.session.field(node), "Block text", if (value.optString("type") == "heading") style.copy(fontSize = (style.fontSize.value * 1.55).sp, fontWeight = FontWeight.Bold) else style) { state.textSelection?.let { state.execute(ModernCommand.SplitBlock(it, UUID.randomUUID().toString())) } } else Text("Unsupported content preserved")
                }
            }
                }
                if (state.dropNode == nodeKey && !state.dropBefore) HorizontalDivider(color = MaterialTheme.colorScheme.primary, thickness = 2.dp)
            }
        }
    }
}

@Composable private fun ModernEmptyInput(state: ModernBlockEditorState, style: TextStyle) {
    var value by remember(state.session) { mutableStateOf(TextFieldValue()) }
    val id = remember(state.session) { UUID.randomUUID().toString() }
    val boundary = remember(state.session) { state.session.captureBoundary() }
    var release by remember(state.session) { mutableStateOf<(() -> Unit)?>(null) }
    DisposableEffect(id) { onDispose { state.composition(id, false); release?.invoke() } }
    BasicTextField(value = value, readOnly = state.host.readOnly, textStyle = style,
        modifier = Modifier.fillMaxWidth().heightIn(min = 44.dp).semantics { contentDescription = "Start writing" },
        decorationBox = { inner -> if (value.text.isEmpty()) Text("Start writing…"); inner() }, onValueChange = { next ->
            if (next.composition != null && release == null) { release = state.session.holdRemoteChanges(); state.composition(id, true) }
            if (next.composition == null) state.composition(id, false)
            value = next
            if (next.text.isNotEmpty()) {
                try {
                    val payload = state.session.clipboardText(next.text, "multiline")
                    val retained = modernObject("id" to id, "target" to ModernPasteTarget.Boundary(boundary).wire(), "clipboard" to payload, "reason" to "pendingEmptyInput")
                    state.host.retainedClipboard = state.host.retainedClipboard.filter { it.optString("id") != id } + retained
                    if (next.composition == null) {
                        val result = state.execute(ModernCommand.Paste(ModernPasteTarget.Boundary(boundary), payload))
                        if (result?.status in listOf(ModernResultStatus.APPLIED, ModernResultStatus.NOOP)) state.host.retainedClipboard = state.host.retainedClipboard.filter { it.optString("id") != id }
                    }
                } catch (failure: Throwable) { state.reportError(failure) }
            }
            if (next.composition == null) {
                if (next.text.isEmpty()) state.host.retainedClipboard = state.host.retainedClipboard.filter { it.optString("id") != id }
                val finish = release; release = null; finish?.invoke()
            }
        })
}

@Composable private fun ModernListItems(state: ModernBlockEditorState, values: JSONArray, root: String, path: List<String>, listStyle: String, style: TextStyle) {
    for (index in 0 until values.length()) {
        val value = values.getJSONObject(index); val current = path + value.getString("id"); val node = state.session.node(root, current)
        key(node.export().toString()) {
            Column {
                Row {
                    if (listStyle == "todo") Checkbox(checked = value.optBoolean("checked"), enabled = !state.host.readOnly, onCheckedChange = { checked -> state.execute(ModernCommand.ListStructure(ModernListTarget(state.session.captureListNodes(listOf(node))), ModernListOperation.SetChecked(checked))) })
                    else Text(if (listStyle == "ordered") "${index + 1}." else "•")
                    Column(Modifier.weight(1f)) {
                        ModernInput(state, state.session.field(node), "List item", style) { state.textSelection?.let { state.execute(ModernCommand.SplitBlock(it, UUID.randomUUID().toString())) } }
                        Row {
                            TextButton(onClick = { state.execute(ModernCommand.ListStructure(ModernListTarget(state.session.captureListNodes(listOf(node))), ModernListOperation.Indent)) }) { Text("Indent item") }
                            TextButton(onClick = { state.execute(ModernCommand.ListStructure(ModernListTarget(state.session.captureListNodes(listOf(node))), ModernListOperation.Outdent)) }) { Text("Outdent item") }
                        }
                        value.optJSONArray("children")?.let { children -> Column(Modifier.padding(start = 16.dp)) { ModernListItems(state, children, root, current + "children", listStyle, style) } }
                    }
                }
            }
        }
    }
}


@Composable private fun ModernAppearanceControls(state: ModernBlockEditorState, documentID: String, appearance: JSONObject) {
    var menu by remember { mutableStateOf<String?>(null) }
    listOf("fontFamily" to "Font", "fontSize" to "Text size", "pageWidth" to "Page width").forEach { (field, label) ->
        Box {
            TextButton(enabled = !state.host.readOnly, onClick = { menu = field }) { Text(label) }
            DropdownMenu(expanded = menu == field, onDismissRequest = { menu = null }) {
                val values = when (field) { "fontFamily" -> ModernFontFamily.entries.map { it.wireValue }; "fontSize" -> ModernFontSize.entries.map { it.wireValue }; else -> ModernPageWidth.entries.map { it.wireValue } }
                values.forEach { value -> DropdownMenuItem(text = { Text(value.replaceFirstChar { it.uppercase() } + if (appearance.getString(field) == value) " ✓" else "") }, onClick = {
                    state.execute(when (field) { "fontFamily" -> ModernCommand.Appearance.FontFamily(documentID, ModernFontFamily.entries.first { it.wireValue == value }); "fontSize" -> ModernCommand.Appearance.FontSize(documentID, ModernFontSize.entries.first { it.wireValue == value }); else -> ModernCommand.Appearance.PageWidth(documentID, ModernPageWidth.entries.first { it.wireValue == value }) }); menu = null
                }) }
            }
        }
    }
}

@Composable private fun ModernSecondaryActions(state: ModernBlockEditorState, clipboard: ClipboardManager) {
    var opened by remember { mutableStateOf(false) }
    var colors by remember { mutableStateOf<ModernSemanticTarget?>(null) }
    val session = state.session
    fun target(): ModernDeleteTarget = ModernDeleteTarget(state.selection, state.textSpan.ifEmpty { state.textSelection?.let { listOf(it) } ?: emptyList() })
    fun paste(plainOnly: Boolean) {
        try {
            val range = state.textSelection ?: return; val capturedClipboard = ModernNativeClipboard.capture(clipboard) ?: return
            val captured = if (state.textSpan.isEmpty()) range else ModernTextRange.restore(modernObject("start" to state.textSpan.first().start, "end" to state.textSpan.last().end, "observed" to state.textSpan.first().export().getJSONArray("observed")))
            val pasteTarget = ModernPasteTarget.Range(captured); val id = UUID.randomUUID().toString()
            val entry = capturedClipboard.put("id", id).put("target", pasteTarget.wire()).put("reason", "awaitingPaste")
            require(state.host.retainedClipboard.size < 64 && JSONArray(state.host.retainedClipboard + entry).toString().length <= 64_000_000)
            state.host.retainedClipboard = state.host.retainedClipboard + entry
            val payload = ModernNativeClipboard.decode(entry, session, plainOnly)
            val result = state.execute(ModernCommand.Paste(pasteTarget, payload, if (plainOnly) ModernPasteMode.PLAIN_TEXT else ModernPasteMode.RICH))
            if (result?.status in listOf(ModernResultStatus.APPLIED, ModernResultStatus.NOOP)) state.host.retainedClipboard = state.host.retainedClipboard.filter { it.optString("id") != id }
        } catch (failure: Throwable) { state.reportError(failure) }
    }
    Box {
        TextButton(onClick = { opened = true }) { Text("More") }
        DropdownMenu(expanded = opened, onDismissRequest = { opened = false }) {
            DropdownMenuItem(text = { Text("Redo") }, enabled = !state.host.readOnly && session.snapshot.canRedo, onClick = { state.execute(ModernCommand.Redo); opened = false })
            DropdownMenuItem(text = { Text("Copy") }, onClick = { try { ModernNativeClipboard.publish(clipboard, session.copy(target())) } catch (failure: Throwable) { state.reportError(failure) }; opened = false })
            DropdownMenuItem(text = { Text("Cut") }, enabled = !state.host.readOnly, onClick = {
                try { val preparation = session.prepareCut(target()); val published = try { ModernNativeClipboard.publish(clipboard, preparation.clipboard) } catch (_: Throwable) { false }; session.finishCut(preparation, published && state.host.active && !state.host.readOnly) } catch (failure: Throwable) { state.reportError(failure) }; opened = false
            })
            DropdownMenuItem(text = { Text("Paste") }, enabled = !state.host.readOnly, onClick = { paste(false); opened = false })
            DropdownMenuItem(text = { Text("Paste plain text") }, enabled = !state.host.readOnly, onClick = { paste(true); opened = false })
            DropdownMenuItem(text = { Text("Select block") }, onClick = { state.textSelection?.let { state.select(it.start.export().getJSONObject("field").getJSONObject("node").let { ModernNodeID.restore(it) }) }; opened = false })
            DropdownMenuItem(text = { Text("Color") }, enabled = !state.host.readOnly, onClick = { colors = state.selection?.let { ModernSemanticTarget.Nodes(it) } ?: state.textSelection?.let { ModernSemanticTarget.Range(it) }; opened = false })
            if (state.textSpan.isNotEmpty()) DropdownMenuItem(text = { Text("Cancel text selection") }, onClick = { state.textSpan = emptyList(); opened = false })
        }
    }
    colors?.let { captured -> AlertDialog(onDismissRequest = { colors = null }, title = { Text("Color") }, text = { Column {
        ModernSemanticKind.entries.forEach { kind ->
            val status = try { session.semanticState(captured, kind).export() } catch (_: Throwable) { JSONObject() }
            Text((if (kind == ModernSemanticKind.INK) "Text color" else "Background") + ": " + if (status.has("mixed")) "Mixed" else status.optJSONObject("role")?.optString("_0") ?: "Default")
            Row(Modifier.horizontalScroll(rememberScrollState())) { ModernSemanticRole.entries.forEach { role -> TextButton(onClick = { state.execute(ModernCommand.SetSemanticColor(captured, kind, role)) }) { Text(role.wireValue) } } }
            TextButton(onClick = { state.execute(ModernCommand.SetSemanticColor(captured, kind, null)) }) { Text("Reset") }
        }
    } }, confirmButton = { TextButton(onClick = { colors = null }) { Text("Done") } }) }
}
