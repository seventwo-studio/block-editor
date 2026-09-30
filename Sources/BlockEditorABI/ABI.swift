import BlockEditorCore
import Foundation

// The host must serialize calls to this ABI. Browser JS and the Kotlin wrapper do so.
nonisolated(unsafe) private let bridge = EditorBridge()

@_cdecl("block_editor_alloc")
public func blockEditorAlloc(_ count: Int32) -> UnsafeMutablePointer<UInt8>? {
    guard count > 0, count <= 64_000_001 else { return nil }
    return .allocate(capacity: Int(count))
}

@_cdecl("block_editor_free")
public func blockEditorFree(_ pointer: UnsafeMutablePointer<UInt8>?) { pointer?.deallocate() }

/// UTF-8 JSON in, NUL-terminated UTF-8 JSON out. Caller frees both buffers.
@_cdecl("block_editor_call")
public func blockEditorCall(_ pointer: UnsafePointer<UInt8>?, _ length: Int32) -> UnsafeMutablePointer<UInt8>? {
    guard let pointer, length >= 0, length <= 64_000_000 else { return nil }
    let result = bridge.call(Data(bytes: pointer, count: Int(length)))
    let output = UnsafeMutablePointer<UInt8>.allocate(capacity: result.count + 1)
    result.copyBytes(to: output, count: result.count); output[result.count] = 0
    return output
}

/// Keeps C exports reachable from the WASM executable.
public func initializeBridge() { _ = bridge }
