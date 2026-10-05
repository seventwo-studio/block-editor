import Foundation

public enum ModernAsyncKind: String, Codable, Sendable { case image, file, embed }
public struct ModernAsyncOrigin: Codable, Equatable, Sendable {
    public let node: NodeID
    public let kind: ModernAsyncKind
    public let source: String
    public let observed: [ChangeID]
}
/// Request identity/generation are local invocation state, never shared content.
public struct ModernAsyncTarget: Codable, Equatable, Sendable {
    public let documentID: String
    public let epoch: String
    public let requestID: String
    public let generation: UInt64
    public let origin: ModernAsyncOrigin
}
public enum ModernAsyncStatus: String, Codable, Sendable { case pending, retained, failed, cancelled, applied }
public struct ModernAsyncRecord: Codable, Equatable, Sendable {
    public let target: ModernAsyncTarget
    public var status: ModernAsyncStatus
    public var result: [String: JSONValue]?
    public var reason: String?
    public var receipt: [ChangeID]?
}
public struct ModernAsyncOutcome: Codable, Equatable, Sendable {
    public let status: String
    public let reason: String?
    public let retainedResult: [String: JSONValue]?
}
struct ModernAsyncArchive: Codable {
    let version: Int
    let documentID: String
    let epoch: String
    let generation: UInt64
    let requests: [ModernAsyncRecord]
}
/// A shared metadata edit has a causal source proof, without local request data.
public struct ModernAsyncMetadataEdit: Codable, Equatable, Sendable {
    public let origin: ModernAsyncOrigin
    public let metadata: [String: JSONValue]
}

private func modernAsyncSourceField(_ kind: ModernAsyncKind) -> String { kind == .embed ? "url" : "src" }
func validateModernAsyncMetadata(_ metadata: [String: JSONValue], kind: ModernAsyncKind) throws {
    try inspectModernPayload(.object(metadata))
    let fields: Set<String>
    var sample: [String: JSONValue] = ["id": .string("validation"), "type": .string(kind.rawValue)]
    switch kind {
    case .image:
        fields = ["src", "alt", "width", "height"]
        sample["src"] = .string("asset://validation/image")
    case .file:
        fields = ["src", "name", "mimeType", "size"]
        sample["src"] = .string("asset://validation/file"); sample["name"] = .string("file")
    case .embed:
        fields = ["title", "description", "thumbnail"]
        sample["url"] = .string("https://example.org")
    }
    guard !metadata.isEmpty, Set(metadata.keys).isSubset(of: fields) else { throw EditorError.invalidChange }
    for (field, value) in metadata {
        if let text = value.string { guard text.utf16.count <= 100_000 else { throw EditorError.invalidChange } }
        if value == .null { sample.removeValue(forKey: field) } else { sample[field] = value }
    }
    do { try Validation.block(Block(fields: sample), modern: true) } catch { throw EditorError.invalidChange }
}
func validateModernAsyncOrigin(_ origin: ModernAsyncOrigin, in structure: StructuralState) throws {
    _ = try structure.address(of: origin.node)
    guard let node = structure.nodes[origin.node], node.kind == .block,
          node.fields["type"] == .string(origin.kind.rawValue),
          node.fields[modernAsyncSourceField(origin.kind)] == .string(origin.source) else { throw EditorError.invalidPath }
}
func validateModernAsyncShape(_ edit: ModernAsyncMetadataEdit, change: ChangeID) throws {
    try modernStructuralIdentityShape(edit.origin.node)
    guard !edit.origin.source.isEmpty, edit.origin.source.utf16.count <= 100_000 else { throw EditorError.invalidChange }
    try validateObservedFrontier(edit.origin.observed, before: change)
    try validateModernAsyncMetadata(edit.metadata, kind: edit.origin.kind)
}
func validateModernAsyncEdit(_ edit: ModernAsyncMetadataEdit, captured: StructuralState, authored: StructuralState) throws {
    try validateModernAsyncOrigin(edit.origin, in: captured)
    try validateModernAsyncOrigin(edit.origin, in: authored)
    var fields = authored.nodes[edit.origin.node]!.fields
    for (field, value) in edit.metadata {
        if value == .null { fields.removeValue(forKey: field) } else { fields[field] = value }
    }
    do { try Validation.block(Block(fields: fields), modern: true) } catch { throw EditorError.invalidChange }
}
func applyModernAsyncMetadata(_ edit: ModernAsyncMetadataEdit, enabled: Bool, raw: inout Materialized) throws {
    guard raw.structure!.nodes[edit.origin.node] != nil else { throw EditorError.invalidChange }
    if enabled {
        for (field, value) in edit.metadata {
            if value == .null { raw.structure!.nodes[edit.origin.node]!.fields.removeValue(forKey: field) }
            else { raw.structure!.nodes[edit.origin.node]!.fields[field] = value }
        }
        raw.structure!.touched.insert(edit.origin.node)
    }
}

extension ModernSession {
    public var asyncRequests: [ModernAsyncRecord] { modernAsyncRequests.values.sorted { $0.target.generation < $1.target.generation } }

    public func beginAsyncBlock(_ node: NodeID, requestID: String) throws -> ModernAsyncTarget {
        try authoringAllowed(command: "completeAsyncBlock")
        guard validToken(requestID), modernAsyncRequests[requestID] == nil, modernAsyncRequests.count < 64,
              modernAsyncGeneration < 9_007_199_254_740_991 else { throw EditorError.invalidChange }
        _ = try structure.address(of: node)
        guard let value = structure.nodes[node], value.kind == .block,
              let kind = ModernAsyncKind(rawValue: value.fields["type"]?.string ?? ""),
              let source = value.fields[modernAsyncSourceField(kind)]?.string, !source.isEmpty, source.utf16.count <= 100_000 else { throw EditorError.invalidPath }
        let origin = ModernAsyncOrigin(node: node, kind: kind, source: source, observed: modernObserved)
        let target = ModernAsyncTarget(documentID: documentID, epoch: epoch, requestID: requestID,
            generation: modernAsyncGeneration + 1, origin: origin)
        var requests = modernAsyncRequests
        for (id, var record) in requests where record.target.origin.node == node && [ModernAsyncStatus.pending, .retained, .failed].contains(record.status) {
            record.status = .cancelled; record.reason = "superseded"; requests[id] = record
        }
        requests[requestID] = ModernAsyncRecord(target: target, status: .pending)
        _ = try checkedModernAsyncArchive(requests, generation: target.generation)
        modernAsyncGeneration = target.generation; modernAsyncRequests = requests
        return target
    }
    public func cancelAsyncBlock(_ target: ModernAsyncTarget) throws {
        guard var record = modernAsyncRequests[target.requestID], record.target == target else { throw EditorError.invalidChange }
        if record.status != .applied {
            record.status = .cancelled; record.reason = record.reason ?? "cancelled"
            var proposed = modernAsyncRequests; proposed[target.requestID] = record
            _ = try checkedModernAsyncArchive(proposed, generation: modernAsyncGeneration)
            modernAsyncRequests = proposed
        }
    }
    public func failAsyncBlock(_ target: ModernAsyncTarget, reason: String) throws {
        guard reason.utf16.count <= 1000, var record = modernAsyncRequests[target.requestID], record.target == target,
              [ModernAsyncStatus.pending, .retained].contains(record.status) else { throw EditorError.invalidChange }
        record.status = .failed; record.reason = reason
        var proposed = modernAsyncRequests; proposed[target.requestID] = record
        _ = try checkedModernAsyncArchive(proposed, generation: modernAsyncGeneration)
        modernAsyncRequests = proposed
    }
    public func forgetAsyncBlock(_ target: ModernAsyncTarget) throws {
        guard let record = modernAsyncRequests[target.requestID], record.target == target, record.status != .pending else { throw EditorError.invalidChange }
        modernAsyncRequests.removeValue(forKey: target.requestID)
    }
    public func completeAsyncBlock(_ target: ModernAsyncTarget, metadata: [String: JSONValue]) throws -> ModernAsyncOutcome {
        try validateModernAsyncMetadata(metadata, kind: target.origin.kind)
        func unavailable(_ reason: String, retain: Bool = true) -> ModernAsyncOutcome {
            if retain, var record = modernAsyncRequests[target.requestID], record.target == target, record.status != .applied {
                record.result = metadata
                if record.status == .pending || record.status == .retained { record.status = .retained; record.reason = reason }
                var proposed = modernAsyncRequests; proposed[target.requestID] = record
                guard (try? checkedModernAsyncArchive(proposed, generation: modernAsyncGeneration)) != nil else {
                    return ModernAsyncOutcome(status: "unavailable", reason: "asyncResultStorageFull", retainedResult: metadata)
                }
                modernAsyncRequests = proposed
            }
            return ModernAsyncOutcome(status: "unavailable", reason: reason, retainedResult: metadata)
        }
        guard target.documentID == documentID, target.epoch == epoch else { return unavailable("asyncOriginScopeChanged", retain: false) }
        guard let record = modernAsyncRequests[target.requestID], record.target == target else { return unavailable("asyncInvocationChanged", retain: false) }
        if record.status == .applied {
            if record.result == metadata { return ModernAsyncOutcome(status: "noop", reason: nil, retainedResult: nil) }
            return unavailable("asyncAlreadyApplied", retain: false)
        }
        guard record.status == .pending || record.status == .retained else { return unavailable("asyncCancelledOrFailed") }
        do { try authoringAllowed(command: "completeAsyncBlock") }
        catch ModernSessionError.compositionActive { return unavailable("compositionActive") }
        catch ModernSessionError.unavailable(let reason) { return unavailable(reason) }
        catch ModernSessionError.recoveryRequired { return unavailable("pendingRecovery") }
        let edit = ModernAsyncMetadataEdit(origin: target.origin, metadata: metadata)
        do {
            try validateModernAsyncEdit(edit, captured: modernCapturedStructure(target.origin.observed), authored: structure)
        } catch { return unavailable("asyncTargetChanged") }
        let changed = metadata.contains { key, value in structure.nodes[target.origin.node]!.fields[key] != (value == .null ? nil : value) }
        let id = changed ? try nextID() : nil
        var applied = record; applied.status = .applied; applied.result = metadata; applied.reason = nil
        applied.receipt = id.map { next in (modernObserved.filter { $0.actor != next.actor } + [next]).sorted() } ?? modernObserved
        var proposed = modernAsyncRequests; proposed[target.requestID] = applied
        guard (try? checkedModernAsyncArchive(proposed, generation: modernAsyncGeneration)) != nil else {
            return unavailable("asyncResultStorageFull", retain: false)
        }
        if let id {
            try validateModernAsyncShape(edit, change: id); endTypingGroup()
            do { try performReturning(id, [.completeAsyncMetadata(edit)]) { _, _ in () } }
            catch ModernSessionError.recoveryRequired { return unavailable("pendingRecovery") }
            catch let error as EditorError {
                if case .invalidDocument = error { return unavailable("asyncMetadataConflict") }
                throw error
            }
        }
        // Publication callbacks may cancel/fail other local requests. Preserve
        // those lifecycle updates; the preflight reserve covers their growth.
        modernAsyncRequests[target.requestID] = applied
        return ModernAsyncOutcome(status: changed ? "applied" : "noop", reason: nil, retainedResult: nil)
    }

    /// Store this bounded local provider state beside accepted history. No
    /// network work or completion is restarted by export/import or document save.
    public func exportAsyncRequests() throws -> Data {
        try checkedModernAsyncArchive(modernAsyncRequests, generation: modernAsyncGeneration)
    }
    private func checkedModernAsyncArchive(_ requests: [String: ModernAsyncRecord], generation: UInt64) throws -> Data {
        let archive = ModernAsyncArchive(version: 1, documentID: documentID, epoch: epoch,
            generation: generation, requests: requests.values.sorted { $0.target.generation < $1.target.generation })
        let data = try canonicalEncoder().encode(archive)
        // A pending invocation must still be cancellable or able to record a
        // 1,000-unit failure reason, including worst-case JSON escaping.
        let reserve = requests.values.filter { $0.status == .pending || $0.status == .retained }.count * 6200
        guard data.count <= 16_000_000 - reserve else { throw EditorError.recoveryCapacityExceeded }
        return data
    }
    public func restoreAsyncRequests(_ data: Data) throws {
        guard data.count <= 16_000_000, modernAsyncRequests.isEmpty, modernAsyncGeneration == 0 else { throw EditorError.invalidChange }
        let wire = try modernWireValue(data), archive = try canonicalEncoder().encode(wire)
        let state = try JSONDecoder().decode(ModernAsyncArchive.self, from: archive)
        guard try modernWireValue(canonicalEncoder().encode(state)) == wire,
              state.version == 1, state.documentID == documentID, state.epoch == epoch,
              state.generation <= 9_007_199_254_740_991, state.requests.count <= 64,
              Set(state.requests.map { $0.target.requestID }).count == state.requests.count,
              Set(state.requests.map { $0.target.generation }).count == state.requests.count else { throw EditorError.invalidChange }
        var latest: [NodeID: UInt64] = [:]
        for record in state.requests { latest[record.target.origin.node] = max(latest[record.target.origin.node] ?? 0, record.target.generation) }
        for record in state.requests {
            let target = record.target
            guard target.documentID == documentID, target.epoch == epoch, validToken(target.requestID),
                  target.generation > 0, target.generation <= state.generation,
                  record.reason == nil || record.reason!.utf16.count <= 1000 else { throw EditorError.invalidChange }
            let change = ChangeID(counter: UInt64.max, actor: actorID)
            try modernStructuralIdentityShape(target.origin.node)
            try validateObservedFrontier(target.origin.observed, before: change)
            guard !target.origin.source.isEmpty, target.origin.source.utf16.count <= 100_000 else { throw EditorError.invalidChange }
            try validateModernAsyncOrigin(target.origin, in: modernCapturedStructure(target.origin.observed))
            if [ModernAsyncStatus.pending, .retained].contains(record.status) { guard latest[target.origin.node] == target.generation else { throw EditorError.invalidChange } }
            if let result = record.result { try validateModernAsyncMetadata(result, kind: target.origin.kind) }
            if [ModernAsyncStatus.applied, .retained].contains(record.status) { guard record.result != nil else { throw EditorError.invalidChange } }
            if record.status == .pending { guard record.result == nil, record.reason == nil, record.receipt == nil else { throw EditorError.invalidChange } }
            if record.status == .failed || record.status == .retained || record.status == .cancelled {
                guard record.reason != nil else { throw EditorError.invalidChange }
            }
            if record.status == .applied {
                guard record.reason == nil else { throw EditorError.invalidChange }
                guard let receipt = record.receipt, let result = record.result else { throw EditorError.invalidChange }
                try validateObservedFrontier(receipt, before: change)
                let admitted = try modernCapturedStructure(receipt)
                _ = try admitted.address(of: target.origin.node)
                guard admitted.nodes[target.origin.node]?.fields["type"] == .string(target.origin.kind.rawValue),
                      result.allSatisfy({ field, value in admitted.nodes[target.origin.node]!.fields[field] == (value == .null ? nil : value) }) else { throw EditorError.invalidChange }
            } else { guard record.receipt == nil else { throw EditorError.invalidChange } }
        }
        let requests = Dictionary(uniqueKeysWithValues: state.requests.map { ($0.target.requestID, $0) })
        _ = try checkedModernAsyncArchive(requests, generation: state.generation)
        modernAsyncGeneration = state.generation; modernAsyncRequests = requests
    }
}
