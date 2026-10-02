package studio.seventwo.blockeditor

import android.view.inputmethod.EditorInfo
import android.view.inputmethod.InputConnection
import androidx.activity.ComponentActivity
import androidx.compose.material3.MaterialTheme
import androidx.compose.runtime.mutableStateOf
import androidx.compose.ui.ExperimentalComposeUiApi
import androidx.compose.ui.focus.focusProperties
import androidx.compose.ui.platform.InterceptPlatformTextInput
import androidx.compose.ui.platform.PlatformTextInputInterceptor
import androidx.compose.ui.semantics.SemanticsActions
import androidx.compose.ui.semantics.SemanticsProperties
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.createAndroidComposeRule
import androidx.compose.ui.text.AnnotatedString
import androidx.compose.ui.text.TextRange
import kotlinx.coroutines.awaitCancellation
import org.json.JSONArray
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test

/** Real Compose InputConnection/component proof, not installed keyboard acceptance. */
@OptIn(ExperimentalComposeUiApi::class, ExperimentalTestApi::class)
class WritingComposeInputTest {
    @get:Rule val compose = createAndroidComposeRule<ComponentActivity>()
    private fun seed() = JSONArray("""[{"id":"p","type":"paragraph","content":[{"type":"text","text":"AB","marks":[{"type":"bold"}]},{"type":"entity-ref","entityType":"person","entityId":"mira","label":"Mira","host":"opaque"}]}]""")
    private fun texts(session: WritingSession) = session.snapshot.getJSONArray("blocks").let { blocks ->
        (0 until blocks.length()).map { plainText(blocks.getJSONObject(it).getJSONArray("content")) }
    }
    private fun retainedDrafts(drafts: List<WritingInputDraft>) { assertTrue("No pending draft in this test", drafts.isEmpty()) }

    @Test fun returnedCaretWaitsForActualNativeDestinationFocus() {
        lateinit var a: WritingSession
        lateinit var owner: WritingParagraphEditorState
        val visible = mutableStateOf(true)
        val allowTailFocus = mutableStateOf(false)
        val interceptor = PlatformTextInputInterceptor { request, _ ->
            val connection = request.createInputConnection(EditorInfo())
            try { awaitCancellation() } finally { connection.closeConnection() }
        }
        compose.runOnUiThread { a = WritingSession.createV4("compose-focus-adoption", "a", "v4", seed()) }
        try {
            compose.setContent { InterceptPlatformTextInput(interceptor) { MaterialTheme {
                owner = rememberWritingParagraphEditorState(a, ::retainedDrafts, reportError = { throw it })
                if (visible.value) {
                    val snapshot = a.snapshot
                    val roots = androidx.compose.runtime.remember(a, snapshot) { a.collectionNodes(NodeCollection.ROOT) }
                    roots.forEachIndexed { index, identity ->
                        androidx.compose.runtime.key(writingCanonical(identity.wire)) {
                            val permitted = index == 0 || allowTailFocus.value
                            androidx.compose.foundation.layout.Column(androidx.compose.ui.Modifier.focusProperties { canFocus = permitted }) {
                                WritingTextField(a, owner.inputs, identity, false, { throw it })
                            }
                        }
                    }
                }
            } } }
            val source = compose.onNode(hasSetTextAction())
            source.performClick(); source.performTextInputSelection(TextRange(6))
            compose.onNodeWithTag("writing-enter").performClick()
            // Pending caret ownership makes the field read-only, so SetText
            // semantics are intentionally absent until actual focus adoption.
            val tailTag = compose.runOnIdle { "writing-text:${a.collectionNodes(NodeCollection.ROOT)[1].wire}" }
            val tail = compose.onNodeWithTag(tailTag)
            tail.assertIsNotFocused()
            compose.runOnIdle {
                val pending = checkNotNull(owner.inputs.focusRequest) { "Unfocused destination must retain its caret request" }
                assertEquals(0, a.resolvePosition(pending.range.start).offset)
                assertTrue(owner.pendingDrafts().isEmpty())
                assertEquals(listOf("ABMira", ""), texts(a))
                allowTailFocus.value = true
            }
            tail.performClick(); tail.assertIsFocused()
            assertEquals(TextRange(0), tail.fetchSemanticsNode().config[SemanticsProperties.TextSelectionRange])
            compose.runOnIdle {
                assertNull(owner.inputs.focusRequest); assertTrue(owner.pendingDrafts().isEmpty())
                val reopened = WritingSession.restore(a.save(), "a")
                try {
                    reopened.undo(); assertEquals(listOf("ABMira"), texts(reopened))
                    reopened.redo(); assertEquals(a.snapshot.toString(), reopened.snapshot.toString())
                } finally { reopened.close() }
            }
        } finally {
            compose.runOnIdle { visible.value = false }; compose.waitForIdle()
            compose.runOnIdle { owner.close(); a.close() }
        }
    }

    @Test fun sameFieldSoftBreakKeepsCaretOwnershipAgainstSiblingFocusDuringHandoff() {
        lateinit var a: WritingSession; lateinit var b: WritingSession
        lateinit var owner: WritingParagraphEditorState
        val visible = mutableStateOf(true)
        var connection: InputConnection? = null
        var phase = "setup"
        var primaryFailure: Throwable? = null
        fun checkpoint(stage: String) {
            val drafts = owner.pendingDrafts()
            println("ST97_FOCUS_CHECKPOINT " + org.json.JSONObject().put("stage", stage).put("phase", phase)
                .put("pendingTarget", owner.inputs.focusRequest?.key ?: org.json.JSONObject.NULL)
                .put("drafts", JSONArray(drafts.map { draft -> org.json.JSONObject()
                    .put("address", draft.address.export()).put("text", draft.text)
                    .put("selectionStart", draft.selectionStart).put("selectionEnd", draft.selectionEnd)
                    .put("reason", draft.reason) })).put("accepted", a.snapshot))
        }
        val interceptor = PlatformTextInputInterceptor { request, _ ->
            val current = request.createInputConnection(EditorInfo()); connection = current
            try { awaitCancellation() } finally { current.closeConnection(); if (connection === current) connection = null }
        }
        compose.runOnUiThread {
            val blocks = seed().put(org.json.JSONObject("""{"id":"rich","type":"paragraph","content":[{"type":"text","text":"Sibling😀","marks":[{"type":"italic"}]},{"type":"entity-ref","entityType":"person","entityId":"peer","label":"Reference","host":"opaque-sibling"}]}"""))
            a = WritingSession.createV4("compose-same-field-caret", "a", "v4", blocks)
            b = WritingSession.createV4("compose-same-field-caret", "b", "v4", blocks)
        }
        try {
            compose.setContent { InterceptPlatformTextInput(interceptor) { MaterialTheme { run {
                owner = rememberWritingParagraphEditorState(a, { drafts ->
                    if (drafts.isNotEmpty()) println("ST97_RETAINED_DRAFT phase=$phase primary=${primaryFailure?.message} drafts=${drafts.map { Triple(it.address.export(), it.text, it.reason) }}")
                    retainedDrafts(drafts)
                }, reportError = { throw it })
                if (visible.value) WritingParagraphEditor(owner, reportError = { throw it })
            } } } }
            val fields = compose.onAllNodes(hasSetTextAction())
            fields[0].performClick(); fields[0].performTextInputSelection(TextRange(1))
            compose.waitUntil { connection != null }
            compose.runOnIdle { assertTrue(checkNotNull(connection).setComposingText("東京", 1)) }
            compose.runOnIdle {
                b.replaceText(b.textAddress(b.node(NodeAddress("p"))), 6, 6, "R"); a.receive(b.changes())
                assertEquals(1, a.exportDeferredChanges().size)
            }
            val command = checkNotNull(compose.onNodeWithTag("writing-soft-break").fetchSemanticsNode().config[SemanticsActions.OnClick].action)
            val siblingFocus = checkNotNull(fields[1].fetchSemanticsNode().config[SemanticsActions.RequestFocus].action)
            val siblingBefore = compose.runOnIdle { a.snapshot.getJSONArray("blocks").getJSONObject(1).toString() }
            phase = "shared-command"
            compose.runOnIdle {
                command()
                checkpoint("after-command")
                assertNotNull("Same-field caret must stay owned until its native node attaches", owner.inputs.focusRequest)
                // A semantics request may be handled/deferred before layout;
                // its Boolean is not the eventual native focus owner. The
                // retained target and actual focused field below are the oracle.
                println("ST97_SIBLING_FOCUS_REQUEST handled=${siblingFocus()}")
                assertNotNull(owner.inputs.focusRequest)
                assertTrue(owner.pendingDrafts().isEmpty())
            }
            phase = "target-focus"
            val focused = compose.onNode(hasSetTextAction() and isFocused())
            focused.assertTextContains("A東京\nBMiraR")
            assertEquals(TextRange(4), focused.fetchSemanticsNode().config[SemanticsProperties.TextSelectionRange])
            compose.runOnIdle {
                assertTrue(owner.pendingDrafts().isEmpty()); assertTrue(a.exportDeferredChanges().isEmpty())
                assertEquals(siblingBefore, a.snapshot.getJSONArray("blocks").getJSONObject(1).toString())
                val reopened = WritingSession.restore(a.save(), "a")
                try {
                    reopened.undo(); assertEquals("A東京BMiraR", texts(reopened)[0])
                    reopened.redo(); assertEquals("A東京\nBMiraR", texts(reopened)[0])
                    assertEquals(siblingBefore, reopened.snapshot.getJSONArray("blocks").getJSONObject(1).toString())
                } finally { reopened.close() }
            }
            // After caret adoption, deliberate user focus on the sibling works.
            val acceptedBeforeSibling = compose.runOnIdle { a.save().export().toString() }
            phase = "deliberate-sibling-focus"
            fields[1].performClick(); fields[1].assertIsFocused()
            // Deterministic native caret inside the displayed atomic label;
            // API26 physical click produced this exact17/17 position.
            fields[1].performTextInputSelection(TextRange(17))
            assertEquals(TextRange(18), fields[1].fetchSemanticsNode().config[SemanticsProperties.TextSelectionRange])
            compose.runOnIdle {
                assertEquals(acceptedBeforeSibling, a.save().export().toString())
                assertTrue(owner.pendingDrafts().isEmpty())
            }
            compose.waitUntil { connection != null }
            phase = "sibling-composition-finalization"
            compose.runOnIdle {
                checkpoint("before-sibling-finalization")
                // Exercise real unchanged native composition, then finalize it;
                // closing a deliberately focused input must not discard a draft.
                assertTrue(checkNotNull(connection).setComposingRegion(0, "Sibling😀".length))
            }
            compose.runOnIdle {
                assertEquals(acceptedBeforeSibling, a.save().export().toString())
                assertEquals("rich", owner.pendingDrafts().single().address.blockID)
                checkpoint("genuine-sibling-composition")
                assertTrue(checkNotNull(connection).finishComposingText())
            }
            compose.runOnIdle {
                assertEquals(acceptedBeforeSibling, a.save().export().toString())
                assertTrue(owner.pendingDrafts().isEmpty())
                checkpoint("before-clean-teardown")
            }
        } catch (error: Throwable) {
            primaryFailure = error
            println("ST97_PRIMARY_FAILURE phase=$phase error=${error.javaClass.name}: ${error.message}")
            try { compose.runOnIdle { checkpoint("primary-failure") } }
            catch (diagnostic: Throwable) { error.addSuppressed(diagnostic) }
            throw error
        } finally {
            try {
                phase = "cleanup"
                compose.runOnIdle { visible.value = false }; compose.waitForIdle()
                compose.runOnIdle { a.close(); b.close() }
            } catch (cleanup: Throwable) {
                val original = primaryFailure
                if (original == null) throw cleanup
                original.addSuppressed(cleanup)
                println("ST97_SECONDARY_CLEANUP_FAILURE ${cleanup.javaClass.name}: ${cleanup.message}")
            }
        }
    }

    @Test fun nativeMarkedTextAndHeldPeerCommitBeforeActualSharedEnter() {
        lateinit var a: WritingSession; lateinit var b: WritingSession
        val visible = mutableStateOf(true)
        var connection: InputConnection? = null
        val interceptor = PlatformTextInputInterceptor { request, _ ->
            val current = request.createInputConnection(EditorInfo()); connection = current
            try { awaitCancellation() } finally { current.closeConnection(); if (connection === current) connection = null }
        }
        compose.runOnUiThread {
            a = WritingSession.createV4("compose-shared-enter", "a", "v4", seed())
            b = WritingSession.createV4("compose-shared-enter", "b", "v4", seed())
        }
        try {
            compose.setContent { InterceptPlatformTextInput(interceptor) { MaterialTheme { run {
                val state = rememberWritingParagraphEditorState(a, ::retainedDrafts, reportError = { throw it })
                if (visible.value) WritingParagraphEditor(state, reportError = { throw it })
            } } } }
            val field = compose.onNode(hasSetTextAction()); field.performClick(); field.performTextInputSelection(TextRange(1))
            compose.waitUntil { connection != null }
            compose.runOnIdle { assertTrue(checkNotNull(connection).setComposingText("東京", 1)) }
            compose.runOnIdle {
                assertEquals(listOf("ABMira"), texts(a))
                b.replaceText(b.textAddress(b.node(NodeAddress("p"))), 6, 6, "R"); a.receive(b.changes())
                assertEquals(listOf("ABMira"), texts(a)); assertEquals(1, a.exportDeferredChanges().size)
            }
            field.assertTextContains("A東京BMira")
            compose.onNodeWithTag("writing-enter").assertIsEnabled().performClick()
            compose.runOnIdle {
                assertEquals(listOf("A東京", "BMiraR"), texts(a)); assertTrue(a.exportDeferredChanges().isEmpty())
                val rich = a.snapshot.getJSONArray("blocks").toString(); assertTrue(rich.contains("mira")); assertTrue(rich.contains("bold")); assertTrue(rich.contains("opaque"))
            }
            val focused = compose.onNode(hasSetTextAction() and isFocused()); focused.assertTextContains("BMiraR")
            assertEquals(TextRange(0), focused.fetchSemanticsNode().config[SemanticsProperties.TextSelectionRange])
            compose.onNodeWithTag("writing-undo").assertIsEnabled().performClick()
            compose.runOnIdle { assertEquals(listOf("A東京BMiraR"), texts(a)) }
            compose.onNodeWithTag("writing-redo").assertIsEnabled().performClick()
            compose.runOnIdle { assertEquals(listOf("A東京", "BMiraR"), texts(a)) }
        } finally {
            compose.runOnIdle { visible.value = false }; compose.waitForIdle()
            compose.runOnIdle { a.close(); b.close() }
        }
    }

    @Test fun renderedUnicodeSelectionRebasesThenReplacesOnlySharedAtoms() {
        lateinit var a: WritingSession; lateinit var b: WritingSession
        val visible = mutableStateOf(true)
        val interceptor = PlatformTextInputInterceptor { request, _ ->
            val connection = request.createInputConnection(EditorInfo()); try { awaitCancellation() } finally { connection.closeConnection() }
        }
        compose.runOnUiThread {
            val blocks = JSONArray("""[{"id":"p","type":"paragraph","content":[{"type":"text","text":"A😀B","marks":[{"type":"bold"}]},{"type":"entity-ref","entityType":"person","entityId":"mira","label":"Mira"}]}]""")
            a = WritingSession.createV4("compose-shared-selection", "a", "v4", blocks)
            b = WritingSession.createV4("compose-shared-selection", "b", "v4", blocks)
        }
        try {
            compose.setContent { InterceptPlatformTextInput(interceptor) { MaterialTheme { run {
                val state = rememberWritingParagraphEditorState(a, ::retainedDrafts, reportError = { throw it })
                if (visible.value) WritingParagraphEditor(state, reportError = { throw it })
            } } } }
            val field = compose.onNode(hasSetTextAction()); field.performClick(); field.performTextInputSelection(TextRange(3, 1))
            val nativeSelection = field.fetchSemanticsNode().config[SemanticsProperties.TextSelectionRange]
            assertEquals(1, nativeSelection.min); assertEquals(3, nativeSelection.max)
            // Preserve whichever direction the actual Android control accepted.
            compose.runOnIdle { b.replaceText(b.textAddress(b.node(NodeAddress("p"))), 0, 0, "R"); a.receive(b.changes()) }
            assertEquals(TextRange(nativeSelection.start + 1, nativeSelection.end + 1), field.fetchSemanticsNode().config[SemanticsProperties.TextSelectionRange])
            field.performTextInput("東京")
            compose.runOnIdle {
                assertEquals(listOf("RA東京BMira"), texts(a))
                assertTrue(a.snapshot.getJSONArray("blocks").toString().contains("mira"))
                val restored = WritingSession.restore(a.save(), "a")
                try { restored.undo(); assertEquals(listOf("RA😀BMira"), texts(restored)) } finally { restored.close() }
            }
        } finally {
            compose.runOnIdle { visible.value = false }; compose.waitForIdle()
            compose.runOnIdle { a.close(); b.close() }
        }
    }

    @Test fun retainedRenderedSetTextCannotWriteAfterPermissionRevocation() {
        lateinit var a: WritingSession; val readonly = mutableStateOf(false)
        var renderedOwner: WritingParagraphEditorState? = null
        val visible = mutableStateOf(true)
        val interceptor = PlatformTextInputInterceptor { request, _ ->
            val connection = request.createInputConnection(EditorInfo()); try { awaitCancellation() } finally { connection.closeConnection() }
        }
        compose.runOnUiThread { a = WritingSession.createV4("compose-shared-readonly", "a", "v4", seed()) }
        try {
            compose.setContent { InterceptPlatformTextInput(interceptor) { MaterialTheme { run {
                val state = rememberWritingParagraphEditorState(a, ::retainedDrafts, reportError = { throw it })
                // Observe the requested permission during composition. A read
                // only inside SideEffect does not subscribe this composition to
                // changes of the host flag, leaving the real owner editable.
                val requestedReadOnly = readonly.value
                androidx.compose.runtime.SideEffect { state.readOnly = requestedReadOnly; renderedOwner = state }
                if (visible.value) WritingParagraphEditor(state, reportError = { throw it })
            } } } }
            val field = compose.onNode(hasSetTextAction()); field.performClick()
            val retained = checkNotNull(field.fetchSemanticsNode().config[SemanticsActions.SetText].action)
            val before = a.save().export().toString()
            compose.runOnIdle { readonly.value = true }
            compose.waitForIdle()
            compose.runOnIdle {
                assertTrue("The real input owner must be revoked before invoking the retained callback", checkNotNull(renderedOwner).readOnly)
                retained(AnnotatedString("retained overwrite")); assertEquals(before, a.save().export().toString())
            }
            compose.runOnIdle { readonly.value = false }
            field.performClick()
            compose.runOnIdle { assertFalse("The current owner must be editable for the fresh positive callback", checkNotNull(renderedOwner).readOnly) }
            field.performTextInputSelection(TextRange(0)); field.performTextInput("X")
            compose.runOnIdle { assertEquals(listOf("XABMira"), texts(a)) }
        } finally {
            compose.runOnIdle { visible.value = false }; compose.waitForIdle()
            compose.runOnIdle { a.close() }
        }
    }

    @Test fun nativeEmptyTailUndoRedoKeepsOriginalRetainedHeadSelection() {
        lateinit var a: WritingSession
        val visible = mutableStateOf(true)
        val interceptor = PlatformTextInputInterceptor { request, _ ->
            val connection = request.createInputConnection(EditorInfo()); try { awaitCancellation() } finally { connection.closeConnection() }
        }
        compose.runOnUiThread { a = WritingSession.createV4("compose-shared-empty-tail", "a", "v4", seed()) }
        try {
            compose.setContent { InterceptPlatformTextInput(interceptor) { MaterialTheme { run {
                val state = rememberWritingParagraphEditorState(a, ::retainedDrafts, reportError = { throw it })
                if (visible.value) WritingParagraphEditor(state, reportError = { throw it })
            } } } }
            val original = compose.onNode(hasSetTextAction()); original.performClick(); original.performTextInputSelection(TextRange(6))
            compose.onNodeWithTag("writing-enter").performClick()
            compose.onNode(hasSetTextAction() and isFocused()).assertTextContains("")
            assertEquals("The returned empty tail must actually own native focus", "",
                compose.onNode(hasSetTextAction() and isFocused()).fetchSemanticsNode().config[SemanticsProperties.EditableText].text)
            assertEquals(TextRange(0), compose.onNode(hasSetTextAction() and isFocused()).fetchSemanticsNode().config[SemanticsProperties.TextSelectionRange])
            compose.runOnIdle { assertEquals(listOf("ABMira", ""), texts(a)) }
            compose.onNodeWithTag("writing-undo").performClick()
            compose.onNode(hasSetTextAction() and isFocused()).assertTextContains("ABMira")
            assertEquals(TextRange(6), compose.onNode(hasSetTextAction() and isFocused()).fetchSemanticsNode().config[SemanticsProperties.TextSelectionRange])
            compose.onNodeWithTag("writing-redo").performClick()
            compose.runOnIdle { assertEquals(listOf("ABMira", ""), texts(a)) }
            assertEquals(TextRange(0), compose.onNode(hasSetTextAction() and isFocused()).fetchSemanticsNode().config[SemanticsProperties.TextSelectionRange])
        } finally {
            compose.runOnIdle { visible.value = false }; compose.waitForIdle()
            compose.runOnIdle { a.close() }
        }
    }
}
