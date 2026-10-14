import BlockEditorCore
import Foundation
import Testing

@Suite struct ModernWireJSONTests {
    @Test func originalDuplicatesRoundingAndMalformedUnicodeCannotBeNormalizedIntoAdmission() throws {
        let malformed = [Data(#"{"a":1,"a":2}"#.utf8), Data(#"{"a":[{"x":1,"\u0078":2}]}"#.utf8),
            Data(#"{"counter":1.0000000000000001}"#.utf8), Data(#"{"value":18446744073709551616}"#.utf8),
            Data(#"{"text":"\ud800"}"#.utf8), Data([123, 34, 120, 34, 58, 34, 255, 34, 125])]
        for bytes in malformed {
            #expect(throws: (any Error).self) { try ModernWireJSON.inspect(bytes) }
            let response = try JSONDecoder().decode(JSONValue.self, from: ModernWireJSON.response(bytes))
            #expect(response["ok"] == .bool(false) && response["value"] == nil)
        }
        let inspected = try ModernWireJSON.inspect(Data(#"{"text":"東京😀","number":1e3,"zero":-0}"#.utf8))
        #expect(inspected["text"] == .string("東京😀") && inspected["number"] == .number(1000))
        guard case .number(let zero) = inspected["zero"] else { Issue.record("Missing signed zero"); return }
        #expect(zero == 0 && zero.sign == .minus)
    }
    @Test func fullRawByteBudgetIsAvailableWithoutAnEncodedRequestEnvelope() throws {
        let prefix = Data(#"{"opaque":""#.utf8), suffix = Data(#""}"#.utf8)
        let length = 64_000_000 - prefix.count - suffix.count
        var bytes = prefix; bytes.append(Data(repeating: 97, count: length)); bytes.append(suffix)
        #expect(bytes.count == 64_000_000)
        guard case .string(let text) = try ModernWireJSON.inspect(bytes)["opaque"] else { Issue.record("Raw string was not preserved"); return }
        #expect(text.utf8.count == length)
        bytes.append(32)
        #expect(throws: (any Error).self) { try ModernWireJSON.inspect(bytes) }
    }
}
