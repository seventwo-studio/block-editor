package studio.seventwo.blockeditor

import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.focus.focusProperties
import androidx.compose.ui.focus.onFocusChanged
import androidx.compose.ui.input.key.*
import androidx.compose.ui.platform.LocalFocusManager
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.input.OffsetMapping
import androidx.compose.ui.text.input.TransformedText
import androidx.compose.ui.text.input.VisualTransformation
import java.util.UUID

/** The host retains this owner across disposal failures, and closes the native
 * surface before closing its session. A failed retention callback leaves drafts,
 * held packets and the owner lease available through pendingDrafts()/close(). */
class WritingParagraphEditorState private constructor(val session: WritingSession, scope: kotlinx.coroutines.CoroutineScope,
    retainDrafts: (List<WritingInputDraft>) -> Unit, private val report: (Exception) -> Unit,
    enableCollections: Boolean,
) : java.io.Closeable {
    constructor(session: WritingSession, scope: kotlinx.coroutines.CoroutineScope,
        retainDrafts: (List<WritingInputDraft>) -> Unit, report: (Exception) -> Unit = {},
    ) : this(session, scope, retainDrafts, report, false)
    companion object {
        internal fun forCollections(session: WritingSession, scope: kotlinx.coroutines.CoroutineScope,
            retainDrafts: (List<WritingInputDraft>) -> Unit, report: (Exception) -> Unit,
        ) = WritingParagraphEditorState(session, scope, retainDrafts, report, true)
    }
    var readOnly by mutableStateOf(false)
    var pastePolicy by mutableStateOf(WritingPastePolicy())
    internal val inputs = WritingEditorInputs(session, scope, { !readOnly }, retainDrafts, report, { pastePolicy }, enableCollections)
    private var surfaceAttached = false
    internal fun attachSurface() { check(!surfaceAttached) { "One native surface per input owner" }; surfaceAttached = true }
    internal fun detachSurface() { surfaceAttached = false; try { close() } catch (error: Exception) { report(error) } }
    fun pendingDrafts(): List<WritingInputDraft> = inputs.exportDrafts()
    internal fun reportError(error: Exception) = report(error)
    override fun close() = inputs.close()
}

@Composable fun rememberWritingParagraphEditorState(session: WritingSession,
    retainDrafts: (List<WritingInputDraft>) -> Unit, reportError: (Exception) -> Unit = {},
): WritingParagraphEditorState {
    val currentRetain by rememberUpdatedState(retainDrafts)
    val currentError by rememberUpdatedState(reportError)
    val scope = rememberCoroutineScope()
    return remember(session, scope) { WritingParagraphEditorState(session, scope, { currentRetain(it) }, { currentError(it) }) }
}

/** Additive root rich-inline surface for explicitly selected writing v4/v5/v6.
 * Native commands share composition finalization and opaque origin leases.
 * Nested/list/table authoring and installed accessibility remain separate work. */
@Composable fun WritingParagraphEditor(state: WritingParagraphEditorState,
    modifier: Modifier = Modifier, reportError: (Exception) -> Unit = state::reportError,
) {
    val session = state.session; val inputs = state.inputs; val readOnly = state.readOnly
    val currentError by rememberUpdatedState(reportError)
    val nativeFocus = LocalFocusManager.current
    DisposableEffect(state) { state.attachSurface(); onDispose { state.detachSurface() } }
    val snapshot = session.snapshot
    val roots = remember(session, snapshot) { session.collectionNodes(NodeCollection.ROOT) }
    Column(modifier) {
        Row {
            TextButton(enabled = !readOnly && snapshot.optBoolean("canUndo") && inputs.focusRequest == null,
                onClick = { try { inputs.history({ nativeFocus.clearFocus(force = true) }, false) } catch (error: Exception) { currentError(error) } },
                modifier = Modifier.testTag("writing-undo")) { Text("Undo") }
            TextButton(enabled = !readOnly && snapshot.optBoolean("canRedo") && inputs.focusRequest == null,
                onClick = { try { inputs.history({ nativeFocus.clearFocus(force = true) }, true) } catch (error: Exception) { currentError(error) } },
                modifier = Modifier.testTag("writing-redo")) { Text("Redo") }
        }
        roots.forEach { identity ->
            val address = session.nodeAddress(identity)
            val node = fieldValue(snapshot, address.blockID, address.path) as? org.json.JSONObject
            key(writingCanonical(identity.wire)) {
                if (node?.optString("type") in setOf("paragraph", "heading", "quote", "callout")) {
                    WritingTextField(session, inputs, identity, readOnly, { currentError(it) })
                } else Text("${node?.optString("type") ?: "Block"}: ${node?.optString("id") ?: address.blockID}")
            }
        }
    }
}

@Composable internal fun WritingTextField(session: WritingSession, inputs: WritingEditorInputs,
    identity: NodeIdentity, readOnly: Boolean, report: (Exception) -> Unit,
    field: String = "content", label: String = "Paragraph", blockConversions: Boolean = true) {
    val currentReadOnly by rememberUpdatedState(readOnly)
    val currentError by rememberUpdatedState(report)
    val origin = writingKey(session.textAddress(identity, field))
    val revision = inputs.revision(origin)
    val binding = remember(inputs, origin, revision) { inputs.bind(identity, field) }
    val input = binding.input
    val focus = remember(input) { FocusRequester() }
    val nativeFocus = LocalFocusManager.current
    val context = androidx.compose.ui.platform.LocalContext.current
    val clipboard = remember(context) { context.getSystemService(android.content.Context.CLIPBOARD_SERVICE) as android.content.ClipboardManager }
    var focused by remember(input) { mutableStateOf(false) }
    val request = inputs.focusRequest
    DisposableEffect(binding) { inputs.attach(binding); onDispose { inputs.detach(binding) } }
    LaunchedEffect(binding, request, input.value) {
        if (request?.key == origin && binding.current()) {
            val start = session.resolvePosition(request.range.start)
            val end = session.resolvePosition(request.range.end)
            val desired = androidx.compose.ui.text.TextRange(start.offset, end.offset)
            if (input.value.selection != desired || input.value.text != input.readText()) {
                // Recompose the actual controlled field with the anchored value
                // before requesting native focus; its initial caret must not win.
                input.adopt(request.range)
                return@LaunchedEffect
            }
            focus.requestFocus()
            inputs.consume(request, binding)
        }
    }
    fun invoke(command: Int) {
        if (currentReadOnly || !binding.current()) return
        try {
            val revoke = { nativeFocus.clearFocus(force = true) }
            when (command) {
                0 -> inputs.enter(binding, revoke, "p-${UUID.randomUUID()}")
                1 -> inputs.softBreak(binding, revoke)
                2 -> inputs.mergePrevious(binding, revoke)
                3 -> inputs.copy(binding, revoke) { WritingNativeClipboard.write(clipboard, it) }
                4 -> inputs.cut(binding, revoke) { WritingNativeClipboard.write(clipboard, it) }
                5 -> WritingNativeClipboard.read(clipboard, session, input.plainField)?.let { inputs.paste(binding, revoke, it) }
                6 -> inputs.format(binding, revoke, "bold", org.json.JSONObject().put("type", "bold"))
                7 -> inputs.format(binding, revoke, "italic", org.json.JSONObject().put("type", "italic"))
                8 -> inputs.convert(binding, revoke, WritingBlockTarget("heading", level = 2))
                9 -> inputs.convert(binding, revoke, WritingBlockTarget("paragraph"))
                10 -> if (!input.plainField) WritingNativeClipboard.readMarkdown(clipboard, session)?.let { inputs.paste(binding, revoke, it) }
            }
        } catch (error: Exception) { currentError(error) }
    }
    val blocked = readOnly || request != null
    // Retire the command semantics nodes with their immutable native binding.
    // Material OnClick wrappers must not reauthorize an old action after handoff.
    key(revision) {
      Column {
            OutlinedTextField(value = input.value,
                onValueChange = { if (!currentReadOnly) binding.update(it) }, readOnly = blocked,
                modifier = Modifier.fillMaxWidth().focusProperties {
                    // A native node replacement must not give its pending caret
                    // to a sibling and start an unrelated keyboard composition.
                    canFocus = inputs.focusRequest?.key?.let { it == origin } ?: true
                }.focusRequester(focus)
                    .onFocusChanged { focused = it.isFocused; inputs.focusChanged(binding, it.isFocused) }
                    .testTag("writing-text:${input.identity.wire.toString()}")
                    .onPreviewKeyEvent { event ->
                        if (event.type != KeyEventType.KeyDown || currentReadOnly || !binding.current() || request != null) false
                        else when {
                            event.isCtrlPressed && event.key == Key.C -> { invoke(3); true }
                            event.isCtrlPressed && event.key == Key.X -> { invoke(4); true }
                            event.isCtrlPressed && event.key == Key.V -> { invoke(5); true }
                            !input.plainField && event.isCtrlPressed && event.key == Key.B -> { invoke(6); true }
                            !input.plainField && event.isCtrlPressed && event.key == Key.I -> { invoke(7); true }
                            event.key == Key.Enter -> { invoke(if (event.isShiftPressed) 1 else 0); true }
                            event.key == Key.Backspace -> if (inputs.mergesParagraph(binding) && input.value.selection.collapsed && input.value.selection.min == 0) { invoke(2); true } else false
                            else -> false
                        }
                    }, label = { Text(label) }, textStyle = MaterialTheme.typography.bodyLarge,
                keyboardOptions = KeyboardOptions(imeAction = ImeAction.Next), keyboardActions = KeyboardActions(onNext = { invoke(0) }),
                visualTransformation = VisualTransformation { text ->
                    val rich = if (input.plainField) null else runCatching { input.readNodes() }.getOrNull()
                    TransformedText(if (!input.plainField && input.value.composition == null && plainText(rich) == text.text) styledInline(rich) else text, OffsetMapping.Identity)
                })
        if (focused) Row {
            TextButton(enabled = !blocked, onClick = { invoke(0) }, modifier = Modifier.testTag("writing-enter")) { Text("Enter") }
            TextButton(enabled = !blocked, onClick = { invoke(1) }, modifier = Modifier.testTag("writing-soft-break")) { Text("Soft break") }
            TextButton(enabled = !blocked && inputs.mergesParagraph(binding) && input.value.selection.collapsed && input.value.selection.min == 0,
                onClick = { invoke(2) }, modifier = Modifier.testTag("writing-merge")) { Text("Merge previous") }
        }
        if (focused) Column {
            Row {
                TextButton(enabled = !blocked, onClick = { invoke(3) }, modifier = Modifier.testTag("writing-copy")) { Text("Copy") }
                TextButton(enabled = !blocked, onClick = { invoke(4) }, modifier = Modifier.testTag("writing-cut")) { Text("Cut") }
                TextButton(enabled = !blocked, onClick = { invoke(5) }, modifier = Modifier.testTag("writing-paste")) { Text("Paste") }
                if (!input.plainField) TextButton(enabled = !blocked, onClick = { invoke(10) }, modifier = Modifier.testTag("writing-paste-markdown")) { Text("Paste Markdown") }
            }
            if (!input.plainField) Row {
                TextButton(enabled = !blocked, onClick = { invoke(6) }, modifier = Modifier.testTag("writing-bold")) { Text("Bold") }
                TextButton(enabled = !blocked, onClick = { invoke(7) }, modifier = Modifier.testTag("writing-italic")) { Text("Italic") }
            }
            if (blockConversions && !input.plainField) Row {
                TextButton(enabled = !blocked, onClick = { invoke(8) }, modifier = Modifier.testTag("writing-heading")) { Text("Heading") }
                TextButton(enabled = !blocked, onClick = { invoke(9) }, modifier = Modifier.testTag("writing-paragraph")) { Text("Paragraph") }
            }
        }
        input.failedReason?.let { Text(it) }
      }
    }
}
