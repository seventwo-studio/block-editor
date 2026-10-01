import BlockEditorCore
import Foundation

// Local demo process boundary. Stdout contains exactly one JSON response per line.
// A single bridge serializes every request; no engine state is shared concurrently.
let bridge = EditorBridge()
while let line = readLine() {
    let response = bridge.call(Data(line.utf8))
    FileHandle.standardOutput.write(response + Data([0x0a]))
}
