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

/** CI-only installed AOSP keyboard input. No replacement IME or composing API calls. */
@OptIn(ExperimentalTestApi::class)
class BuiltinImeTest {
    @get:Rule val compose = createAndroidComposeRule<ComponentActivity>()
    private val instrumentation get() = InstrumentationRegistry.getInstrumentation()
    private val automation get() = instrumentation.uiAutomation
    private val keyTouches = JSONArray()
    private lateinit var keyboardPackage: String

    private fun shell(command: String): String = ParcelFileDescriptor.AutoCloseInputStream(
        automation.executeShellCommand(command)).bufferedReader().use { it.readText() }

    private fun capture(name: String) {
        val file = File(instrumentation.targetContext.filesDir, "system-ime-$name.png")
        val bitmap = checkNotNull(automation.takeScreenshot())
        try { file.outputStream().use { bitmap.compress(android.graphics.Bitmap.CompressFormat.PNG, 100, it) } }
        finally { bitmap.recycle() }
        File(file.parentFile, "system-ime-$name-input-method.txt").writeText(shell("dumpsys input_method"))
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
        File(instrumentation.targetContext.filesDir, "system-ime-keyboard-nodes.json").writeText(observed.toString())
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
        File(instrumentation.targetContext.filesDir, "system-ime-key-touches.json").writeText(keyTouches.toString())
        compose.waitForIdle()
    }

    @Test fun installedLatinImeHoldsRemoteAndPreservesAuthorHistory() {
        val args = InstrumentationRegistry.getArguments()
        assumeTrue(args.getString("ciSystemIme") == "true")
        assertEquals("This reviewed smoke row is the API26 minimum", 26, Build.VERSION.SDK_INT)
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
        val control = mutableStateOf(TextFieldValue(""))
        val controlUpdates = JSONArray()
        val editorVisible = mutableStateOf(false)
        lateinit var local: EditorSession
        lateinit var remote: EditorSession
        compose.runOnUiThread {
            val blocks = JSONArray("""[{"id":"p","type":"paragraph","content":[]},
              {"id":"rich","type":"paragraph","content":[{"type":"text","text":"Hello 👩🏽‍💻 café 日本語","marks":[{"type":"italic"}]},
              {"type":"mention","entityId":"ref","entityType":"user","label":"Reference"}]}]""")
            local = EditorSession.create("builtin-ime-$runID", "local", blocks)
            remote = EditorSession.create("builtin-ime-$runID", "remote", blocks)
        }
        val preservedRich = local.snapshot.getJSONArray("blocks").getJSONObject(1).toString()
        val proof = JSONObject().put("runID", runID).put("scope", "API26 installed LatinIME composition; separate rich Unicode/reference preservation; no TalkBack/full authoring")
        try {
            compose.setContent { MaterialTheme {
                if (editorVisible.value) BlockEditor(local)
                else OutlinedTextField(control.value, { value ->
                    control.value = value
                    controlUpdates.put(JSONObject().put("text", value.text)
                        .put("composingStart", value.composition?.start ?: JSONObject.NULL)
                        .put("composingEnd", value.composition?.end ?: JSONObject.NULL))
                })
            } }
            val field = { compose.onAllNodes(hasSetTextAction())[0] }
            field().performTouchInput { click() }
            field().assertIsFocused()
            capture("plain-keyboard")
            for (key in listOf("c", "a", "t")) touchKey(key)
            capture("plain-composing")
            File(instrumentation.targetContext.filesDir, "system-ime-plain-updates.json").writeText(controlUpdates.toString())
            val composed = control.value.text
            compose.runOnIdle {
                assertEquals("Vanilla installed-keyboard control must type the observed word", "cat", composed.lowercase())
                assertEquals("Control must demonstrate real composition before editor acceptance", TextRange(0, 3), control.value.composition)
            }
            touchKey("Space")
            compose.runOnIdle {
                assertNull("Actual Space key must commit control composition", control.value.composition)
                assertEquals(composed + " ", control.value.text)
                editorVisible.value = true
            }
            field().performTouchInput { click() }
            field().assertIsFocused()
            for (key in listOf("c", "a", "t")) touchKey(key)
            assertEquals(composed, field().fetchSemanticsNode().config[SemanticsProperties.EditableText].text)
            capture("composing")
            compose.runOnIdle {
                assertEquals("Engine must not persist active installed-IME composition", "", plainText(local.snapshot.getJSONArray("blocks").getJSONObject(0).getJSONArray("content")))
                remote.setText("p", "R")
                local.receive(remote.changes())
                assertEquals("Remote receipts remain pending until the real keyboard commits", 0, local.syncState().getJSONArray("received").length())
                proof.put("heldSnapshot", local.snapshot).put("heldSync", local.syncState())
                proof.put("remoteOnlyBlocks", remote.snapshot.getJSONArray("blocks"))
            }
            assertEquals(composed, field().fetchSemanticsNode().config[SemanticsProperties.EditableText].text)
            touchKey("Space")
            assertEquals("R$composed ", field().fetchSemanticsNode().config[SemanticsProperties.EditableText].text)
            assertEquals(TextRange(5), field().fetchSemanticsNode().config[SemanticsProperties.TextSelectionRange])
            compose.runOnIdle {
                assertTrue(local.syncState().getJSONArray("received").length() > 0)
                assertEquals(preservedRich, local.snapshot.getJSONArray("blocks").getJSONObject(1).toString())
                proof.put("committedSnapshot", local.snapshot).put("committedSync", local.syncState())
                remote.receive(local.changes())
                assertEquals(remote.snapshot.getJSONArray("blocks").toString(), local.snapshot.getJSONArray("blocks").toString())
            }
            compose.onNodeWithText("Undo").performTouchInput { click() }
            compose.runOnIdle {
                assertEquals(proof.getJSONArray("remoteOnlyBlocks").toString(), local.snapshot.getJSONArray("blocks").toString())
                proof.put("undoSnapshot", local.snapshot)
            }
            capture("author-undo")
            compose.onNodeWithText("Redo").performTouchInput { click() }
            compose.runOnIdle {
                assertEquals(proof.getJSONObject("committedSnapshot").getJSONArray("blocks").toString(), local.snapshot.getJSONArray("blocks").toString())
                File(instrumentation.targetContext.filesDir, "system-ime-proof.json").writeText(proof.toString())
                File(instrumentation.targetContext.filesDir, "native-input-$runID.json").writeText(
                    JSONObject().put("pid", Process.myPid()).put("snapshot", local.save())
                        .put("expectedBlocks", local.snapshot.getJSONArray("blocks"))
                        .put("remoteOnlyBlocks", proof.getJSONArray("remoteOnlyBlocks")).toString())
            }
            capture("author-redo")
        } finally {
            compose.runOnIdle { local.close(); remote.close() }
        }
    }
}
