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
class WritingParagraphEditorState(val session: WritingSession, scope: kotlinx.coroutines.CoroutineScope,
    retainDrafts: (List<WritingInputDraft>) -> Unit, private val report: (Exception) -> Unit = {},
) : java.io.Closeable {
    var readOnly by mutableStateOf(false)
    internal val inputs = WritingEditorInputs(session, scope, { !readOnly }, retainDrafts, report)
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

/** Additive paragraph-only surface for an explicit shared-writing v4 epoch.
 * Lists, cross-block selection, structured paste, assets and accessibility
 * acceptance remain separate work. Existing BlockEditor is unchanged. */
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
                if (node?.optString("type") == "paragraph") {
                    WritingTextField(session, inputs, identity, readOnly, { currentError(it) })
                } else Text("${node?.optString("type") ?: "Block"}: ${node?.optString("id") ?: address.blockID}")
            }
        }
    }
}

@Composable private fun WritingTextField(session: WritingSession, inputs: WritingEditorInputs,
    identity: NodeIdentity, readOnly: Boolean, report: (Exception) -> Unit) {
    val currentReadOnly by rememberUpdatedState(readOnly)
    val currentError by rememberUpdatedState(report)
    val origin = writingKey(session.textAddress(identity))
    val revision = inputs.revision(origin)
    val binding = remember(inputs, origin, revision) { inputs.bind(identity) }
    val input = binding.input
    val focus = remember(input) { FocusRequester() }
    val nativeFocus = LocalFocusManager.current
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
            }
        } catch (error: Exception) { currentError(error) }
    }
    val blocked = readOnly || request != null
    Column {
        // A replaced Foundation node cannot reauthorize retained native callbacks.
        key(revision) {
            OutlinedTextField(value = input.value,
                onValueChange = { if (!currentReadOnly) binding.update(it) }, readOnly = blocked,
                modifier = Modifier.fillMaxWidth().focusRequester(focus)
                    .onFocusChanged { focused = it.isFocused; inputs.focusChanged(binding, it.isFocused) }
                    .testTag("writing-text:${input.identity.wire.toString()}")
                    .onPreviewKeyEvent { event ->
                        if (event.type != KeyEventType.KeyDown || currentReadOnly || !binding.current() || request != null) false
                        else when (event.key) {
                            Key.Enter -> { invoke(if (event.isShiftPressed) 1 else 0); true }
                            Key.Backspace -> if (input.value.selection.collapsed && input.value.selection.min == 0) { invoke(2); true } else false
                            else -> false
                        }
                    }, label = { Text("Paragraph") }, textStyle = MaterialTheme.typography.bodyLarge,
                keyboardOptions = KeyboardOptions(imeAction = ImeAction.Next), keyboardActions = KeyboardActions(onNext = { invoke(0) }),
                visualTransformation = VisualTransformation { text ->
                    val rich = runCatching { input.readNodes() }.getOrNull()
                    TransformedText(if (input.value.composition == null && plainText(rich) == text.text) styledInline(rich) else text, OffsetMapping.Identity)
                })
        }
        if (focused) Row {
            TextButton(enabled = !blocked, onClick = { invoke(0) }, modifier = Modifier.testTag("writing-enter")) { Text("Enter") }
            TextButton(enabled = !blocked, onClick = { invoke(1) }, modifier = Modifier.testTag("writing-soft-break")) { Text("Soft break") }
            TextButton(enabled = !blocked && input.value.selection.collapsed && input.value.selection.min == 0,
                onClick = { invoke(2) }, modifier = Modifier.testTag("writing-merge")) { Text("Merge previous") }
        }
        input.failedReason?.let { Text(it) }
    }
}
