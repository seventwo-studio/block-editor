package studio.seventwo.blockeditor.demo

import androidx.test.platform.app.InstrumentationRegistry
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withContext
import org.junit.Assert.*
import org.junit.Test
import java.util.UUID

class RelayTest {
    @Test fun offlineClientsRejoinAndUndoKeepsRemoteText() = runBlocking {
        val args = InstrumentationRegistry.getArguments()
        val endpoint = (args.getString("relayUrl") ?: "http://10.0.2.2:4319") + "/rooms/android-${UUID.randomUUID()}"
        val token = args.getString("relayToken") ?: "relay-test"
        withContext(Dispatchers.Main) {
            val a = LocalRelayConnection.open(endpoint, token)
            val b = LocalRelayConnection.open(endpoint, token)
            try {
                a.connected = false; b.connected = false
                a.session.setText("p", "Alice offline 😀")
                b.session.setText("p", "Bob offline 世界")
                assertTrue(a.pending > 0); assertTrue(b.pending > 0)
                a.connected = true; b.connected = true
                a.exchange(); b.exchange(); a.exchange()
                assertEquals(a.session.snapshot.getJSONArray("blocks").toString(), b.session.snapshot.getJSONArray("blocks").toString())
                a.session.undo(); a.exchange(); b.exchange()
                val document = b.session.snapshot.getJSONArray("blocks").toString()
                assertTrue(document.contains("Bob offline")); assertFalse(document.contains("Alice offline"))
                assertEquals(0, a.pending); assertEquals(0, b.pending)
                assertEquals(1, a.peerCount); assertEquals(1, b.peerCount)
                a.connected = false
                assertEquals(0, a.peerCount)
                assertFalse(a.session.save().has("presence"))
            } finally { a.close(); b.close() }
        }
    }
}
