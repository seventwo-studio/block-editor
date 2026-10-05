import Foundation

/// Persisted presets only. Viewport stacking, outline and focus mode are host state.
public struct ModernAppearance: Equatable, Sendable {
    public enum FontFamily: String, Sendable { case sans, serif, monospace }
    public enum FontSize: String, Sendable { case small, `default`, large }
    public enum PageWidth: String, Sendable { case readable, wide }
    public let fontFamily: FontFamily
    public let fontSize: FontSize
    public let pageWidth: PageWidth
    public init(fontFamily: FontFamily = .sans, fontSize: FontSize = .default, pageWidth: PageWidth = .readable) {
        self.fontFamily = fontFamily; self.fontSize = fontSize; self.pageWidth = pageWidth
    }
    public static let `default` = ModernAppearance()
    var jsonValue: JSONValue {
        .object(["fontFamily": .string(fontFamily.rawValue), "fontSize": .string(fontSize.rawValue), "pageWidth": .string(pageWidth.rawValue)])
    }
    init(_ value: JSONValue?) throws {
        guard let value, value.object != nil,
              let family = FontFamily(rawValue: value["fontFamily"]?.string ?? ""),
              let size = FontSize(rawValue: value["fontSize"]?.string ?? ""),
              let width = PageWidth(rawValue: value["pageWidth"]?.string ?? "") else {
            throw EditorError.invalidDocument("Invalid modern appearance")
        }
        self.init(fontFamily: family, fontSize: size, pageWidth: width)
    }
}

/// Immutable format-1 snapshot. This is not a protocol-7 session, migration,
/// authoring policy or archive activation; legacy entrypoints stay unchanged.
public struct ModernDocument: Encodable, Equatable, Sendable {
    public static let format = "seventwo.block-editor.document"
    public static let formatVersion = 1
    public let documentID: String
    public let title: String
    public let appearance: ModernAppearance
    public let blocks: [Block]
    /// Includes admitted unknown envelope, appearance, block and inline fields.
    public let fields: [String: JSONValue]

    public init(documentID: String, title: String = "", appearance: ModernAppearance = .default, blocks: [Block] = []) throws {
        try self.init(fields: ["format": .string(Self.format), "formatVersion": .number(Double(Self.formatVersion)),
                               "documentID": .string(documentID), "title": .string(title),
                               "appearance": appearance.jsonValue, "blocks": .array(blocks.map { .object($0.fields) })])
    }
    public init(fields: [String: JSONValue]) throws {
        guard fields["format"] == .string(Self.format), fields["formatVersion"] == .number(Double(Self.formatVersion)) else {
            throw EditorError.invalidDocument("Unsupported modern document format")
        }
        guard let identity = fields["documentID"]?.string, !identity.isEmpty,
              let title = fields["title"]?.string, !title.unicodeScalars.contains(where: { [10, 13, 0x2028, 0x2029].contains($0.value) }),
              let values = fields["blocks"]?.array, values.count <= 10_000 else {
            throw EditorError.invalidDocument("Invalid modern document identity, title or blocks")
        }
        let appearance = try ModernAppearance(fields["appearance"])
        try Self.inspect(.object(fields), maximumDepth: 104)
        for (key, value) in fields where key != "blocks" { try Self.inspect(value, maximumDepth: 100) }
        var ids = Set<String>()
        let blocks = try values.map { value -> Block in
            guard let fields = value.object else { throw EditorError.invalidDocument("Block must be an object") }
            let block = try Block(fields: fields)
            guard ids.insert(block.id).inserted else { throw EditorError.invalidDocument("Duplicate root block ID") }
            // Keep the legacy per-block depth bound, allowing for the new envelope.
            try Self.inspect(value, maximumDepth: 100)
            try Validation.block(block, modern: true)
            return block
        }
        guard try canonicalEncoder().encode(fields).count <= 32_000_000 else {
            throw EditorError.invalidDocument("Document exceeds 32 MB")
        }
        self.documentID = identity; self.title = title; self.appearance = appearance
        self.blocks = blocks; self.fields = fields
    }
    public init(json: Data) throws {
        guard json.count <= 32_000_000 else { throw EditorError.invalidDocument("Document exceeds 32 MB") }
        try inspectModernJSONKeys(json)
        guard let fields = try JSONDecoder().decode(JSONValue.self, from: json).object else {
            throw EditorError.invalidDocument("Modern document must be an object")
        }
        try self.init(fields: fields)
    }
    public func encode(to encoder: any Encoder) throws { try JSONValue.object(fields).encode(to: encoder) }
    public func json() throws -> Data { try canonicalEncoder().encode(fields) }

    private static func inspect(_ value: JSONValue, maximumDepth: Int) throws {
        var pending = [(value, 0)]
        while let (value, depth) = pending.popLast() {
            guard depth <= maximumDepth else { throw EditorError.invalidDocument("Document nesting exceeds limit") }
            if case .number(let number) = value, !number.isFinite { throw EditorError.invalidDocument("Nonfinite JSON number") }
            if let object = value.object { pending.append(contentsOf: object.values.map { ($0, depth + 1) }) }
            else if let array = value.array { pending.append(contentsOf: array.map { ($0, depth + 1) }) }
        }
    }
}

/// Foundation decoders collapse duplicate object keys. Check raw keys, including
/// escaped spellings, before decoding. JSONDecoder still owns syntax validation.
private func inspectModernJSONKeys(_ data: Data) throws {
    struct Frame { let object: Bool; var needsKey = true; var keys = Set<String>() }
    let bytes = Array(data)
    var frames: [Frame] = [], offset = 0
    while offset < bytes.count {
        switch bytes[offset] {
        case 123, 91: // { [
            guard frames.count < 104 else { throw EditorError.invalidDocument("Document nesting exceeds limit") }
            frames.append(Frame(object: bytes[offset] == 123)); offset += 1
        case 125, 93: // } ]
            guard let frame = frames.popLast(), frame.object == (bytes[offset] == 125) else { throw EditorError.invalidDocument("Invalid JSON container") }
            offset += 1
        case 44: // comma
            if let index = frames.indices.last, frames[index].object { frames[index].needsKey = true }
            offset += 1
        case 34: // string
            let start = offset
            offset += 1
            while offset < bytes.count && bytes[offset] != 34 {
                offset += bytes[offset] == 92 ? 2 : 1
            }
            guard offset < bytes.count else { throw EditorError.invalidDocument("Unterminated JSON string") }
            offset += 1
            if let index = frames.indices.last, frames[index].object, frames[index].needsKey {
                let key = try JSONDecoder().decode(String.self, from: Data(bytes[start..<offset]))
                guard frames[index].keys.insert(key).inserted else { throw EditorError.invalidDocument("Duplicate JSON object key \(key)") }
                frames[index].needsKey = false
            }
        case 45, 48...57: // number; retain the mathematical value of opaque metadata
            let start = offset
            while offset < bytes.count, ![9, 10, 13, 32, 44, 93, 125].contains(bytes[offset]) { offset += 1 }
            let literal = Data(bytes[start..<offset])
            let number = try JSONDecoder().decode(Double.self, from: literal)
            let encoded = try canonicalEncoder().encode(number)
            guard try modernNumberIdentity(literal) == modernNumberIdentity(encoded) else {
                throw EditorError.invalidDocument("JSON number cannot be preserved without rounding")
            }
        default: offset += 1
        }
    }
    guard frames.isEmpty else { throw EditorError.invalidDocument("Unclosed JSON container") }
}

/// Compare decimal values without a fixed-precision decimal or integer parser.
/// Syntax has already been checked by JSONDecoder for each numeric token.
private func modernNumberIdentity(_ data: Data) throws -> String {
    var value = String(decoding: data, as: UTF8.self).lowercased()
    let negative = value.hasPrefix("-")
    if negative { value.removeFirst() }
    let parts = value.split(separator: "e", omittingEmptySubsequences: false)
    let mantissa = String(parts[0])
    let fractionCount = mantissa.split(separator: ".", omittingEmptySubsequences: false).dropFirst().first?.count ?? 0
    let digits = mantissa.filter { $0 != "." }.drop(while: { $0 == "0" })
    if digits.isEmpty { return negative ? "-0" : "0" }
    guard let exponent = parts.count == 1 ? 0 : Int(parts[1]) else {
        throw EditorError.invalidDocument("JSON number exponent exceeds limit")
    }
    let (initialScale, overflow) = exponent.subtractingReportingOverflow(fractionCount)
    guard !overflow else { throw EditorError.invalidDocument("JSON number exponent exceeds limit") }
    let trailingZeroCount = digits.reversed().prefix(while: { $0 == "0" }).count
    let (scale, scaleOverflow) = initialScale.addingReportingOverflow(trailingZeroCount)
    guard !scaleOverflow else { throw EditorError.invalidDocument("JSON number exponent exceeds limit") }
    return "\(negative ? "-" : "")\(digits.dropLast(trailingZeroCount))e\(scale)"
}
