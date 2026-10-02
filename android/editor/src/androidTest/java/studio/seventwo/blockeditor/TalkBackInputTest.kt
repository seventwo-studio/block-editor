package studio.seventwo.blockeditor

import android.accessibilityservice.AccessibilityServiceInfo
import android.app.UiAutomation
import android.content.Context
import android.graphics.Rect
import android.os.SystemClock
import android.view.InputDevice
import android.view.MotionEvent
import android.view.accessibility.AccessibilityManager
import android.view.accessibility.AccessibilityNodeInfo
import androidx.activity.ComponentActivity
import androidx.compose.ui.platform.ComposeView
import androidx.compose.material3.MaterialTheme
import androidx.test.core.app.ActivityScenario
import androidx.test.platform.app.InstrumentationRegistry
import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Assume.assumeTrue
import org.junit.Test
import java.io.File

/** Actual TalkBack gestures, with the installed service retained throughout instrumentation. */
class TalkBackInputTest {
    @Test fun installedTalkBackFocusesAndActivatesAuthorUndo() {
        val instrumentation = InstrumentationRegistry.getInstrumentation()
        assumeTrue(InstrumentationRegistry.getArguments().getString("nativeTalkBack") == "true")
        // Obtain this connection before launching any rule/helper that could suppress services.
        val automation = instrumentation.getUiAutomation(UiAutomation.FLAG_DONT_SUPPRESS_ACCESSIBILITY_SERVICES)
        automation.serviceInfo = automation.serviceInfo.apply {
            flags = flags or AccessibilityServiceInfo.FLAG_RETRIEVE_INTERACTIVE_WINDOWS
        }
        val manager = instrumentation.targetContext.getSystemService(Context.ACCESSIBILITY_SERVICE) as AccessibilityManager
        fun verifyService() {
            assertTrue("Installed TalkBack must retain touch exploration", manager.isTouchExplorationEnabled)
            assertTrue("Spoken-feedback TalkBack service must stay enabled", manager.getEnabledAccessibilityServiceList(
                AccessibilityServiceInfo.FEEDBACK_SPOKEN).any { it.id.contains("com.google.android.marvin.talkback") })
        }
        verifyService()
        val focusHistory = JSONArray()
        var session: EditorSession? = null
        val scenario = ActivityScenario.launch(ComponentActivity::class.java)
        val proof = JSONObject().put("scope", "Active installed TalkBack swipe focus and double-tap Undo activation; spoken audio and full authoring remain separate")
        val kernelGestures = InstrumentationRegistry.getArguments().getString("nativeTalkBackKernel") == "true"
        proof.put("gestureSource", if (kernelGestures) "emulator-kernel-touchscreen" else "UiAutomation")
        var gestureSequence = 0
        fun hardwareGesture(kind: String, x: Float, y: Float, endX: Float = x) {
            val sequence = ++gestureSequence
            val metrics = instrumentation.targetContext.resources.displayMetrics
            File(instrumentation.targetContext.filesDir, "talkback-gesture-request.json").writeText(
                JSONObject().put("sequence", sequence).put("kind", kind).put("x", x).put("y", y).put("endX", endX)
                    .put("width", metrics.widthPixels).put("height", metrics.heightPixels).toString())
            val acknowledgment = File(instrumentation.targetContext.filesDir, "talkback-gesture-ack.txt")
            val deadline = SystemClock.uptimeMillis() + 20_000
            while (SystemClock.uptimeMillis() < deadline) {
                if (acknowledgment.exists() && acknowledgment.readText().trim() == sequence.toString()) return
                SystemClock.sleep(50)
            }
            fail("Emulator kernel gesture driver did not acknowledge request $sequence")
        }
        fun nodeLabels(node: AccessibilityNodeInfo, labels: MutableSet<String>, depth: Int = 0) {
            node.text?.toString()?.takeIf { it.isNotBlank() }?.let(labels::add)
            node.contentDescription?.toString()?.takeIf { it.isNotBlank() }?.let(labels::add)
            if (depth >= 8) return
            for (index in 0 until node.childCount) {
                val child = node.getChild(index) ?: continue
                try { nodeLabels(child, labels, depth + 1) } finally { child.recycle() }
            }
        }
        fun recordFocus(): JSONObject? {
            for (window in automation.windows) {
                val root = window.root ?: continue
                try {
                    val focused = root.findFocus(AccessibilityNodeInfo.FOCUS_ACCESSIBILITY) ?: continue
                    try {
                        focused.refresh()
                        val bounds = Rect().also(focused::getBoundsInScreen)
                        val labels = mutableSetOf<String>().also { nodeLabels(focused, it) }
                        return JSONObject().put("text", focused.text?.toString() ?: "")
                            .put("description", focused.contentDescription?.toString() ?: "")
                            .put("labels", JSONArray(labels.toList()))
                            .put("class", focused.className?.toString() ?: "")
                            .put("enabled", focused.isEnabled).put("clickable", focused.isClickable)
                            .put("package", focused.packageName?.toString() ?: "")
                            .put("bounds", JSONArray(listOf(bounds.left, bounds.top, bounds.right, bounds.bottom)))
                    } finally { focused.recycle() }
                } finally { root.recycle() }
            }
            return null
        }
        fun touch(action: Int, x: Float, y: Float, downTime: Long) {
            val event = MotionEvent.obtain(downTime, SystemClock.uptimeMillis(), action, x, y, 0)
            event.source = InputDevice.SOURCE_TOUCHSCREEN
            try { assertTrue(automation.injectInputEvent(event, true)) } finally { event.recycle() }
        }
        fun swipeNext() {
            val metrics = instrumentation.targetContext.resources.displayMetrics
            if (kernelGestures) {
                hardwareGesture("swipe", metrics.widthPixels * 0.3f, metrics.heightPixels * 0.5f, metrics.widthPixels * 0.7f)
                SystemClock.sleep(500)
                return
            }
            val down = SystemClock.uptimeMillis()
            val y = metrics.heightPixels * 0.5f
            touch(MotionEvent.ACTION_DOWN, metrics.widthPixels * 0.3f, y, down)
            for (step in 1..6) {
                SystemClock.sleep(20)
                touch(MotionEvent.ACTION_MOVE, metrics.widthPixels * (0.3f + 0.4f * step / 6), y, down)
            }
            touch(MotionEvent.ACTION_UP, metrics.widthPixels * 0.7f, y, down)
            SystemClock.sleep(400)
        }
        fun screenshot(name: String) {
            val bitmap = checkNotNull(automation.takeScreenshot())
            try { File(instrumentation.targetContext.filesDir, "talkback-$name.png").outputStream().use {
                bitmap.compress(android.graphics.Bitmap.CompressFormat.PNG, 100, it)
            } } finally { bitmap.recycle() }
        }
        try {
            scenario.onActivity { activity ->
                val local = EditorSession.create("talkback-input", "local", JSONArray("""[
                    {"id":"p","type":"paragraph","content":[{"type":"text","text":"Original café 日本語","marks":[{"type":"italic"}]}]}
                ]"""))
                session = local
                proof.put("originalBlocks", JSONArray(local.snapshot.getJSONArray("blocks").toString()))
                local.setText("p", "Original café 日本語 local")
                activity.setContentView(ComposeView(activity).apply { setContent { MaterialTheme { BlockEditor(local) } } })
            }
            instrumentation.waitForIdleSync()
            SystemClock.sleep(1_000)
            var undo: JSONObject? = null
            fun isUndo(focus: JSONObject?): Boolean = focus?.optString("package") == "studio.seventwo.blockeditor.test" &&
                focus.optBoolean("enabled") && focus.optBoolean("clickable") &&
                (0 until focus.getJSONArray("labels").length()).any { focus.getJSONArray("labels").getString(it) == "Undo" }
            val initialFocus = recordFocus()
            focusHistory.put(initialFocus ?: JSONObject.NULL)
            var departedUndo = !isUndo(initialFocus)
            for (attempt in 0 until 20) {
                verifyService()
                // Require navigation, even if TalkBack initially focuses Undo.
                swipeNext()
                val focus = recordFocus()
                focusHistory.put(focus ?: JSONObject.NULL)
                if (focus != null && !isUndo(focus)) departedUndo = true
                if (isUndo(focus) && departedUndo) {
                    undo = focus; break
                }
            }
            assertNotNull("Real TalkBack swipe navigation must focus the enabled Undo control", undo)
            screenshot("undo-focus")
            val bounds = checkNotNull(undo).getJSONArray("bounds")
            val x = (bounds.getInt(0) + bounds.getInt(2)) / 2f
            val y = (bounds.getInt(1) + bounds.getInt(3)) / 2f
            // Double tap activates the service's focused node; never perform an AX click/focus action.
            if (kernelGestures) hardwareGesture("double-tap", x, y)
            else repeat(2) { index ->
                val down = SystemClock.uptimeMillis()
                touch(MotionEvent.ACTION_DOWN, x, y, down)
                SystemClock.sleep(30)
                touch(MotionEvent.ACTION_UP, x, y, down)
                if (index == 0) SystemClock.sleep(80)
            }
            instrumentation.waitForIdleSync()
            SystemClock.sleep(500)
            scenario.onActivity {
                assertEquals(proof.getJSONArray("originalBlocks").toString(), checkNotNull(session).snapshot.getJSONArray("blocks").toString())
                proof.put("undoSnapshot", checkNotNull(session).snapshot)
            }
            verifyService()
            screenshot("activated-undo")
            proof.put("passed", true)
        } finally {
            screenshot("final-focus")
            proof.put("focusHistory", focusHistory)
            File(instrumentation.targetContext.filesDir, "talkback-input-proof.json").writeText(proof.toString())
            scenario.close()
            instrumentation.runOnMainSync { session?.close() }
        }
    }
}
