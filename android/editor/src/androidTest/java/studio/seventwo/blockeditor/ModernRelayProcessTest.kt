package studio.seventwo.blockeditor

import androidx.test.platform.app.InstrumentationRegistry
import kotlinx.coroutines.runBlocking
import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Assume.assumeTrue
import org.junit.Test
import java.io.File
import java.math.BigDecimal
import java.util.UUID

/** Opt-in phases driven by test-modern-android-relay.ts. Each instrumentation
 * invocation opens a separate native process; every expected document is static. */
class ModernRelayProcessTest {
    private fun normalized(value: Any?): Any? = when (value) {
        is JSONObject -> value.keys().asSequence().associateWith { normalized(value.get(it)) }
        is JSONArray -> (0 until value.length()).map { normalized(value.get(it)) }
        is Number -> BigDecimal(value.toString()).stripTrailingZeros()
        JSONObject.NULL -> null
        else -> value
    }
    @Test fun nativeHTTPProcessPhase() = runBlocking {
        val arguments = InstrumentationRegistry.getArguments()
        assumeTrue("Explicit local relay phase required", arguments.containsKey("modernRelayPhase"))
        val phase = checkNotNull(arguments.getString("modernRelayPhase")); require(phase in listOf("seed", "offline", "rejoin", "undo", "redo"))
        val runID = UUID.fromString(checkNotNull(arguments.getString("modernRelayRun"))).toString()
        val endpoint = checkNotNull(arguments.getString("modernRelayEndpoint"))
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        val original = InstrumentationRegistry.getInstrumentation().context.assets.open("columns-7000.json").use { JSONObject(it.bufferedReader().readText()) }
        val directory = File(context.filesDir, "modern-process-$runID").apply { mkdirs() }
        val store = ModernHostStore(File(directory, "pair.json"))
        val relay = ModernAndroidRelay.open(store, "st140-columns", "android-process-author", endpoint, "modern-process-service",
            arguments.getString("modernRelayToken") ?: "")
        val session = relay.host.session
        fun applied(result: ModernResult) { assertEquals(ModernResultStatus.APPLIED, result.status) }
        try {
            when (phase) {
                "seed" -> {
                    assertEquals(0, relay.pendingChanges)
                    applied(session.execute(ModernCommand.ReplaceText(session.captureTextRange(session.field(session.node("E")), 0, 0), "Own ")))
                    relay.host.save(); assertEquals(1, relay.pendingChanges)
                }
                "offline" -> {
                    assertFalse(relay.connected); assertEquals(1, relay.pendingChanges)
                    applied(session.execute(ModernCommand.ReplaceTitle(session.captureTextRange(ModernField(ModernNodeID.document("st140-columns"), "title"), 0, 0), "Offline ")))
                    relay.host.save(); assertEquals(2, relay.pendingChanges)
                }
                "rejoin" -> { assertEquals(2, relay.pendingChanges); relay.exchange(); assertEquals(0, relay.pendingChanges); assertTrue(relay.peers.isEmpty()) }
                "undo" -> { applied(session.execute(ModernCommand.Undo)); applied(session.execute(ModernCommand.Undo)); relay.host.save(); assertEquals(2, relay.pendingChanges) }
                "redo" -> {
                    applied(session.execute(ModernCommand.Redo)); applied(session.execute(ModernCommand.Redo))
                    relay.host.save(); relay.exchange(); assertEquals(0, relay.pendingChanges)
                }
            }
            val expected = JSONObject(original.toString())
            if (phase != "undo") expected.getJSONArray("blocks").getJSONObject(1).getJSONArray("content").getJSONObject(0).put("text", "Own Outside layout")
            if (phase in listOf("offline", "rejoin", "redo")) expected.put("title", "Offline Field notes")
            if (phase in listOf("rejoin", "undo", "redo")) {
                expected.getJSONObject("appearance").put("fontFamily", "serif")
                expected.getJSONArray("blocks").getJSONObject(0).put("splitBasisPoints", 3000)
            }
            assertEquals(normalized(expected), normalized(session.snapshot.document.export()))
            val pair = checkNotNull(store.load()); assertFalse(pair.toString().contains("modern-relay-test"))
            val report = JSONObject().put("passed", true).put("phase", phase).put("runID", runID).put("pid", android.os.Process.myPid())
                .put("packageName", context.packageName).put("document", session.snapshot.document.export()).put("pending", relay.pendingChanges)
                .put("receipt", relay.receipt.export()).put("api", android.os.Build.VERSION.SDK_INT).put("abi", android.os.Build.SUPPORTED_ABIS[0])
            File(context.filesDir, "modern-process-$runID-$phase.json").writeText(report.toString())
        } finally { relay.close(); session.close() }
    }
}
