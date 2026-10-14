import Foundation

/// Inspect original bytes before a platform parser can discard duplicate keys,
/// round numbers or substitute Unicode. This never authors a document.
public enum ModernWireJSON {
    public static func inspect(_ data: Data) throws -> JSONValue { try modernWireValue(data) }
    public static func response(_ data: Data) -> Data {
        do { return try canonicalEncoder().encode(JSONValue.object(["ok": .bool(true), "value": try inspect(data)])) }
        catch { return (try? canonicalEncoder().encode(JSONValue.object(["ok": .bool(false), "error": .string(String(describing: error))]))) ?? Data() }
    }
}
