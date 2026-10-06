import Foundation

public struct ModernCodeTarget: Codable, Equatable, Sendable {
    public let documentID: String
    public let epoch: String
    public let node: NodeID
    public let observed: [ChangeID]
}
public struct ModernCodeProperties: Codable, Equatable, Sendable {
    public let target: ModernCodeTarget
    public let language: String?
}
public enum ModernCodeLanguages {
    public static let supported = ["swift", "kotlin", "javascript", "typescript", "python", "json", "html", "css", "sql", "shell"]
}
func validateModernCodeProperties(_ edit: ModernCodeProperties, change: ChangeID) throws {
    try modernStructuralIdentityShape(edit.target.node)
    try validateObservedFrontier(edit.target.observed, before: change)
    guard edit.language == nil || ModernCodeLanguages.supported.contains(edit.language!) else { throw EditorError.invalidChange }
}
func validateModernCodeTarget(_ target: ModernCodeTarget, in shape: StructuralState) throws {
    _ = try shape.address(of: target.node)
    guard shape.nodes[target.node]?.fields["type"] == .string("code") else { throw EditorError.invalidPath }
}
func applyModernCodeProperties(_ edit: ModernCodeProperties, enabled: Bool, raw: inout Materialized) throws {
    guard raw.structure!.nodes[edit.target.node] != nil else { throw EditorError.invalidChange }
    if enabled { raw.structure!.nodes[edit.target.node]!.fields["language"] = edit.language.map(JSONValue.string); raw.structure!.touched.insert(edit.target.node) }
}
extension ModernSession {
    public func captureCodeTarget(_ node: NodeID) throws -> ModernCodeTarget {
        let target = ModernCodeTarget(documentID: documentID, epoch: epoch, node: node, observed: modernObserved)
        try validateModernCodeTarget(target, in: structure); return target
    }
    public func codeProperties(_ target: ModernCodeTarget, language: String?) throws -> ModernStructuralResult {
        try authoringAllowed(command: "codeProperties"); try validateTargetScope(target.documentID, target.epoch)
        let edit = ModernCodeProperties(target: target, language: language), id = try nextID()
        try validateModernCodeProperties(edit, change: id)
        try validateModernCodeTarget(target, in: modernCapturedStructure(target.observed)); try validateModernCodeTarget(target, in: structure)
        let field = try self.field(node: target.node, name: "code"), caret = try position(in: field, offset: 0)
        let outcome = ModernStructuralResult(focus: .text(caret), selection: .text(WritingTextRange(start: caret, end: caret)))
        if structure.nodes[target.node]?.fields["language"] == language.map(JSONValue.string) { return outcome }
        endTypingGroup(); return try performReturning(id, [.codeProperties(edit)]) { _, _ in outcome }
    }
}
