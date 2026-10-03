package studio.seventwo.blockeditor

import android.os.Bundle
import androidx.test.platform.app.InstrumentationRegistry
import org.json.JSONObject
import android.view.inputmethod.EditorInfo
import android.view.inputmethod.InputConnection
import androidx.activity.ComponentActivity
import androidx.compose.material3.MaterialTheme
import androidx.compose.runtime.mutableStateOf
import androidx.compose.ui.ExperimentalComposeUiApi
import androidx.compose.ui.semantics.SemanticsActions
import androidx.compose.ui.semantics.SemanticsProperties
import androidx.compose.ui.platform.InterceptPlatformTextInput
import androidx.compose.ui.platform.PlatformTextInputInterceptor
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.createAndroidComposeRule
import androidx.compose.ui.text.TextRange
import org.json.JSONArray
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test
import kotlinx.coroutines.awaitCancellation

@OptIn(ExperimentalTestApi::class)
class ComposeInputTest {
    @get:Rule val compose = createAndroidComposeRule<ComponentActivity>()

    @Test fun readOnlyNestedContentShowsRecoveredTextTablesAndChecklistChildren() {
        lateinit var session: EditorSession
        compose.runOnUiThread {
            val blocks = JSONArray("""[{"id":"t","type":"toggle","summary":[{"type":"text","text":"Recovered block","marks":[]}],"children":[
                {"id":"p","type":"paragraph","content":[{"type":"text","text":"Remote Bob","marks":[]}]},
                {"id":"l","type":"list","style":"todo","items":[{"id":"i","checked":true,"content":[{"type":"text","text":"Parent","marks":[]}],"children":[{"id":"j","content":[{"type":"text","text":"Child","marks":[]}],"children":[]}]}]},
                {"id":"table","type":"table","rows":[{"id":"r","cells":[{"id":"c","content":[{"type":"text","text":"Cell text","marks":[]}]}]}]}
            ]}]""")
            session = EditorSession.create("nested-preview", "reader", blocks, collaborationVersion = 2)
        }
        try {
            compose.setContent { MaterialTheme { BlockEditor(session, readOnly = true) } }
            compose.onNodeWithText("Recovered block").assertExists()
            compose.onNodeWithText("Remote Bob").assertExists()
            compose.onNodeWithText("Parent").assertExists()
            compose.onNodeWithText("Child").assertExists()
            compose.onNodeWithText("Cell text").assertExists()
            val checks = compose.onAllNodes(isToggleable())
            checks.assertCountEquals(2)
            checks[0].assertIsOn().assertIsNotEnabled()
            checks[1].assertIsOff().assertIsNotEnabled()
            compose.onNodeWithText("Paragraph").assertIsNotEnabled()
        } finally { compose.runOnUiThread { session.close() } }
    }

    @OptIn(ExperimentalComposeUiApi::class)
    @Test fun renderedFieldPreservesSelectionAndLocalTypingAcrossRemoteEdits() {
        lateinit var a: EditorSession
        lateinit var b: EditorSession
        // This component test drives selection/text through Compose semantics.
        // Own the input session so the installed keyboard cannot introduce an
        // unrelated composing range between those actions and direct engine Undo.
        // Real keyboard composition/Undo is exercised by the opt-in IME tests.
        val interceptor = PlatformTextInputInterceptor { request, _ ->
            val connection = request.createInputConnection(EditorInfo())
            try { awaitCancellation() } finally { connection.closeConnection() }
        }
        compose.runOnUiThread {
            val blocks = JSONArray("""[{"id":"p","type":"paragraph","content":[{"type":"text","text":"Hello world","marks":[]}]}]""")
            a = EditorSession.create("compose-selection", "a", blocks)
            b = EditorSession.create("compose-selection", "b", blocks)
        }
        try {
            compose.setContent { InterceptPlatformTextInput(interceptor) { MaterialTheme { BlockEditor(a) } } }
            val field = compose.onNode(hasSetTextAction())
            field.performClick().performTextInputSelection(TextRange(11, 6))
            // The semantics selection action may normalize direction; preserve the actual UI range.
            val before = field.fetchSemanticsNode().config[SemanticsProperties.TextSelectionRange]
            assertEquals(6, before.min); assertEquals(11, before.max)
            compose.runOnIdle { b.setText("p", "RHello world"); a.receive(b.changes()) }
            assertEquals(TextRange(before.start + 1, before.end + 1), field.fetchSemanticsNode().config[SemanticsProperties.TextSelectionRange])
            field.performTextInput("there")
            compose.runOnIdle {
                assertEquals("RHello there", plainText(a.snapshot.getJSONArray("blocks").getJSONObject(0).getJSONArray("content")))
                a.undo()
                assertEquals("Engine Undo must preserve the remote prefix", "RHello world",
                    plainText(a.snapshot.getJSONArray("blocks").getJSONObject(0).getJSONArray("content")))
            }
            field.assertTextContains("RHello world")
        } finally { compose.runOnIdle { a.close(); b.close() } }
    }

    @OptIn(ExperimentalComposeUiApi::class)
    @Test fun androidInputConnectionHoldsRemoteApplyUntilCompositionCommits() {
        lateinit var a: EditorSession
        lateinit var b: EditorSession
        var connection: InputConnection? = null
        // Own this rendered field's input session. Creating another connection
        // from the focused View races the system keyboard, which can commit our
        // injected composing range. This checks the real Compose InputConnection
        // boundary; installed keyboard/system-IME acceptance remains separate.
        val interceptor = PlatformTextInputInterceptor { request, _ ->
            val current = request.createInputConnection(EditorInfo())
            connection = current
            try { awaitCancellation() }
            finally { current.closeConnection(); if (connection === current) connection = null }
        }
        compose.runOnUiThread {
            val blocks = JSONArray("""[{"id":"c","type":"code","language":"swift","code":"Hello"}]""")
            a = EditorSession.create("compose-ime", "a", blocks)
            b = EditorSession.create("compose-ime", "b", blocks)
        }
        try {
            compose.setContent { InterceptPlatformTextInput(interceptor) { MaterialTheme { BlockEditor(a) } } }
            val field = compose.onNode(hasSetTextAction())
            field.performClick().performTextInputSelection(TextRange(0))
            compose.waitUntil(5_000) { connection != null }
            compose.runOnIdle {
                assertTrue(checkNotNull(connection).setComposingText("漢", 1))
            }
            compose.waitForIdle()
            compose.runOnIdle {
                b.setText("c", "RHello", listOf("code")); a.receive(b.changes())
                assertEquals(0, a.syncState().getJSONArray("received").length())
            }
            field.assertTextContains("漢Hello")
            compose.runOnIdle { assertTrue(checkNotNull(connection).finishComposingText()) }
            compose.waitForIdle()
            field.assertTextContains("R漢Hello")
            assertEquals(TextRange(2), field.fetchSemanticsNode().config[SemanticsProperties.TextSelectionRange])
            compose.runOnIdle { a.undo() }
            field.assertTextContains("RHello")
        } finally { compose.runOnIdle { a.close(); b.close() } }
    }
    @OptIn(ExperimentalComposeUiApi::class)
    @Test fun unchangedNativeRecompositionEndsBeforeHistoryAndRevokesOldCallbacks() {
        lateinit var a: EditorSession
        lateinit var b: EditorSession
        var connection: InputConnection? = null
        var nextConnectionSerial = 0
        var currentConnectionSerial: Int? = null
        val connectionEvents = JSONArray()
        val closedConnections = mutableSetOf<Int>()
        var originalConnection: InputConnection? = null
        var originalSerial: Int? = null
        fun receiptIDs(received: JSONArray): Set<Pair<Long, String>> = buildSet {
            for (index in 0 until received.length()) {
                val id = received.getJSONObject(index)
                add(id.getLong("counter") to id.getString("actor"))
            }
        }
        fun acceptedState(): JSONObject = JSONObject().put("snapshot", JSONObject(a.snapshot.toString()))
            .put("receipt", runCatching { JSONObject(a.syncState().toString()) }
                .getOrElse { JSONObject().put("unavailable", it.toString()) })
        val beforeComposition = setOf(1L to "a", 2L to "a")
        // Own the actual Compose InputConnection for a deterministic component
        // witness. BuiltinImeTest still drives the installed keyboard and taps.
        val interceptor = PlatformTextInputInterceptor { request, _ ->
            val current = request.createInputConnection(EditorInfo())
            val serial = ++nextConnectionSerial
            connectionEvents.put(JSONObject().put("event", "created").put("serial", serial)
                .put("objectIdentity", System.identityHashCode(current)).put("replacedSerial", currentConnectionSerial ?: JSONObject.NULL)
                .put("accepted", acceptedState()))
            connection = current; currentConnectionSerial = serial
            try { awaitCancellation() }
            finally {
                current.closeConnection(); closedConnections.add(serial)
                connectionEvents.put(JSONObject().put("event", "closed").put("serial", serial)
                    .put("wasLatest", connection === current).put("currentSerial", currentConnectionSerial ?: JSONObject.NULL)
                    .put("accepted", acceptedState()))
                if (connection === current) { connection = null; currentConnectionSerial = null }
            }
        }
        compose.runOnUiThread {
            val blocks = JSONArray("""[{"id":"c","type":"code","code":"R","language":"swift","host":{"opaque":true}}]""")
            a = EditorSession.create("native-history", "a", blocks)
            b = EditorSession.create("native-history", "b", blocks)
            a.setText("c", "Rcat ", listOf("code")); a.undo()
            // A receipt acknowledges every accepted change, including this
            // author's original edit and Undo; it is not a remote-only count.
            assertEquals(beforeComposition, receiptIDs(a.syncState().getJSONArray("received")))
        }
        try {
            compose.setContent { InterceptPlatformTextInput(interceptor) { MaterialTheme { BlockEditor(a) } } }
            val field = compose.onNode(hasSetTextAction())
            field.performClick().performTextInputSelection(TextRange(1))
            compose.waitUntil(5_000) { connection != null }
            originalConnection = connection; originalSerial = currentConnectionSerial
            fun diagnose(stage: String, failure: String? = null) {
                val fieldSemantics = runCatching { field.fetchSemanticsNode().config }.getOrNull()
                val redoSemantics = runCatching { compose.onNodeWithText("Redo").fetchSemanticsNode().config }.getOrNull()
                val focused = fieldSemantics?.let { if (it.contains(SemanticsProperties.Focused)) it[SemanticsProperties.Focused] else false }
                val selection = fieldSemantics?.let { if (it.contains(SemanticsProperties.TextSelectionRange)) it[SemanticsProperties.TextSelectionRange].toString() else null }
                val displayed = fieldSemantics?.let { if (it.contains(SemanticsProperties.EditableText)) it[SemanticsProperties.EditableText].text else null }
                compose.runOnIdle {
                    val evidence = JSONObject().put("stage", stage).put("failure", failure ?: JSONObject.NULL)
                        .put("scope", "Owned Compose InputConnection; physical history touch; installed-IME acceptance separate")
                        .put("originalSerial", originalSerial ?: JSONObject.NULL)
                        .put("originalClosed", originalSerial?.let { it in closedConnections } ?: false)
                        .put("currentSerial", currentConnectionSerial ?: JSONObject.NULL)
                        .put("currentIsOriginal", connection != null && connection === originalConnection)
                        .put("currentIsNull", connection == null).put("connectionEvents", JSONArray(connectionEvents.toString()))
                        .put("snapshot", JSONObject(a.snapshot.toString())).put("receipt", JSONObject(a.syncState().toString()))
                        .put("fieldFocused", focused ?: JSONObject.NULL).put("fieldSelection", selection ?: JSONObject.NULL)
                        .put("displayedText", displayed ?: JSONObject.NULL)
                        .put("redoDisabled", redoSemantics?.contains(SemanticsProperties.Disabled) ?: JSONObject.NULL)
                    val instrumentation = InstrumentationRegistry.getInstrumentation()
                    instrumentation.targetContext.filesDir.resolve("native-history-connection-$stage.json").writeText(evidence.toString(2))
                    instrumentation.sendStatus(2, Bundle().apply { putString("stream", "\nNATIVE_HISTORY_CONNECTION " + evidence.toString() + "\n") })
                }
            }
            val oldSetText = checkNotNull(field.fetchSemanticsNode().config[SemanticsActions.SetText].action)
            compose.runOnIdle {
                assertTrue(checkNotNull(connection).setComposingRegion(0, 1))
            }
            compose.waitForIdle()
            compose.runOnIdle {
                b.setText("c", "BR", listOf("code")); a.receive(b.changes())
                assertEquals("The peer edit must remain unacknowledged while composing", beforeComposition,
                    receiptIDs(a.syncState().getJSONArray("received")))
                assertTrue(a.snapshot.getBoolean("canRedo"))
            }
            field.assertTextContains("R")
            diagnose("before-redo")
            compose.onNodeWithText("Redo").assertIsEnabled().performTouchInput { click() }
            // Android may reopen input for the still-focused field. The retired
            // connection must close; a fresh connection need not stay absent.
            try { compose.waitUntil(5_000) {
                checkNotNull(originalSerial) in closedConnections && connection !== originalConnection
            } }
            catch (failure: Throwable) {
                try { diagnose("connection-timeout", failure.toString()) } catch (diagnostic: Throwable) { failure.addSuppressed(diagnostic) }
                throw failure
            }
            diagnose("after-redo")
            compose.runOnIdle {
                assertEquals("BRcat ", a.snapshot.getJSONArray("blocks").getJSONObject(0).getString("code"))
                assertEquals(beforeComposition + setOf(1L to "b", 3L to "a"),
                    receiptIDs(a.syncState().getJSONArray("received")))
                // Original edit, Undo, remote edit, Redo; ending unchanged native
                // composition must not manufacture another author edit.
                assertEquals(4, a.changes().getJSONArray("changes").length())
                assertTrue(a.snapshot.getJSONArray("blocks").getJSONObject(0).getJSONObject("host").getBoolean("opaque"))
                val accepted = a.save().toString()
                checkNotNull(originalConnection).setComposingText("late retired composition", 1)
                checkNotNull(originalConnection).commitText("late retired commit", 1)
                checkNotNull(originalConnection).finishComposingText()
                oldSetText(androidx.compose.ui.text.AnnotatedString("late old callback"))
                assertEquals(accepted, a.save().toString())
                assertEquals(beforeComposition + setOf(1L to "b", 3L to "a"),
                    receiptIDs(a.syncState().getJSONArray("received")))
            }
            field.assertTextContains("BRcat ")
            assertEquals("BRcat ", field.fetchSemanticsNode().config[SemanticsProperties.EditableText].text)
            val oldUndo = checkNotNull(compose.onNodeWithText("Undo").fetchSemanticsNode().config[SemanticsActions.OnClick].action)
            field.performClick().performTextInputSelection(TextRange(0))
            compose.waitUntil(5_000) { connection != null }
            lateinit var accepted: String
            compose.runOnIdle {
                accepted = a.save().toString()
                assertTrue(checkNotNull(connection).setComposingText("draft", 1))
            }
            compose.waitForIdle()
            compose.onNodeWithText("Undo").assertIsNotEnabled()
            compose.runOnIdle {
                oldUndo()
                assertEquals("A changed native draft must block retained history actions", accepted, a.save().toString())
            }
            field.assertTextContains("draftBRcat ")
        } finally { compose.runOnIdle { a.close(); b.close() } }
    }

    @OptIn(ExperimentalComposeUiApi::class)
    @Test fun retainedNativeTextCallbackHonorsLiveReadOnlyPermission() {
        lateinit var a: EditorSession
        var connection: InputConnection? = null
        val readOnly = mutableStateOf(false)
        val interceptor = PlatformTextInputInterceptor { request, _ ->
            val current = request.createInputConnection(EditorInfo())
            connection = current
            try { awaitCancellation() }
            finally { current.closeConnection(); if (connection === current) connection = null }
        }
        compose.runOnUiThread {
            a = EditorSession.create("native-readonly", "a", JSONArray("""[{"id":"c","type":"code","code":"P","language":"swift"}]"""))
        }
        try {
            compose.setContent { InterceptPlatformTextInput(interceptor) { MaterialTheme { BlockEditor(a, readOnly = readOnly.value) } } }
            val field = compose.onNode(hasSetTextAction())
            field.performClick().performTextInputSelection(TextRange(1))
            compose.waitUntil(5_000) { connection != null }
            val retainedSetText = checkNotNull(field.fetchSemanticsNode().config[SemanticsActions.SetText].action)
            compose.runOnIdle { readOnly.value = true }
            compose.waitForIdle()
            compose.onNodeWithText("Paragraph").assertIsNotEnabled()
            lateinit var acceptedBeforeSelection: String
            lateinit var receiptBeforeSelection: String
            compose.runOnIdle {
                acceptedBeforeSelection = a.save().toString()
                receiptBeforeSelection = a.syncState().toString()
            }
            field.performTextInputSelection(TextRange(0, 1))
            assertEquals(TextRange(0, 1), field.fetchSemanticsNode().config[SemanticsProperties.TextSelectionRange])
            compose.runOnIdle {
                assertEquals(acceptedBeforeSelection, a.save().toString())
                assertEquals(receiptBeforeSelection, a.syncState().toString())
            }
            compose.runOnIdle {
                val accepted = a.save().toString(); val receipt = a.syncState().toString()
                retainedSetText(androidx.compose.ui.text.AnnotatedString("late editable callback"))
                assertEquals("Retained editable callback must honor current read-only permission", accepted, a.save().toString())
                assertEquals(receipt, a.syncState().toString())
            }
            compose.onNodeWithText("P").assertExists()
            compose.runOnIdle { readOnly.value = false }
            compose.waitForIdle()
            field.performClick().performTextInputSelection(TextRange(1))
            field.performTextInput("X")
            compose.runOnIdle { assertEquals("PX", a.snapshot.getJSONArray("blocks").getJSONObject(0).getString("code")) }
        } finally { compose.runOnIdle { a.close() } }
    }

}
