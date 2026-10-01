package studio.seventwo.blockeditor

import android.graphics.Bitmap
import android.graphics.Rect
import android.accessibilityservice.AccessibilityServiceInfo
import android.content.ClipData
import android.content.ClipboardManager
import android.os.SystemClock
import android.os.Process
import android.os.Build
import android.os.ParcelFileDescriptor
import android.provider.Settings
import android.view.InputDevice
import android.view.inputmethod.InputMethodManager
import android.content.Context
import android.view.MotionEvent
import androidx.activity.ComponentActivity
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Text
import androidx.compose.foundation.Image
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.size
import androidx.compose.runtime.mutableStateOf
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.unit.dp
import androidx.compose.ui.text.input.TextFieldValue
import org.json.JSONObject
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.createAndroidComposeRule
import androidx.compose.ui.text.TextRange
import androidx.test.platform.app.InstrumentationRegistry
import org.json.JSONArray
import org.junit.Assert.*
import org.junit.Assume.assumeTrue
import org.junit.Rule
import org.junit.Test
import java.io.File

/** Opt-in system keyboard acceptance. Never injects an InputConnection or composition. */
@OptIn(ExperimentalTestApi::class)
class SystemImeTest {
    @get:Rule val compose = createAndroidComposeRule<ComponentActivity>()
    private val instrumentation get() = InstrumentationRegistry.getInstrumentation()
    private fun tap(x: Float, y: Float) {
        val time = SystemClock.uptimeMillis()
        for (action in listOf(MotionEvent.ACTION_DOWN, MotionEvent.ACTION_UP)) {
            val event = MotionEvent.obtain(time, SystemClock.uptimeMillis(), action, x, y, 0)
            event.source = InputDevice.SOURCE_TOUCHSCREEN
            try { assertTrue(instrumentation.uiAutomation.injectInputEvent(event, true)) } finally { event.recycle() }
        }
        compose.waitForIdle()
    }
    private fun capture(name: String) {
        val bitmap = checkNotNull(instrumentation.uiAutomation.takeScreenshot())
        val file = File(instrumentation.targetContext.filesDir, "system-ime-$name.png")
        file.outputStream().use { bitmap.compress(Bitmap.CompressFormat.PNG, 100, it) }
        bitmap.recycle()
        val descriptor = instrumentation.uiAutomation.executeShellCommand("dumpsys input_method")
        File(instrumentation.targetContext.filesDir, "system-ime-$name-input-method.txt").writeText(
            ParcelFileDescriptor.AutoCloseInputStream(descriptor).bufferedReader().use { it.readText() })
    }
    @Test fun diagnoseInstalledImeAgainstPlainTextField() {
        val args = InstrumentationRegistry.getArguments()
        assumeTrue(args.getString("systemImeControl") == "true")
        val value = mutableStateOf(TextFieldValue(""))
        val updates = JSONArray()
        compose.setContent { MaterialTheme { OutlinedTextField(value.value, { next ->
            updates.put(JSONObject().put("text", next.text).put("composition", next.composition?.toString() ?: JSONObject.NULL))
            value.value = next
        }, label = { Text("Plain control") }) } }
        val field = compose.onNode(hasSetTextAction())
        field.performClick()
        SystemClock.sleep(1_000)
        // Optional bounded pause lets a human select an already installed subtype in the keyboard picker.
        args.getString("keyboardSetupWaitMs")?.toLong()?.let { require(it in 0..30_000); SystemClock.sleep(it) }
        field.performTouchInput { click(androidx.compose.ui.geometry.Offset(45f, center.y)) }
        SystemClock.sleep(250)
        capture("plain-keyboard")
        if (args.getString("keyboardLocale") == "ja") { tap(810f, 1868f); tap(59f, 1868f) }
        else { tap(432f, 2025f); tap(112f, 1868f); tap(486f, 1717f) }
        capture("plain-composing")
        File(instrumentation.targetContext.filesDir, "system-ime-plain-updates.json").writeText(updates.toString())
        compose.runOnIdle {
            assertEquals(if (args.getString("keyboardLocale") == "ja") "か" else "cat", value.value.text)
            assertNotNull("The same installed keyboard must demonstrate actual composition on a vanilla control", value.value.composition)
        }
    }
    @Test fun installedJapaneseImeHoldsRemoteUntilKeyboardCommit() {
        val args = InstrumentationRegistry.getArguments()
        assumeTrue(args.getString("systemIme") == "true")
        assertEquals("Explicitly validated keyboard layout required", "gboard-japanese-qwerty-1080x2400", args.getString("keyboardLayout"))
        val ime = Settings.Secure.getString(instrumentation.targetContext.contentResolver, Settings.Secure.DEFAULT_INPUT_METHOD)
        assertEquals("Use the installed Gboard; do not replace the system input connection", "com.google.android.inputmethod.latin/com.android.inputmethod.latin.LatinIME", ime)
        val subtype = (instrumentation.targetContext.getSystemService(Context.INPUT_METHOD_SERVICE) as InputMethodManager).currentInputMethodSubtype
        assertTrue("Enable the existing Japanese QWERTY subtype before this opt-in test", subtype?.locale?.startsWith("ja") == true)
        val display = instrumentation.targetContext.resources.displayMetrics
        assertEquals(1080, display.widthPixels); assertEquals(2400, display.heightPixels)
        lateinit var a: EditorSession
        lateinit var b: EditorSession
        val initial = " Hello 👩🏽‍💻 café 日本語"
        compose.runOnUiThread {
            val blocks = JSONArray("""[{"id":"p","type":"paragraph","content":[{"type":"text","text":"$initial","marks":[{"type":"italic"}]},{"type":"mention","entityId":"ref","entityType":"user","label":"Reference"}]}]""")
            a = EditorSession.create("system-ime", "local", blocks)
            b = EditorSession.create("system-ime", "remote", blocks)
        }
        val proof = JSONObject()
        fun verifyRichContent(session: EditorSession) {
            val nodes = session.snapshot.getJSONArray("blocks").getJSONObject(0).getJSONArray("content")
            val values = (0 until nodes.length()).map { nodes.getJSONObject(it) }
            val reference = values.single { it.optString("type") == "mention" }
            assertEquals("ref", reference.getString("entityId")); assertEquals("user", reference.getString("entityType"))
            assertEquals("Reference", reference.getString("label"))
            val original = values.single { it.optString("text").contains(initial) }
            assertTrue((0 until original.getJSONArray("marks").length()).any { original.getJSONArray("marks").getJSONObject(it).getString("type") == "italic" })
        }
        try {
            compose.setContent { MaterialTheme { BlockEditor(a) } }
            val field = compose.onNode(hasSetTextAction())
            field.performClick()
            SystemClock.sleep(1_000)
            capture("before-caret")
            field.performTouchInput { click(androidx.compose.ui.geometry.Offset(45f, center.y)) }
            SystemClock.sleep(250)
            capture("after-caret")
            assertEquals(TextRange(0), field.fetchSemanticsNode().config[androidx.compose.ui.semantics.SemanticsProperties.TextSelectionRange])
            capture("keyboard")
            // Coordinates come from the retained 1080x2400 Japanese Gboard QWERTY layout.
            // Touches go to the installed keyboard, not Compose semantics or input APIs.
            tap(810f, 1868f) // k
            tap(59f, 1868f) // a: the actual Japanese IME composes か.
            assertEquals("か${initial}Reference", field.fetchSemanticsNode().config[androidx.compose.ui.semantics.SemanticsProperties.EditableText].text)
            capture("composing")
            compose.runOnIdle {
                assertEquals("Installed IME must still be composing", initial + "Reference", plainText(a.snapshot.getJSONArray("blocks").getJSONObject(0).getJSONArray("content")))
                b.setText("p", "R" + initial + "Reference")
                a.receive(b.changes())
                assertEquals("Remote receipt must stay pending during system composition", 0, a.syncState().getJSONArray("received").length())
                proof.put("heldSnapshot", a.snapshot).put("heldSync", a.syncState())
                proof.put("remoteOnlyBlocks", b.snapshot.getJSONArray("blocks"))
                verifyRichContent(b)
            }
            assertEquals("か${initial}Reference", field.fetchSemanticsNode().config[androidx.compose.ui.semantics.SemanticsProperties.EditableText].text)
            capture("composing")
            tap(990f, 2180f) // Enter commits Kana through the installed keyboard.
            assertEquals("Rか${initial}Reference", field.fetchSemanticsNode().config[androidx.compose.ui.semantics.SemanticsProperties.EditableText].text)
            assertEquals(TextRange(2), field.fetchSemanticsNode().config[androidx.compose.ui.semantics.SemanticsProperties.TextSelectionRange])
            compose.runOnIdle {
                verifyRichContent(a)
                assertTrue(a.syncState().getJSONArray("received").length() > 0)
                proof.put("committedSnapshot", a.snapshot).put("committedSync", a.syncState())
                b.receive(a.changes())
                assertEquals(b.snapshot.getJSONArray("blocks").toString(), a.snapshot.getJSONArray("blocks").toString())
            }
            compose.onNodeWithText("Undo").performTouchInput { click() }
            assertEquals("R${initial}Reference", field.fetchSemanticsNode().config[androidx.compose.ui.semantics.SemanticsProperties.EditableText].text)
            compose.runOnIdle {
                verifyRichContent(a)
                assertEquals(proof.getJSONArray("remoteOnlyBlocks").toString(), a.snapshot.getJSONArray("blocks").toString())
                proof.put("undoSnapshot", a.snapshot)
                File(instrumentation.targetContext.filesDir, "system-ime-proof.json").writeText(proof.toString())
            }
            capture("author-undo")
            compose.onNodeWithText("Redo").performTouchInput { click() }
            compose.runOnIdle {
                assertEquals(proof.getJSONObject("committedSnapshot").getJSONArray("blocks").toString(), a.snapshot.getJSONArray("blocks").toString())
                val runID = args.getString("nativeInputRun")
                if (runID != null) {
                    require(runID.matches(Regex("[a-zA-Z0-9-]{1,80}")))
                    val archive = JSONObject().put("pid", Process.myPid()).put("snapshot", a.save())
                        .put("expectedBlocks", a.snapshot.getJSONArray("blocks"))
                        .put("remoteOnlyBlocks", proof.getJSONArray("remoteOnlyBlocks"))
                    File(instrumentation.targetContext.filesDir, "native-input-$runID.json").writeText(archive.toString())
                }
            }
            capture("author-redo")
        } finally { compose.runOnIdle { a.close(); b.close() } }
    }
    @Test fun reopenSavedKeyboardDocumentInAnotherProcess() {
        val args = InstrumentationRegistry.getArguments()
        val runID = args.getString("nativeInputRun")
        assumeTrue(args.getString("nativeInputReopen") == "true" && runID != null)
        require(checkNotNull(runID).matches(Regex("[a-zA-Z0-9-]{1,80}")))
        val file = File(instrumentation.targetContext.filesDir, "native-input-$runID.json")
        val archive = JSONObject(file.readText())
        assertNotEquals("The runner must really stop the previous host process", archive.getInt("pid"), Process.myPid())
        lateinit var session: EditorSession
        compose.runOnUiThread { session = EditorSession.restore(archive.getJSONObject("snapshot"), "local") }
        try {
            compose.setContent { MaterialTheme { BlockEditor(session) } }
            compose.runOnIdle { assertEquals(archive.getJSONArray("expectedBlocks").toString(), session.snapshot.getJSONArray("blocks").toString()) }
            compose.onNodeWithText("Undo").performTouchInput { click() }
            compose.runOnIdle { assertEquals(archive.getJSONArray("remoteOnlyBlocks").toString(), session.snapshot.getJSONArray("blocks").toString()) }
            compose.onNodeWithText("Redo").performTouchInput { click() }
            compose.runOnIdle {
                assertEquals(archive.getJSONArray("expectedBlocks").toString(), session.snapshot.getJSONArray("blocks").toString())
                File(instrumentation.targetContext.filesDir, "system-ime-reopen-proof.json").writeText(
                    JSONObject().put("previousPid", archive.getInt("pid")).put("pid", Process.myPid()).put("snapshot", session.snapshot).toString())
            }
            capture("process-reopen")
        } finally { compose.runOnIdle { session.close() } }
    }

    @Test fun nativePlainPasteAndHostOwnedImage() {
        assumeTrue(InstrumentationRegistry.getArguments().getString("nativeClipboard") == "true")
        lateinit var clipboard: ClipboardManager
        lateinit var session: EditorSession
        val plain = "Paste 👩🏽‍💻 café 日本語"
        val image = Bitmap.createBitmap(32, 32, Bitmap.Config.ARGB_8888).apply { eraseColor(android.graphics.Color.BLUE) }
        val tapped = mutableStateOf(false)
        var previous: ClipData? = null
        var clipboardChanged = false
        compose.runOnUiThread {
            // API26's ClipboardManager constructs a Handler on the calling thread.
            clipboard = instrumentation.targetContext.getSystemService(Context.CLIPBOARD_SERVICE) as ClipboardManager
            session = EditorSession.create("native-paste", "local", JSONArray("""[
                {"id":"p","type":"paragraph","content":[]},
                {"id":"rich","type":"paragraph","content":[{"type":"text","text":"Original café 日本語","marks":[{"type":"italic"}]},{"type":"mention","entityId":"ref","entityType":"user","label":"Reference"}]},
                {"id":"asset","type":"image","src":"asset:host-owned","alt":"Host-owned blue image"}
            ]"""))
        }
        val original = session.snapshot.getJSONArray("blocks").toString()
        try {
            compose.setContent { MaterialTheme {
                BlockEditor(session, asset = { block ->
                    assertEquals("asset:host-owned", block.getString("src"))
                    Image(image.asImageBitmap(), block.getString("alt"), Modifier.size(60.dp).clickable { tapped.value = true })
                })
            } }
            compose.onNodeWithContentDescription("Host-owned blue image").performTouchInput { click() }
            compose.runOnIdle { assertTrue("The host's local image must receive actual touch", tapped.value) }
            val field = compose.onAllNodes(hasSetTextAction())[0]
            field.performClick()
            SystemClock.sleep(800)
            compose.runOnUiThread {
                previous = clipboard.primaryClip
                clipboard.setPrimaryClip(ClipData.newHtmlText("Native paste fixture", plain,
                    "<b>$plain</b><script>alert('must not execute')</script><img src='https://invalid.test/image'>"))
                clipboardChanged = true
            }
            field.performTouchInput { longClick(androidx.compose.ui.geometry.Offset(45f, center.y)) }
            SystemClock.sleep(300)
            capture("paste-menu")
            val automation = instrumentation.uiAutomation
            automation.serviceInfo = automation.serviceInfo.apply { flags = flags or AccessibilityServiceInfo.FLAG_RETRIEVE_INTERACTIVE_WINDOWS }
            val windows = automation.windows
            val nodes = windows.flatMap { it.root?.findAccessibilityNodeInfosByText("Paste") ?: emptyList() }
            fun describeNodes(values: List<android.view.accessibility.AccessibilityNodeInfo>): JSONArray {
                val observed = JSONArray()
                for (node in values) {
                val area = Rect().also(node::getBoundsInScreen)
                observed.put(JSONObject().put("text", node.text?.toString() ?: "")
                    .put("description", node.contentDescription?.toString() ?: "")
                    .put("package", node.packageName?.toString() ?: "").put("class", node.className?.toString() ?: "")
                    .put("window", node.windowId).put("enabled", node.isEnabled).put("clickable", node.isClickable)
                    .put("bounds", JSONArray(listOf(area.left, area.top, area.right, area.bottom))))
                }
                return observed
            }
            val observedWindows = JSONArray()
            for (window in windows) {
                val area = Rect().also(window::getBoundsInScreen)
                observedWindows.put(JSONObject().put("id", window.id).put("type", window.type)
                    .put("active", window.isActive).put("focused", window.isFocused)
                    .put("rootPackage", window.root?.packageName?.toString() ?: "")
                    .put("bounds", JSONArray(listOf(area.left, area.top, area.right, area.bottom))))
            }
            val uppercaseNodes = windows.flatMap { it.root?.findAccessibilityNodeInfosByText("PASTE") ?: emptyList() }
            File(instrumentation.targetContext.filesDir, "system-ime-paste-menu-nodes.json").writeText(
                JSONObject().put("windows", observedWindows).put("PasteQuery", describeNodes(nodes))
                    .put("PASTEQuery", describeNodes(uppercaseNodes)).toString())
            val paste = nodes.single { it.text?.toString()?.equals("Paste", ignoreCase = true) == true }
            val bounds = Rect(); paste.getBoundsInScreen(bounds)
            assertFalse("Native paste menu must have visible touch bounds", bounds.isEmpty)
            tap(bounds.exactCenterX(), bounds.exactCenterY())
            assertEquals(plain, field.fetchSemanticsNode().config[androidx.compose.ui.semantics.SemanticsProperties.EditableText].text)
            compose.runOnIdle {
                val before = JSONArray(original)
                val blocks = session.snapshot.getJSONArray("blocks")
                assertEquals("HTML must not create scripts, images or extra document blocks", 3, blocks.length())
                assertEquals(plain, plainText(blocks.getJSONObject(0).getJSONArray("content")))
                assertEquals(before.getJSONObject(1).toString(), blocks.getJSONObject(1).toString())
                assertEquals(before.getJSONObject(2).toString(), blocks.getJSONObject(2).toString())
                File(instrumentation.targetContext.filesDir, "system-ime-paste-proof.json").writeText(
                    JSONObject().put("plainText", plain).put("snapshot", session.snapshot).put("hostImageTapped", tapped.value).toString())
            }
            capture("plain-paste")
            compose.onNodeWithText("Undo").performTouchInput { click() }
            compose.runOnIdle { assertEquals(original, session.snapshot.getJSONArray("blocks").toString()) }
        } finally {
            compose.runOnUiThread {
                if (clipboardChanged) {
                    if (previous != null) clipboard.setPrimaryClip(checkNotNull(previous))
                    else if (Build.VERSION.SDK_INT >= 28) clipboard.clearPrimaryClip()
                    else clipboard.setPrimaryClip(ClipData.newPlainText("", ""))
                }
                session.close()
            }
            image.recycle()
        }
    }

}
