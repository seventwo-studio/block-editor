package studio.seventwo.blockeditor

import androidx.test.platform.app.InstrumentationRegistry
import kotlinx.coroutines.runBlocking
import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test
import java.io.File
import java.math.BigDecimal
import java.util.UUID

/** Actual Swift/JNI and app-private paired storage; HTTP failures are injected.
 * These cases do not substitute for physical input/assistive acceptance. */
class ModernRelayHostTest {
    private val endpoint = "http://127.0.0.1:4319/rooms/st140-columns"
    private fun original(): JSONObject = InstrumentationRegistry.getInstrumentation().context.assets.open("columns-7000.json").use { JSONObject(it.bufferedReader().readText()) }
    private fun directory() = File(InstrumentationRegistry.getInstrumentation().targetContext.cacheDir, "modern-relay-${UUID.randomUUID()}").apply { check(mkdirs()) }
    private fun session(actor: String) = ModernSession.create(ModernDocument.restore(original()), actor, "epoch")
    private fun applied(result: ModernResult) { assertEquals(ModernResultStatus.APPLIED, result.status) }
    private fun own(session: ModernSession, text: String = "Own ") = applied(session.execute(ModernCommand.ReplaceText(session.captureTextRange(session.field(session.node("E")), 0, 0), text)))
    private fun peer(session: ModernSession) {
        applied(session.execute(ModernCommand.Appearance.FontFamily("st140-columns", ModernFontFamily.SERIF)))
        applied(session.execute(ModernCommand.ResizeColumns(ModernColumnTarget(session.node("layout")), 3000)))
    }
    private fun normalized(value: Any?): Any? = when (value) {
        is JSONObject -> value.keys().asSequence().associateWith { normalized(value.get(it)) }
        is JSONArray -> (0 until value.length()).map { normalized(value.get(it)) }
        is Number -> if (value is Double && value == 0.0 && value.toRawBits() < 0) "negative-zero-number" else BigDecimal(value.toString()).stripTrailingZeros()
        JSONObject.NULL -> null
        else -> value
    }
    private fun expected(own: Boolean, peer: Boolean): JSONObject = original().also { document ->
        if (own) document.getJSONArray("blocks").getJSONObject(1).getJSONArray("content").getJSONObject(0).put("text", "Own Outside layout")
        if (peer) {
            document.getJSONObject("appearance").put("fontFamily", "serif")
            document.getJSONArray("blocks").getJSONObject(0).put("splitBasisPoints", 3000)
        }
    }
    private fun document(expected: JSONObject, session: ModernSession) { assertEquals(normalized(expected), normalized(session.snapshot.document.export())) }
    private fun reply(server: ModernSession, request: ModernRelayRequest): ModernRelayResponse {
        val body = NativeJsonTransport.decode(checkNotNull(request.body), strict = true)
        server.receive(ModernBatch.restore(body.getJSONObject("batch")))
        return ModernRelayResponse(200, NativeJsonTransport.encode(modernObject("batch" to server.changes(), "state" to server.snapshot.syncState,
            "presence" to JSONArray().put(modernObject("actor" to "peer", "revision" to 1)))))
    }

    @Test fun ordinaryReopenReceivesPeersWithoutResumeAndReadOnlyDoesNotSuppressSynchronization() = runBlocking {
        val root = directory(); val store = ModernHostStore(File(root, "pair.json")); val a = session("a"); val b = session("b"); var reopened: ModernAndroidHost? = null
        try {
            own(a); val host = ModernAndroidHost(a, "a", store); host.save()
            val pair = checkNotNull(store.load()); assertFalse(pair.has("relay"))
            val restored = ModernAndroidHost.restore(pair, store); reopened = restored.first
            peer(b); reopened.session.receive(b.changes()); document(expected(true, true), reopened.session)
            assertEquals(0, reopened.session.deferredChanges().size)
            applied(reopened.session.execute(ModernCommand.Undo)); document(expected(false, true), reopened.session)
            applied(reopened.session.execute(ModernCommand.Redo)); restored.second(); restored.second()
            reopened.readOnly = true; var requested = false
            val relay = ModernAndroidRelay(reopened, endpoint, "room", "test-only") { request -> requested = true; reply(b, request) }
            relay.exchange(); assertTrue(requested); assertEquals(0, relay.pendingChanges); relay.close()
        } finally { reopened?.session?.close(); a.close(); b.close(); root.deleteRecursively() }
    }

    @Test fun failedAcknowledgmentSaveKeepsReceiptPendingAndReopenRetainsPeerUndo() = runBlocking {
        val root = directory(); val parked = File(root.path + "-parked"); val store = ModernHostStore(File(root, "pair.json"))
        val a = session("a"); val b = session("b"); val server = session("server"); var reopened: ModernAndroidRelay? = null
        try {
            own(a); peer(b); server.receive(b.changes()); val host = ModernAndroidHost(a, "a", store); var fail = true
            val relay = ModernAndroidRelay(host, endpoint, "room", "test-only") { request ->
                val response = reply(server, request)
                if (fail) { check(root.renameTo(parked)); fail = false }; response
            }
            try { relay.exchange(); fail("Expected failed ACK persistence") } catch (_: Exception) { }
            assertEquals(0, relay.receipt.received.size); assertEquals(3, relay.pendingChanges); document(expected(true, true), a)
            check(parked.renameTo(root)); relay.exchange(); assertEquals(0, relay.pendingChanges); assertEquals(3, server.snapshot.syncState.received.size)
            val saved = checkNotNull(store.load()); assertEquals(normalized(relay.receipt.export()), normalized(saved.getJSONObject("relay").getJSONObject("receipt")))
            assertFalse(saved.toString().contains("test-only")); relay.close()
            var requests = 0
            reopened = ModernAndroidRelay.open(store, "st140-columns", "a", endpoint, "room", "", transport = { requests++; error("Offline reopen must not request") })
            assertEquals(0, requests); assertFalse(reopened.connected); assertEquals(0, reopened.pendingChanges)
            applied(reopened.host.session.execute(ModernCommand.Undo)); document(expected(false, true), reopened.host.session)
            applied(reopened.host.session.execute(ModernCommand.Redo)); document(expected(true, true), reopened.host.session)
        } finally { reopened?.close(); reopened?.host?.session?.close(); a.close(); b.close(); server.close(); root.deleteRecursively(); parked.deleteRecursively() }
    }

    @Test fun inputDuringTransmissionRemainsPendingAndReceiptsReopenWithValidExponentNumbers() = runBlocking {
        val root = directory(); val store = ModernHostStore(File(root, "pair.json")); val a = session("a"); val server = session("server")
        try {
            own(a); var first = true
            val relay = ModernAndroidRelay(ModernAndroidHost(a, "a", store), endpoint, "room", "test-only") { request ->
                if (first) { applied(a.execute(ModernCommand.ReplaceTitle(a.captureTextRange(ModernField(ModernNodeID.document("st140-columns"), "title"), 0, 0), "Later "))); first = false }
                val response = reply(server, request)
                ModernRelayResponse(response.status, response.bytes.toString(Charsets.UTF_8).replace("\"counter\":1", "\"counter\":1e0").toByteArray())
            }
            relay.exchange(); assertEquals("Field notes", server.snapshot.document.title); assertEquals(1, relay.pendingChanges)
            relay.exchange(); assertEquals(0, relay.pendingChanges); assertEquals("Later Field notes", server.snapshot.document.title)
            val restored = ModernAndroidHost.restore(checkNotNull(store.load()), store)
            try { document(a.snapshot.document.export(), restored.first.session) } finally { restored.first.session.close() }
            relay.close()
        } finally { a.close(); server.close(); root.deleteRecursively() }
    }

    @Test fun originalHostAndCredentialABAIgnoreOlderResponse() = runBlocking {
        val root = directory(); val a = session("a"); val b = session("b"); val server = session("server")
        try {
            peer(b); server.receive(b.changes()); val host = ModernAndroidHost(a, "a", ModernHostStore(File(root, "pair.json")))
            var mode = 0; lateinit var relay: ModernAndroidRelay
            relay = ModernAndroidRelay(host, endpoint, "room", "test-only") { request ->
                if (mode == 0) { host.setActive(false); host.setActive(true) } else { relay.setToken("second"); relay.setToken("test-only") }
                reply(server, request)
            }
            val originalSave = a.save().export().toString(); relay.exchange(); mode = 1; relay.exchange()
            assertEquals(originalSave, a.save().export().toString()); assertEquals(0, relay.receipt.received.size); assertTrue(relay.peers.isEmpty()); relay.close()
        } finally { a.close(); b.close(); server.close(); root.deleteRecursively() }
    }

    @Test fun rejectedRecoveryReopensAcceptedContentAndExplicitOwnRepairRetainsPeer() = runBlocking {
        val root = directory(); val store = ModernHostStore(File(root, "pair.json")); val a = session("a"); val b = session("b"); val server = session("server"); var reopened: ModernAndroidRelay? = null
        try {
            fun insert(session: ModernSession, text: String) = session.execute(ModernCommand.InsertBlock(session.captureBoundary(), ModernPayload.restore(JSONObject("""{"id":"collision","type":"paragraph","content":[{"type":"text","text":"$text"}]}""")))).also { applied(it) }
            val own = checkNotNull(insert(a, "Own").transaction); insert(b, "Peer"); server.receive(b.changes())
            val transport: ModernRelayTransport = { request ->
                try { reply(server, request) } catch (failure: ModernRecoveryException) {
                    ModernRelayResponse(409, NativeJsonTransport.encode(modernObject("error" to "modernRecoveryRequired", "recovery" to failure.recovery)))
                }
            }
            val relay = ModernAndroidRelay(ModernAndroidHost(a, "a", store), endpoint, "room", "test-only", transport)
            val before = a.save().export().toString()
            try { relay.exchange(); fail("Must retain rejected recovery") } catch (_: ModernRelayRetryException) { }
            assertEquals(before, a.save().export().toString()); assertEquals(0, relay.receipt.received.size)
            val saved = checkNotNull(store.load()); assertFalse(saved.isNull("recovery")); relay.close()
            reopened = ModernAndroidRelay.open(store, "st140-columns", "a", endpoint, "room", "test-only", transport = transport)
            reopened.host.session.repairUndo(listOf(own)); reopened.exchange(); assertEquals(0, reopened.pendingChanges)
            val expected = original()
            // Top-level insertion prepends without replacing either original block.
            expected.put("blocks", JSONArray().put(JSONObject("""{"id":"collision","type":"paragraph","content":[{"type":"text","text":"Peer"}]}""")).put(original().getJSONArray("blocks").get(0)).put(original().getJSONArray("blocks").get(1)))
            document(expected, reopened.host.session); document(expected, server)
        } finally { reopened?.close(); reopened?.host?.session?.close(); a.close(); b.close(); server.close(); root.deleteRecursively() }
    }

    @Test fun heldPeerAndOriginalNativeDraftRemainInertUntilExplicitResume() = runBlocking {
        val root = directory(); val store = ModernHostStore(File(root, "pair.json")); val a = session("a"); val b = session("b"); val server = session("server"); var reopened: ModernAndroidRelay? = null
        try {
            own(a); val host = ModernAndroidHost(a, "a", store); val release = a.holdRemoteChanges(); a.setComposing(true)
            val range = a.captureTextRange(a.field(a.node("E")), 4, 4)
            val draft = modernObject("id" to "saved-draft", "target" to range, "text" to "東京😀", "nativeText" to "東京😀", "start" to 4, "end" to 4, "reason" to "compositionActive")
            host.drafts = listOf(draft); peer(b); server.receive(b.changes())
            val relay = ModernAndroidRelay(host, endpoint, "room", "test-only") { reply(server, it) }
            relay.exchange(); assertEquals(0, relay.pendingChanges); document(expected(true, false), a); relay.close()
            reopened = ModernAndroidRelay.open(store, "st140-columns", "a", endpoint, "room", "", transport = { error("Restored inputs must stay local") })
            assertFalse(reopened.host.session.capabilities().export().getBoolean("isComposing")); assertEquals(normalized(draft), normalized(reopened.host.drafts.single()))
            document(expected(true, false), reopened.host.session); checkNotNull(reopened.resumeDeferred).invoke()
            document(expected(true, true), reopened.host.session); applied(reopened.host.session.execute(ModernCommand.Undo)); document(expected(false, true), reopened.host.session)
            a.setComposing(false); release()
        } finally { reopened?.close(); reopened?.host?.session?.close(); a.close(); b.close(); server.close(); root.deleteRecursively() }
    }

    @Test fun duplicateKeysRoundedNumbersForeignScopeAndUnknownReceiptsCannotPublish() = runBlocking {
        val root = directory(); val a = session("a"); val b = session("b"); val server = session("server")
        try {
            peer(b); server.receive(b.changes()); var mode = 0
            val host = ModernAndroidHost(a, "a", ModernHostStore(File(root, "pair.json")))
            val relay = ModernAndroidRelay(host, endpoint, "room", "test-only") { request ->
                val good = reply(server, request); var text = good.bytes.toString(Charsets.UTF_8)
                if (mode == 0) text = text.replace("\"batch\":", "\"batch\":{},\"batch\":")
                else if (mode == 1) text = text.replace("\"counter\":1", "\"counter\":1.0000000000000001")
                else {
                    val json = JSONObject(text); val state = json.getJSONObject("state")
                    if (mode == 2) state.put("epoch", "foreign") else state.put("received", JSONArray().put(modernObject("actor" to "unknown", "counter" to 1)))
                    text = json.toString()
                }
                ModernRelayResponse(200, text.toByteArray())
            }
            val before = a.save().export().toString()
            for (next in 0..3) { mode = next; try { relay.exchange(); fail("Malformed reply must fail mode $next") } catch (_: Exception) { }
                assertEquals(before, a.save().export().toString()); assertEquals(0, relay.receipt.received.size) }
            try { ModernAndroidRelay(host, endpoint, "room", "test-only"); fail("Duplicate client must fail") } catch (_: IllegalStateException) { }
            try { ModernAndroidRelay(host, "https://user:secret@example.com/room?token=secret", "room", ""); fail("Embedded credentials must fail") }
            catch (failure: IllegalArgumentException) { assertFalse(failure.toString().contains("secret")) }
            relay.close()
            val saved = host.checkpoint().put("unknownSidecar", "retain or reject")
            try { ModernAndroidHost.restore(saved, ModernHostStore(File(root, "other.json"))); fail("Unknown sidecar must not disappear") } catch (_: IllegalArgumentException) { }
        } finally { a.close(); b.close(); server.close(); root.deleteRecursively() }
    }

    @Test fun capacityFailureRetainsCompleteAcceptedHistoryForExportAndReopen() = runBlocking {
        val root = directory(); val store = ModernHostStore(File(root, "pair.json")); val a = session("a"); var reopened: ModernAndroidRelay? = null
        try {
            own(a, "世界😀".repeat(1000)); val host = ModernAndroidHost(a, "a", store)
            val relay = ModernAndroidRelay(host, endpoint, "room", "test-only") { ModernRelayResponse(413, """{"error":"transportCapacityExceeded","maxBytes":8000000}""".toByteArray()) }
            val original = a.save().export().toString()
            try { relay.exchange(); fail("Expected capacity rejection") } catch (failure: ModernRelayCapacityException) { assertEquals(8_000_000, failure.maxBytes) }
            assertEquals(original, a.save().export().toString()); assertEquals(1, relay.pendingChanges); assertEquals(0, relay.receipt.received.size)
            val export = host.checkpoint(); assertFalse(export.toString().contains("test-only")); relay.close()
            reopened = ModernAndroidRelay.open(store, "st140-columns", "a", endpoint, "room", "", transport = { error("Must reopen locally") })
            assertEquals(original, reopened.host.session.save().export().toString()); assertEquals(1, reopened.pendingChanges)
        } finally { reopened?.close(); reopened?.host?.session?.close(); a.close(); root.deleteRecursively() }
    }

    @Test fun originalUnpairedNativeBufferReopensExactlyAndMalformedPrivateFieldsFail() = runBlocking {
        val root = directory(); val store = ModernHostStore(File(root, "pair.json")); val a = session("a"); var reopened: ModernAndroidHost? = null
        try {
            val host = ModernAndroidHost(a, "a", store); a.setComposing(true)
            val range = a.captureTextRange(a.field(a.node("E")), 0, 0)
            host.drafts = listOf(modernObject("id" to "original", "target" to range, "text" to "\uD800", "nativeText" to "\uD800", "start" to 1, "end" to 1, "reason" to "compositionActive"))
            host.save(); val exported = host.exportCheckpoint(); assertTrue(exported.toString(Charsets.UTF_8).contains("\\ud800"))
            val pair = checkNotNull(store.load()); reopened = ModernAndroidHost.restore(pair, store).first
            assertEquals("\uD800", reopened.drafts.single().getString("nativeText")); assertEquals("\uD800", reopened.drafts.single().getString("text"))
            document(original(), reopened.session)
            for (name in listOf("text", "start")) {
                val bad = NativeJsonTransport.copy(pair); bad.getJSONArray("drafts").getJSONObject(0).put(name, if (name == "text") 5 else 0.5)
                try { ModernAndroidHost.restore(bad, store); fail("Invalid private field must not be coerced") } catch (_: Exception) { }
            }
            a.setComposing(false)
        } finally { reopened?.session?.close(); a.close(); root.deleteRecursively() }
    }
}
