package studio.seventwo.blockeditor

import android.content.ClipboardManager
import android.content.Context
import android.view.inputmethod.EditorInfo
import android.view.inputmethod.InputConnection
import androidx.activity.ComponentActivity
import androidx.compose.material3.MaterialTheme
import androidx.compose.runtime.mutableStateOf
import androidx.compose.ui.ExperimentalComposeUiApi
import androidx.compose.ui.platform.InterceptPlatformTextInput
import androidx.compose.ui.platform.PlatformTextInputInterceptor
import androidx.compose.ui.semantics.SemanticsActions
import androidx.compose.ui.semantics.SemanticsProperties
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.createAndroidComposeRule
import androidx.compose.ui.text.TextRange
import kotlinx.coroutines.awaitCancellation
import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test

/** Actual Compose commands/InputConnection; installed keyboard acceptance is separate. */
@OptIn(ExperimentalComposeUiApi::class, ExperimentalTestApi::class)
class WritingAuthoringComposeTest {
    @get:Rule val compose=createAndroidComposeRule<ComponentActivity>()
    private fun seed()=JSONArray("""[{"id":"p","type":"paragraph","host":"keep","content":[{"type":"text","text":"AB","marks":[{"type":"bold"}]},{"type":"entity-ref","entityType":"person","entityId":"mira","label":"Mira","host":"opaque"}]}]""")
    private fun text(session:WritingSession)=plainText(session.snapshot.getJSONArray("blocks").getJSONObject(0).getJSONArray("content"))

    @Test fun renderedStructuredPasteFinalizesMarkedTextDrainsPeerAndRevokesOldAction() {
        lateinit var a:WritingSession;lateinit var b:WritingSession;var connection:InputConnection?=null
        val visible=mutableStateOf(true)
        val interceptor=PlatformTextInputInterceptor {request,_->
            val current=request.createInputConnection(EditorInfo());connection=current
            try {awaitCancellation()} finally {current.closeConnection();if(connection===current)connection=null}
        }
        compose.runOnUiThread {
            a=WritingSession.createV6("compose-native-paste","a","six",seed());b=WritingSession.createV6("compose-native-paste","b","six",seed())
            val manager=compose.activity.getSystemService(Context.CLIPBOARD_SERVICE) as ClipboardManager
            WritingNativeClipboard.write(manager,WritingClipboard.restore(JSONObject("""{"version":1,"parts":[{"inline":{"_0":[{"type":"text","text":"X😀","marks":[{"type":"italic"}]},{"type":"entity-ref","entityType":"task","entityId":"task","label":"Task","host":"paste-meta"}]}}]}""")))
        }
        try {
            compose.setContent {InterceptPlatformTextInput(interceptor){MaterialTheme{run{
                val state=rememberWritingParagraphEditorState(a,{assertTrue(it.isEmpty())},reportError={throw it})
                if(visible.value)WritingParagraphEditor(state,reportError={throw it})
            }}}}
            val field=compose.onNode(hasSetTextAction());field.performClick();field.performTextInputSelection(TextRange(1))
            compose.waitUntil {connection!=null}
            compose.runOnIdle {assertTrue(checkNotNull(connection).setComposingText("東京",1))}
            compose.runOnIdle {b.replaceText(b.textAddress(b.node(NodeAddress("p"))),6,6,"R");a.receive(b.changes());assertEquals("ABMira",text(a));assertEquals(1,a.exportDeferredChanges().size)}
            val stalePaste=checkNotNull(compose.onNodeWithTag("writing-paste").fetchSemanticsNode().config[SemanticsActions.OnClick].action)
            compose.onNodeWithTag("writing-paste").assertIsEnabled().performClick()
            compose.runOnIdle {assertEquals("A東京X😀TaskBMiraR",text(a));assertTrue(a.exportDeferredChanges().isEmpty());assertTrue(a.snapshot.toString().contains("paste-meta"));assertTrue(a.snapshot.toString().contains("opaque"))}
            val focused=compose.onNode(hasSetTextAction() and isFocused());focused.assertTextContains("A東京X😀TaskBMiraR")
            assertEquals(TextRange(10),focused.fetchSemanticsNode().config[SemanticsProperties.TextSelectionRange])
            compose.runOnIdle {val accepted=a.save().export().toString();stalePaste();assertEquals(accepted,a.save().export().toString());val reopened=WritingSession.restore(a.save(),"a");try{reopened.undo();assertEquals("A東京BMiraR",text(reopened));reopened.redo();assertEquals("A東京X😀TaskBMiraR",text(reopened))}finally{reopened.close()}}
        }finally {compose.runOnIdle{visible.value=false};compose.waitForIdle();compose.runOnIdle{a.close();b.close()}}
    }

    @Test fun renderedFormattingAndConversionRetainOpaqueInputAndLivePermission() {
        lateinit var a:WritingSession;val visible=mutableStateOf(true);val readonly=mutableStateOf(false)
        val interceptor=PlatformTextInputInterceptor {request,_->val current=request.createInputConnection(EditorInfo());try{awaitCancellation()}finally{current.closeConnection()}}
        compose.runOnUiThread {a=WritingSession.createV5("compose-native-format","a","five",seed())}
        try {
            compose.setContent {InterceptPlatformTextInput(interceptor){MaterialTheme{run{
                val state=rememberWritingParagraphEditorState(a,{assertTrue(it.isEmpty())},reportError={throw it})
                androidx.compose.runtime.SideEffect {state.readOnly=readonly.value}
                if(visible.value)WritingParagraphEditor(state,reportError={throw it})
            }}}}
            val field=compose.onNode(hasSetTextAction());field.performClick();field.performTextInputSelection(TextRange(2,0))
            val original=field.fetchSemanticsNode().config[SemanticsProperties.TextSelectionRange]
            val stale=checkNotNull(compose.onNodeWithTag("writing-italic").fetchSemanticsNode().config[SemanticsActions.OnClick].action)
            compose.runOnIdle {readonly.value=true};compose.waitForIdle()
            compose.runOnIdle {val before=a.save().export().toString();stale();assertEquals(before,a.save().export().toString());readonly.value=false}
            compose.waitForIdle();field.performClick();field.performTextInputSelection(original)
            compose.onNodeWithTag("writing-italic").performClick()
            compose.runOnIdle {assertTrue(a.snapshot.getJSONArray("blocks").getJSONObject(0).getJSONArray("content").toString().contains("italic"))}
            compose.onNode(hasSetTextAction() and isFocused()).assertTextContains("ABMira")
            val origin=compose.runOnIdle {a.node(NodeAddress("p"))}
            compose.onNodeWithTag("writing-heading").performClick()
            compose.onNode(hasSetTextAction() and isFocused()).assertTextContains("ABMira")
            compose.runOnIdle {assertEquals("heading",a.snapshot.getJSONArray("blocks").getJSONObject(0).getString("type"));assertEquals(writingCanonical(origin.wire),writingCanonical(a.node(NodeAddress("p")).wire));val accepted=a.save().export().toString();stale();assertEquals(accepted,a.save().export().toString())}
        }finally {compose.runOnIdle{visible.value=false};compose.waitForIdle();compose.runOnIdle{a.close()}}
    }
}
