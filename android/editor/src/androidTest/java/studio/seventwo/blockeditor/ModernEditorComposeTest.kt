package studio.seventwo.blockeditor

import android.content.Context
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.test.core.app.ApplicationProvider
import androidx.test.ext.junit.runners.AndroidJUnit4
import kotlinx.coroutines.runBlocking
import org.json.JSONArray
import org.json.JSONObject
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import java.io.File
import java.util.UUID

@RunWith(AndroidJUnit4::class)
class ModernEditorComposeTest {
    @get:Rule val compose = createComposeRule()
    @Test fun modernNativeTypingAndHistoryReopenThroughActualJni() {
        val context = ApplicationProvider.getApplicationContext<Context>(); val file = File(context.cacheDir, "modern-${UUID.randomUUID()}.json")
        val store = ModernHostStore(file); lateinit var host: ModernAndroidHost; lateinit var state: ModernBlockEditorState
        compose.setContent {
            val document = ModernDocument.restore(JSONObject().put("format", "seventwo.block-editor.document").put("formatVersion", 1).put("documentID", "modern-ui")
                .put("title", "Help").put("appearance", JSONObject().put("fontFamily", "sans").put("fontSize", "default").put("pageWidth", "readable"))
                .put("blocks", JSONArray().put(JSONObject().put("id", "body").put("type", "paragraph").put("content", JSONArray()))))
            val current = androidx.compose.runtime.remember { ModernAndroidHost(ModernSession.create(document, "author", "epoch"), "author", store) }
            host = current; state = rememberModernBlockEditorState(current)
            ModernBlockEditor(state)
        }
        compose.onNodeWithContentDescription("Block text").performClick().performTextInput("Unicode 😀")
        compose.onNodeWithContentDescription("Block text").assertTextContains("Unicode 😀")
        compose.onNodeWithText("Undo", useUnmergedTree = true).performClick()
        compose.onNodeWithContentDescription("Block text").assertTextEquals("")
        compose.runOnIdle { state.execute(ModernCommand.Redo) }
        compose.onNodeWithContentDescription("Block text").assertTextContains("Unicode 😀")
        compose.runOnIdle { runBlocking { host.save() } }
        val pair = runBlocking { store.load() }!!
        compose.runOnIdle {
            val restored = ModernAndroidHost.restore(pair, store)
            try { org.junit.Assert.assertEquals("Unicode 😀", restored.first.session.text(restored.first.session.field(restored.first.session.nodes().first()))) }
            finally { restored.first.session.close() }
        }
        file.delete()
    }
}
