package studio.seventwo.blockeditor

import android.accessibilityservice.AccessibilityServiceInfo
import android.content.Context
import android.content.pm.ApplicationInfo
import android.graphics.Rect
import android.os.Build
import android.os.ParcelFileDescriptor
import android.os.Process
import android.os.SystemClock
import android.provider.Settings
import android.view.InputDevice
import android.view.MotionEvent
import android.view.accessibility.AccessibilityNodeInfo
import android.view.accessibility.AccessibilityWindowInfo
import android.view.inputmethod.InputMethodManager
import androidx.activity.ComponentActivity
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.runtime.SideEffect
import androidx.compose.runtime.mutableStateOf
import androidx.compose.ui.semantics.SemanticsProperties
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.createAndroidComposeRule
import androidx.compose.ui.text.TextRange
import androidx.compose.ui.text.input.TextFieldValue
import androidx.test.platform.app.InstrumentationRegistry
import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Assume.assumeTrue
import org.junit.Rule
import org.junit.Test
import java.io.File

/** Installed API26 LatinIME driving the explicit shared-writing v4 surface.
 * No replacement IME, interceptors, composing setters or semantic toolbar actions. */
@OptIn(ExperimentalTestApi::class)
class WritingBuiltinImeTest {
    @get:Rule val compose = createAndroidComposeRule<ComponentActivity>()
    private val instrumentation get() = InstrumentationRegistry.getInstrumentation()
    private val automation get() = instrumentation.uiAutomation
    private val keyTouches = JSONArray()
    private lateinit var keyboardPackage: String

    private fun shell(command: String): String = ParcelFileDescriptor.AutoCloseInputStream(
        automation.executeShellCommand(command)).bufferedReader().use { it.readText() }

    private fun capture(name: String) {
        val file = File(instrumentation.targetContext.filesDir, "writing-system-ime-$name.png")
        val bitmap = checkNotNull(automation.takeScreenshot())
        try { file.outputStream().use { bitmap.compress(android.graphics.Bitmap.CompressFormat.PNG, 100, it) } }
        finally { bitmap.recycle() }
        File(file.parentFile, "writing-system-ime-$name-input-method.txt").writeText(shell("dumpsys input_method"))
    }

    private fun visit(node: AccessibilityNodeInfo, action: (AccessibilityNodeInfo) -> Unit) {
        action(node)
        for (i in 0 until node.childCount) node.getChild(i)?.let { child ->
            try { visit(child, action) } finally { child.recycle() }
        }
    }

    private fun keyBounds(label: String): Rect? {
        val candidates = mutableListOf<Rect>()
        val observed = JSONArray()
        for (window in automation.windows.filter { it.type == AccessibilityWindowInfo.TYPE_INPUT_METHOD }) {
            window.root?.let { root ->
                try { visit(root) { node ->
                    val description = node.contentDescription?.toString() ?: node.text?.toString() ?: ""
                    val bounds = Rect().also(node::getBoundsInScreen)
                    observed.put(JSONObject().put("description", description).put("bounds", bounds.toShortString())
                        .put("package", node.packageName?.toString()).put("visible", node.isVisibleToUser))
                    if (node.packageName?.toString() == keyboardPackage && node.isVisibleToUser &&
                        description.equals(label, ignoreCase = true) && !bounds.isEmpty) candidates.add(Rect(bounds))
                } } finally { root.recycle() }
            }
        }
        File(instrumentation.targetContext.filesDir, "writing-system-ime-keyboard-nodes.json").writeText(observed.toString())
        assertTrue("Ambiguous installed keyboard key $label: $candidates", candidates.distinct().size <= 1)
        return candidates.firstOrNull()
    }

    private fun touchKey(label: String) {
        var bounds: Rect? = null
        compose.waitUntil(8_000) { bounds = keyBounds(label); bounds != null }
        val hit = checkNotNull(bounds)
        compose.runOnIdle { assertTrue("Test host must own foreground focus", compose.activity.hasWindowFocus()) }
        val down = SystemClock.uptimeMillis()
        for (action in listOf(MotionEvent.ACTION_DOWN, MotionEvent.ACTION_UP)) {
            val event = MotionEvent.obtain(down, SystemClock.uptimeMillis(), action, hit.exactCenterX(), hit.exactCenterY(), 0)
            event.source = InputDevice.SOURCE_TOUCHSCREEN
            try { assertTrue(automation.injectInputEvent(event, true)) } finally { event.recycle() }
        }
        keyTouches.put(JSONObject().put("key", label).put("observedBounds", hit.toShortString()))
        File(instrumentation.targetContext.filesDir, "writing-system-ime-key-touches.json").writeText(keyTouches.toString())
        compose.waitForIdle()
    }

    @Test fun installedLatinImeCommitsBeforeSharedEnterAndKeepsAuthorUndo() = exercise(true)
    @Test fun installedLatinImeCommitsBeforeSharedSoftBreakAndKeepsAuthorUndo() = exercise(false)

    private fun exercise(enter: Boolean) {
        val args = InstrumentationRegistry.getArguments()
        assumeTrue(args.getString("ciWritingSystemIme") == "true")
        assertEquals("This reviewed shared-writing row is API26 minimum", 26, Build.VERSION.SDK_INT)
        val ime = Settings.Secure.getString(instrumentation.targetContext.contentResolver, Settings.Secure.DEFAULT_INPUT_METHOD)
        assertTrue("Use the built-in LatinIME; never install or substitute an IME", ime in listOf(
            "com.android.inputmethod.latin/.LatinIME", "com.android.inputmethod.latin/com.android.inputmethod.latin.LatinIME",
            "com.google.android.inputmethod.latin/com.android.inputmethod.latin.LatinIME"))
        keyboardPackage = ime.substringBefore('/')
        val keyboard = instrumentation.targetContext.packageManager.getApplicationInfo(keyboardPackage, 0)
        assertTrue("Accept only a keyboard preinstalled in the pinned image", keyboard.flags and ApplicationInfo.FLAG_SYSTEM != 0)
        val manager = instrumentation.targetContext.getSystemService(Context.INPUT_METHOD_SERVICE) as InputMethodManager
        assertTrue("Existing English keyboard subtype required", manager.currentInputMethodSubtype?.locale?.startsWith("en") == true)
        automation.serviceInfo = automation.serviceInfo.apply {
            flags = flags or AccessibilityServiceInfo.FLAG_RETRIEVE_INTERACTIVE_WINDOWS
        }
        val runID = checkNotNull(args.getString("nativeInputRun"))
        require(runID.matches(Regex("[a-zA-Z0-9-]{1,80}")))
        val mode = if (enter) "enter" else "soft-break"
        val control = mutableStateOf(TextFieldValue(""))
        val controlUpdates = JSONArray()
        val editorVisible = mutableStateOf(false)
        val callbacks = JSONArray(); val failures = JSONArray(); val retainedDrafts = JSONArray(); val controls = JSONArray()
        lateinit var local: WritingSession; lateinit var remote: WritingSession
        lateinit var owner: WritingParagraphEditorState
        var phase = "initial"
        var acceptanceFailure: Throwable? = null
        val proof = JSONObject().put("runID", runID).put("mode", mode).put("protocol", 4)
            .put("scope", "Installed API26 LatinIME composition commits before a visible shared v4 command; physical author history, returned caret/focus, retained original Unicode/rich reference. No structured paste/assets/TalkBack or failed-repair acceptance.")
        fun blocks(session: WritingSession) = session.snapshot.getJSONArray("blocks")
        fun pText(session: WritingSession) = plainText(blocks(session).getJSONObject(0).getJSONArray("content"))
        fun receipt(session: WritingSession) = session.syncState().export()
        fun received(session: WritingSession): Set<String> = receipt(session).getJSONArray("received").let { ids ->
            (0 until ids.length()).map { index -> ids.getJSONObject(index).let { "${it.getString("actor")}/${it.getLong("counter")}" } }.toSet()
        }
        fun deferred(session: WritingSession) = JSONArray(session.exportDeferredChanges().map { it.export() })
        fun rich(session: WritingSession): JSONObject = blocks(session).let { values ->
            (0 until values.length()).map { values.getJSONObject(it) }.first { it.getString("id") == "rich" }
        }
        fun draft(value: WritingInputDraft) = JSONObject().put("address", value.address.export()).put("text", value.text)
            .put("selectionStart", value.selectionStart).put("selectionEnd", value.selectionEnd).put("reason", value.reason)
            .put("accepted", value.accepted.export()).put("deferred", JSONArray(value.deferred.map { it.export() }))
            .put("recovery", value.recovery?.export() ?: JSONObject.NULL)
        fun recordError(error: Exception) {
            failures.put(JSONObject().put("phase", phase).put("type", error.javaClass.name).put("message", error.message)
                .put("accepted", local.save().export()).put("receipt", receipt(local)).put("deferred", deferred(local))
                .put("recovery", local.mergeRecovery()?.export() ?: JSONObject.NULL))
        }
        compose.runOnUiThread {
            val initial = JSONArray("""[{"id":"p","type":"paragraph","content":[]},
              {"id":"rich","type":"paragraph","consumer":{"id":"opaque-owner"},"content":[
                {"type":"text","text":"Hello 👩🏽‍💻 café 日本語","marks":[{"type":"italic"}]},
                {"type":"entity-ref","entityType":"person","entityId":"mira","label":"Reference","consumer":{"id":"opaque-reference"}}]}]""")
            local = WritingSession.createV4("writing-ime-$runID-$mode", "local", "writing-v4-$runID-$mode", initial)
            remote = WritingSession.createV4("writing-ime-$runID-$mode", "remote", "writing-v4-$runID-$mode", initial)
            local.onChange = { snapshot -> callbacks.put(JSONObject().put("phase", phase).put("snapshot", JSONObject(snapshot.toString()))
                .put("receipt", receipt(local)).put("deferred", deferred(local))) }
        }
        val originalRich = compose.runOnIdle { writingCanonical(rich(local)) }
        val initialSave = compose.runOnIdle { writingCanonical(local.save().export()) }
        proof.put("initialAccepted", compose.runOnIdle { local.save().export() })
        val field = { compose.onAllNodes(hasSetTextAction())[0] }
        val focused = { compose.onNode(hasSetTextAction() and isFocused()) }
        fun controlState(stage: String): JSONObject {
            val value = compose.runOnIdle {
                JSONObject().put("phase", stage).put("uptimeMillis", SystemClock.uptimeMillis())
                    .put("snapshot", JSONObject(local.snapshot.toString())).put("accepted", local.save().export())
                    .put("receipt", receipt(local)).put("deferred", deferred(local))
                    .put("pendingDrafts", JSONArray(owner.pendingDrafts().map(::draft)))
                    .put("focusRequest", owner.inputs.focusRequest?.let { JSONObject().put("key", it.key).put("range", JSONObject(it.range.wire.toString())) } ?: JSONObject.NULL)
                    .put("foreground", compose.activity.hasWindowFocus()).put("targetSDK", compose.activity.applicationInfo.targetSdkVersion)
            }
            val fields = compose.onAllNodes(hasSetTextAction()).fetchSemanticsNodes().map { node ->
                val selection = node.config[SemanticsProperties.TextSelectionRange]
                JSONObject().put("text", node.config[SemanticsProperties.EditableText].text)
                    .put("selectionStart", selection.start).put("selectionEnd", selection.end)
                    .put("focused", node.config[SemanticsProperties.Focused])
            }
            value.put("fields", JSONArray(fields))
            for (tag in listOf("writing-undo", "writing-redo")) {
                value.put("$tag-enabled", !compose.onNodeWithTag(tag).fetchSemanticsNode().config.contains(SemanticsProperties.Disabled))
            }
            controls.put(value)
            File(instrumentation.targetContext.filesDir, "writing-system-ime-$mode-control-states.json").writeText(controls.toString())
            return value
        }
        fun tap(tag: String, stage: String) {
            phase = stage
            val observed = controlState("before-$stage")
            capture("$mode-before-$stage")
            try { compose.onNodeWithTag(tag).assertIsEnabled() }
            catch (error: AssertionError) { throw AssertionError("Actual shared-writing control disabled before physical touch: $observed", error) }
            compose.onNodeWithTag(tag).performTouchInput { click() }
            compose.waitForIdle()
            compose.waitUntil(8_000) { compose.runOnIdle { owner.inputs.focusRequest == null } }
            controlState("after-$stage")
            compose.runOnIdle { assertEquals("Native command failures cannot be accepted as successful interaction", 0, failures.length()) }
        }
        try {
            compose.setContent { MaterialTheme {
                val state = rememberWritingParagraphEditorState(local,
                    retainDrafts = { values -> values.forEach { retainedDrafts.put(draft(it)) } }, reportError = ::recordError)
                SideEffect { owner = state }
                if (editorVisible.value) WritingParagraphEditor(state, reportError = ::recordError)
                else OutlinedTextField(control.value, { value ->
                    control.value = value
                    controlUpdates.put(JSONObject().put("text", value.text)
                        .put("composingStart", value.composition?.start ?: JSONObject.NULL)
                        .put("composingEnd", value.composition?.end ?: JSONObject.NULL))
                })
            } }
            phase = "plain-control"
            field().performTouchInput { click() }; field().assertIsFocused(); capture("$mode-plain-keyboard")
            for (key in listOf("c", "a", "t")) touchKey(key)
            compose.runOnIdle {
                assertEquals("Vanilla installed keyboard must type the observed word", "cat", control.value.text.lowercase())
                assertEquals("Control must demonstrate real composition", TextRange(0, 3), control.value.composition)
            }
            capture("$mode-plain-composing")
            touchKey("Space")
            compose.runOnIdle {
                assertNull("Actual Space key must commit vanilla composition", control.value.composition)
                editorVisible.value = true
            }
            val composed = control.value.text.trimEnd()
            phase = "shared-composing"
            field().performTouchInput { click() }; field().assertIsFocused()
            for (key in listOf("c", "a", "t")) touchKey(key)
            assertEquals(composed, field().fetchSemanticsNode().config[SemanticsProperties.EditableText].text)
            capture("$mode-held-composing")
            compose.runOnIdle {
                assertEquals("Native marked draft is not accepted before command finalization", "", pText(local))
                assertEquals(initialSave, writingCanonical(local.save().export()))
                assertEquals(emptySet<String>(), received(local))
                assertEquals(0, failures.length())
                val actualDraft = owner.pendingDrafts().single()
                assertEquals("Native composition is pending", actualDraft.reason)
                assertEquals(composed, actualDraft.text)
                assertEquals(3, actualDraft.selectionStart); assertEquals(3, actualDraft.selectionEnd)
                proof.put("composingDraft", draft(actualDraft))
                remote.replaceText(remote.textAddress(remote.node(NodeAddress("p"))), 0, 0, "R")
                val packet = remote.changes()
                local.receive(packet)
                assertEquals(initialSave, writingCanonical(local.save().export()))
                assertEquals(emptySet<String>(), received(local))
                assertEquals(1, local.exportDeferredChanges().size)
                assertEquals(writingCanonical(packet.export()), writingCanonical(local.exportDeferredChanges().single().export()))
                proof.put("heldAccepted", local.save().export()).put("heldReceipt", receipt(local)).put("heldDeferred", deferred(local))
                proof.put("remoteOnlySnapshot", JSONObject(remote.snapshot.toString()))
                assertEquals(originalRich, writingCanonical(rich(local)))
            }
            assertEquals(composed, field().fetchSemanticsNode().config[SemanticsProperties.EditableText].text)
            val command = if (enter) "writing-enter" else "writing-soft-break"
            tap(command, "shared-command")
            val committed = compose.runOnIdle {
                assertEquals("R$composed" + if (enter) "" else "\n", pText(local))
                assertEquals(if (enter) 3 else 2, blocks(local).length())
                if (enter) assertEquals("", plainText(blocks(local).getJSONObject(1).getJSONArray("content")))
                assertEquals(setOf("local/1", "remote/1", "local/2"), received(local))
                assertTrue(local.exportDeferredChanges().isEmpty()); assertNull(local.mergeRecovery())
                assertEquals(originalRich, writingCanonical(rich(local)))
                assertTrue(owner.pendingDrafts().isEmpty())
                remote.receive(local.changes())
                assertEquals(writingCanonical(blocks(remote)), writingCanonical(blocks(local)))
                proof.put("committedAccepted", local.save().export()).put("committedReceipt", receipt(local))
                JSONObject(local.snapshot.toString())
            }
            assertEquals(if (enter) "" else "R$composed\n", focused().fetchSemanticsNode().config[SemanticsProperties.EditableText].text)
            assertEquals(TextRange(if (enter) 0 else composed.length + 2), focused().fetchSemanticsNode().config[SemanticsProperties.TextSelectionRange])
            val returnedTarget = compose.runOnIdle {
                local.node(NodeAddress(if (enter) blocks(local).getJSONObject(1).getString("id") else "p"))
            }
            val renderedOrigin = focused().fetchSemanticsNode().config[SemanticsProperties.TestTag].removePrefix("writing-text:")
            assertEquals(writingCanonical(returnedTarget.wire), writingCanonical(JSONObject(renderedOrigin)))
            proof.put("returnedCaretOrigin", returnedTarget.wire).put("returnedCaretOffset", if (enter) 0 else composed.length + 2)
            capture("$mode-command-caret")
            val reopened = compose.runOnIdle { WritingSession.restore(local.save(), "local") }
            try {
                compose.runOnIdle {
                    reopened.undo()
                    assertEquals("R$composed", pText(reopened)); assertEquals(2, blocks(reopened).length())
                    assertEquals(originalRich, writingCanonical(rich(reopened)))
                    reopened.redo(); assertEquals(writingCanonical(committed.getJSONArray("blocks")), writingCanonical(blocks(reopened)))
                    proof.put("offlineReopenedAccepted", reopened.save().export())
                }
            } finally { compose.runOnIdle { reopened.close() } }
            tap("writing-undo", "one-command-author-undo")
            compose.runOnIdle {
                assertEquals("Undo removes only Enter/softbreak, retaining committed native text and the remote author", "R$composed", pText(local))
                assertEquals(2, blocks(local).length()); assertEquals(originalRich, writingCanonical(rich(local)))
                proof.put("oneCommandUndoSnapshot", JSONObject(local.snapshot.toString()))
            }
            assertEquals("R$composed", focused().fetchSemanticsNode().config[SemanticsProperties.EditableText].text)
            assertEquals(TextRange(composed.length + 1), focused().fetchSemanticsNode().config[SemanticsProperties.TextSelectionRange])
            tap("writing-redo", "one-command-author-redo")
            compose.runOnIdle { assertEquals(writingCanonical(committed.getJSONArray("blocks")), writingCanonical(blocks(local))) }
            tap("writing-undo", "undo-structural-again")
            tap("writing-undo", "undo-native-draft")
            compose.runOnIdle {
                assertEquals("R", pText(local)); assertEquals(originalRich, writingCanonical(rich(local)))
                assertEquals(writingCanonical(proof.getJSONObject("remoteOnlySnapshot").getJSONArray("blocks")), writingCanonical(blocks(local)))
                proof.put("remoteOnlyUndoSnapshot", JSONObject(local.snapshot.toString()))
                remote.receive(local.changes()); assertEquals(writingCanonical(blocks(remote)), writingCanonical(blocks(local)))
            }
            tap("writing-redo", "redo-native-draft")
            tap("writing-redo", "redo-structural-command")
            compose.runOnIdle {
                assertEquals(writingCanonical(committed.getJSONArray("blocks")), writingCanonical(blocks(local)))
                remote.receive(local.changes()); assertEquals(writingCanonical(blocks(remote)), writingCanonical(blocks(local)))
                assertTrue(owner.pendingDrafts().isEmpty()); assertTrue(local.exportDeferredChanges().isEmpty())
                assertEquals(0, retainedDrafts.length()); assertEquals(0, failures.length())
                proof.put("finalAccepted", local.save().export()).put("finalReceipt", receipt(local)).put("passed", true)
            }
            assertEquals(if (enter) "" else "R$composed\n", focused().fetchSemanticsNode().config[SemanticsProperties.EditableText].text)
            assertEquals(TextRange(if (enter) 0 else composed.length + 2), focused().fetchSemanticsNode().config[SemanticsProperties.TextSelectionRange])
            val finalOrigin = focused().fetchSemanticsNode().config[SemanticsProperties.TestTag].removePrefix("writing-text:")
            assertEquals(writingCanonical(returnedTarget.wire), writingCanonical(JSONObject(finalOrigin)))
            capture("$mode-final-history")
        } catch (error: Throwable) {
            acceptanceFailure = error
            throw error
        } finally {
            var finalizationFailure: Throwable? = null
            fun retainFailure(error: Throwable) {
                val original = acceptanceFailure
                if (original != null) original.addSuppressed(error)
                else if (finalizationFailure == null) finalizationFailure = error
                else finalizationFailure?.addSuppressed(error)
            }
            fun writeProof() {
                try { File(instrumentation.targetContext.filesDir, "writing-system-ime-$mode-proof.json").writeText(proof.toString()) }
                catch (error: Throwable) { retainFailure(error) }
            }
            // Keep every failed draft, accepted/pending packet and callback before
            // disposal. A diagnostic failure must not hide the interaction oracle.
            try {
                compose.runOnIdle {
                    proof.put("lastAccepted", local.save().export()).put("lastReceipt", receipt(local)).put("lastDeferred", deferred(local))
                        .put("lastRecovery", local.mergeRecovery()?.export() ?: JSONObject.NULL)
                        .put("pendingDrafts", JSONArray(owner.pendingDrafts().map(::draft)))
                }
                capture("$mode-final-state")
            } catch (error: Throwable) { proof.put("diagnosticFailure", "${error.javaClass.name}: ${error.message}") }
            proof.put("callbacks", callbacks).put("failures", failures).put("retainedDrafts", retainedDrafts)
                .put("controlUpdates", controlUpdates).put("keyTouches", keyTouches).put("controls", controls)
            writeProof()
            try {
                compose.runOnIdle { editorVisible.value = false }; compose.waitForIdle()
                compose.runOnIdle {
                    owner.close()
                    local.close(pendingStateRetained = local.exportDeferredChanges().isNotEmpty())
                    remote.close()
                }
            } catch (error: Throwable) {
                proof.put("cleanupFailure", "${error.javaClass.name}: ${error.message}")
                retainFailure(error)
            } finally {
                // Include retention/drain callbacks occurring during disposal.
                writeProof()
            }
            // Diagnostics/disposal must not replace the original assertion or
            // Compose timeout. A new finalization failure still fails success.
            if (acceptanceFailure == null) finalizationFailure?.let { throw it }
        }
    }
}
