import BlockEditorCore
import Foundation

// Local demo process boundary. Stdout contains exactly one JSON response per line.
// A single bridge serializes every request; no engine state is shared concurrently.
let bridge = EditorBridge()
while let line = readLine() {
    let response = bridge.call(Data(line.utf8))
    print(String(decoding: response, as: UTF8.self))
    fflush(stdout)
}
