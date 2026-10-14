@testable import BlockEditorCore
import Foundation
import Testing

@Suite struct CanonicalJSONSizeTests {
    @Test func literalWireBoundariesIncludeEscapesUnicodeKeysAndNumbers() throws {
        let literalCases: [(JSONValue, Int)] = [
            (.null, 4), (.bool(true), 4), (.bool(false), 5),
            (.string(""), 2), (.string("a/"), 4),
            (.string("\"\\\n"), 8), (.string("\u{0000}"), 8),
            (.string("😀"), 6), (.string("e\u{0301}"), 5),
            (.array([.null, .bool(false)]), 12),
            (.object(["": .string("")]), 7)
        ]
        for (value, count) in literalCases {
            #expect(try canonicalEncoder().encode(value).count == count)
            #expect(try canonicalJSONSizeFits(value, limit: count))
            #expect(try !canonicalJSONSizeFits(value, limit: count - 1))
            #expect(try canonicalJSONSizeFits(value, limit: count * 20))
        }
        let values: [JSONValue] = [
            .object(["\"\\\u{0001}世界😀e\u{0301}": .array([.number(-0.0), .number(Double.leastNonzeroMagnitude), .number(Double.greatestFiniteMagnitude), .string("\u{2028}\u{2029}")])]),
            .number(9_007_199_254_740_991), .number(-12.34567890123456)
        ]
        for value in values {
            let exact = try canonicalEncoder().encode(value).count
            for limit in [0, exact - 1, exact, exact + 1, exact * 20] {
                #expect(try canonicalJSONSizeFits(value, limit: limit) == (exact <= limit))
            }
        }
        #expect(throws: (any Error).self) { try canonicalJSONSizeFits(.number(.infinity), limit: 32_000_000) }
        #expect(throws: (any Error).self) { try canonicalJSONSizeFits(.number(.nan), limit: 32_000_000) }
    }

    @Test func unchangedAcceptanceDocumentsHaveExactCapacityBoundaries() throws {
        let fixtures = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("docs/acceptance/modern-editor/documents")
        for url in try FileManager.default.contentsOfDirectory(at: fixtures, includingPropertiesForKeys: nil) where url.pathExtension == "json" {
            let value = try JSONDecoder().decode(JSONValue.self, from: Data(contentsOf: url))
            let exact = try canonicalEncoder().encode(value).count
            #expect(try !canonicalJSONSizeFits(value, limit: exact - 1))
            #expect(try canonicalJSONSizeFits(value, limit: exact))
            #expect(try canonicalJSONSizeFits(value, limit: 32_000_000))
        }
    }

    @Test func fullDocumentLimitRetainsLargeOpaqueFieldsAndRejectsOneMoreByte() throws {
        var fields = try ModernDocument(documentID: "capacity").fields
        fields["opaque"] = .string("")
        let overhead = try canonicalEncoder().encode(fields).count
        fields["opaque"] = .string(String(repeating: "x", count: 32_000_000 - overhead))
        #expect(try canonicalEncoder().encode(fields).count == 32_000_000)
        #expect(try ModernDocument(fields: fields).fields == fields)
        fields["opaque"] = .string(String(repeating: "x", count: 32_000_001 - overhead))
        #expect(throws: (any Error).self) { try ModernDocument(fields: fields) }
    }
}
