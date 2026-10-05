import Foundation

public enum ModernLegacyDocumentFormat: String, Codable, Sendable { case blockArray, documentObject }
/// Raw bytes remain archival data, including old author history and rejected input.
public enum ModernCutoverSource: Codable, Equatable, Sendable {
    case document(format: ModernLegacyDocumentFormat, bytes: Data)
    case session(acceptedSnapshot: Data, reconciledSnapshot: Data, pendingRecovery: Data?, unacknowledged: [Data])
}
public struct ModernCutoverArchive: Codable, Equatable, Sendable {
    public let version: Int
    public let documentID: String
    public let epoch: String
    public let source: ModernCutoverSource
    /// Original interchange documents, native drafts and other host-owned evidence.
    /// These bytes are retained without interpreting them as replicated history.
    public let originals: [Data]
    public init(documentID: String, epoch: String, source: ModernCutoverSource, originals: [Data] = []) {
        version = 1; self.documentID = documentID; self.epoch = epoch; self.source = source; self.originals = originals
    }
    public init(json: Data) throws {
        guard json.count <= 384_000_000 else { throw EditorError.recoveryCapacityExceeded }
        let wire = try modernCutoverArchiveWire(json)
        let value = try JSONDecoder().decode(Self.self, from: canonicalEncoder().encode(wire))
        guard try modernCutoverArchiveWire(canonicalEncoder().encode(value)) == wire else { throw EditorError.invalidChange }
        _ = try value.json(); self = value
    }
    public func json() throws -> Data {
        guard version == 1, !documentID.isEmpty, !epoch.isEmpty, epoch.utf8.count <= 10_000,
              originals.count <= 64, originals.reduce(0, { $0 + $1.count }) <= 64_000_000 else { throw EditorError.invalidChange }
        switch source {
        case .document(_, let bytes): guard bytes.count <= 32_000_000 else { throw EditorError.recoveryCapacityExceeded }
        case .session(let accepted, let reconciled, let pending, let packets):
            guard accepted.count <= 64_000_000, reconciled.count <= 64_000_000, packets.count <= 64,
                  (pending?.count ?? 0) + packets.reduce(0, { $0 + $1.count }) <= 64_000_000 else { throw EditorError.recoveryCapacityExceeded }
        }
        let bytes = try canonicalEncoder().encode(self)
        guard bytes.count <= 384_000_000 else { throw EditorError.recoveryCapacityExceeded }
        return bytes
    }
}
public enum ModernCutoverOrigin: Codable, Equatable, Sendable {
    /// Protocol 1 and standalone documents expose scoped paths, not v2 origins.
    case legacyPath(NodeAddress)
    case origin(NodeID)
}
public struct ModernCutoverIdentity: Codable, Equatable, Sendable {
    public let source: ModernCutoverOrigin
    public let address: NodeAddress
    public let target: NodeID
}
public enum ModernCutoverError: Error, Equatable, Sendable {
    case incompatibleRepresentation, unreconciledInput, archiveReadbackMismatch, acknowledgmentsRequired, sameEpoch
}

/// Read-only preparation; constructing a new session does not activate a host's
/// durable pointer. The host saves/readbacks the new session before activation.
public final class ModernCutoverPreparation {
    public let archive: ModernCutoverArchive
    public let archiveBytes: Data
    public let document: ModernDocument
    public let originMapping: [ModernCutoverIdentity]
    fileprivate let editor: EditorSession?
    fileprivate let writing: WritingSession?
    fileprivate init(archive: ModernCutoverArchive, bytes: Data, document: ModernDocument,
                     mapping: [ModernCutoverIdentity], editor: EditorSession?, writing: WritingSession?) {
        self.archive = archive; archiveBytes = bytes; self.document = document; originMapping = mapping; self.editor = editor; self.writing = writing
    }
    public func makeSession(actorID: String, archiveReadback: Data, oldWritersStopped: Bool,
                            archivePersisted: Bool, resetUndoAcknowledged: Bool) throws -> ModernSession {
        guard oldWritersStopped, archivePersisted, resetUndoAcknowledged else { throw ModernCutoverError.acknowledgmentsRequired }
        guard archiveReadback == archiveBytes else { throw ModernCutoverError.archiveReadbackMismatch }
        return try ModernSession(documentID: archive.documentID, actorID: actorID, epoch: archive.epoch, document: document)
    }
    /// Resolve in the reconciled old epoch, then allocate a new baseline anchor.
    /// A deleted/reused old origin cannot be remapped through its display label.
    public func remap(_ position: WritingPosition) throws -> WritingPosition {
        guard let writing else { throw EditorError.invalidChange }
        let resolved = try writing.resolve(position)
        guard let identity = resolved.address.identity, let name = resolved.address.path.last else { throw EditorError.invalidPath }
        return try mappedPosition(.origin(identity), name: name, offset: resolved.offset, affinity: position.affinity)
    }
    public func remap(_ position: TextPosition) throws -> WritingPosition {
        guard let editor else { throw EditorError.invalidChange }
        let offset = try editor.offset(of: position)
        let source: ModernCutoverOrigin
        if editor.collaborationVersion == 2 {
            guard let identity = position.address.identity else { throw EditorError.invalidPath }
            source = .origin(identity)
        } else {
            source = .legacyPath(NodeAddress(position.address.blockID, path: Array(position.address.path.dropLast())))
        }
        guard let name = position.address.path.last else { throw EditorError.invalidPath }
        return try mappedPosition(source, name: name, offset: offset, affinity: position.affinity)
    }
    private func mappedPosition(_ source: ModernCutoverOrigin, name: String, offset: Int, affinity: TextAffinity) throws -> WritingPosition {
        guard let mapping = originMapping.first(where: { $0.source == source }) else { throw EditorError.invalidPath }
        let preview = try ModernSession(documentID: archive.documentID, actorID: "cutover-position", epoch: archive.epoch, document: document)
        return try preview.position(in: WritingField(node: mapping.target, name: name), offset: offset, affinity: affinity)
    }
}

extension ProtocolMigration {
    public static func prepareModernCutover(_ archive: ModernCutoverArchive) throws -> ModernCutoverPreparation {
        let archiveBytes = try archive.json()
        let document: ModernDocument
        var editor: EditorSession?, writing: WritingSession?
        switch archive.source {
        case .document(let format, let bytes):
            let wire = try modernWireValue(bytes)
            let values: [JSONValue], envelope: [String: JSONValue]
            switch format {
            case .blockArray:
                guard let blocks = wire.array else { throw EditorError.invalidChange }; values = blocks; envelope = [:]
            case .documentObject:
                guard let fields = wire.object, let blocks = fields["blocks"]?.array else { throw EditorError.invalidChange }
                guard fields["format"] == nil, fields["formatVersion"] == nil,
                      fields["documentID"] == nil || fields["documentID"] == .string(archive.documentID) else { throw ModernCutoverError.incompatibleRepresentation }
                values = blocks; envelope = fields
            }
            try inspectModernLegacyCollisions(values)
            let old: Document
            do { old = try Document(blocks: values.map { try Block(fields: $0.object ?? [:]) }) }
            catch { throw ModernCutoverError.incompatibleRepresentation }
            var fields = envelope
            fields["format"] = .string(ModernDocument.format); fields["formatVersion"] = .number(1)
            fields["documentID"] = .string(archive.documentID); fields["blocks"] = .array(old.blocks.map { .object($0.fields) })
            if fields["title"] == nil { fields["title"] = .string("") }
            if fields["appearance"] == nil { fields["appearance"] = ModernAppearance.default.jsonValue }
            do { document = try ModernDocument(fields: fields) } catch { throw ModernCutoverError.incompatibleRepresentation }
        case .session(let accepted, let reconciled, let pending, let packets):
            let first = try modernCutoverSnapshot(accepted), last = try modernCutoverSnapshot(reconciled)
            guard first["documentID"] == .string(archive.documentID), first["version"] == last["version"],
                  first["documentID"] == last["documentID"], first["baseline"] == last["baseline"], first["epoch"] == last["epoch"] else { throw EditorError.differentDocument }
            let version = try modernLegacyVersion(first)
            if let oldEpoch = first["epoch"]?.string, oldEpoch == archive.epoch { throw ModernCutoverError.sameEpoch }
            func actor(_ wire: JSONValue) -> String { wire["localHistory"]?["actorID"]?.string ?? "cutover-review" }
            let old: Document
            if version <= 2 {
                _ = try EditorSession.restore(accepted, actorID: actor(first))
                let restored = try EditorSession.restore(reconciled, actorID: actor(last)); editor = restored
                let final = restored.changes()
                var inputs = packets
                if let pending { inputs.append(try modernCutoverRecovery(pending)) }
                inputs.append(accepted); inputs.append(reconciled)
                for bytes in inputs {
                    let wire = try modernCutoverSnapshot(bytes), batch = try JSONDecoder().decode(ChangeBatch.self, from: canonicalEncoder().encode(wire))
                    guard batch.documentID == archive.documentID, batch.version == version, batch.baseline == final.baseline else { throw EditorError.differentDocument }
                    try modernCutoverContains(batch.changes, in: final.changes, id: { $0.id })
                }
                old = try restored.document
            } else {
                _ = try WritingSession.restore(accepted, actorID: actor(first))
                let restored = try WritingSession.restore(reconciled, actorID: actor(last)); writing = restored
                let final = restored.changes()
                var inputs = packets
                if let pending { inputs.append(try modernCutoverRecovery(pending)) }
                inputs.append(accepted); inputs.append(reconciled)
                for bytes in inputs {
                    let wire = try modernCutoverSnapshot(bytes), batch = try JSONDecoder().decode(WritingBatch.self, from: canonicalEncoder().encode(wire))
                    guard batch.documentID == archive.documentID, batch.version == version, batch.epoch == final.epoch, batch.baseline == final.baseline else { throw EditorError.differentDocument }
                    try modernCutoverContains(batch.changes, in: final.changes, id: { $0.id })
                }
                old = restored.document
            }
            try inspectModernLegacyCollisions(old.blocks.map { .object($0.fields) })
            do { document = try ModernDocument(documentID: archive.documentID, blocks: old.blocks) }
            catch { throw ModernCutoverError.incompatibleRepresentation }
        }
        // A fresh modern baseline follows the admitted document's schema paths.
        // Walk those arrays once instead of replaying placements per collection.
        var ordered: [NodeAddress] = []
        var pending = document.blocks.reversed().map { (JSONValue.object($0.fields), NodeKind.block, NodeAddress($0.id)) }
        while let (value, kind, address) = pending.popLast() {
            ordered.append(address)
            let fields = value.object ?? [:]
            let collections = StructuralState.collectionFields(kind, fields, modern: true)
            for name in ["columns", "items", "children", "rows", "cells"].reversed() {
                guard let childKind = collections[name] else { continue }
                for child in (fields[name]?.array ?? []).reversed() {
                    guard let label = child["id"]?.string else { throw EditorError.invalidPath }
                    pending.append((child, childKind, NodeAddress(address.blockID, path: address.path + [name, label])))
                }
            }
        }
        struct AddressKey: Hashable {
            let blockID: String
            let path: [String]
            init(_ address: NodeAddress) { blockID = address.blockID; path = address.path }
        }
        let oldAddresses: [NodeID: NodeAddress]?
        if let writing { oldAddresses = try writing.cutoverAddresses() }
        else if let editor, editor.collaborationVersion == 2 { oldAddresses = try editor.cutoverAddresses() }
        else { oldAddresses = nil }
        var origins: [AddressKey: NodeID] = [:]
        for (origin, address) in oldAddresses ?? [:] {
            guard origins.updateValue(origin, forKey: AddressKey(address)) == nil else { throw EditorError.invalidPath }
        }
        let mapping = try ordered.map { address -> ModernCutoverIdentity in
            let target = NodeID.baseline(blockID: address.blockID, path: address.path)
            let source: ModernCutoverOrigin
            if oldAddresses != nil {
                guard let origin = origins[AddressKey(address)] else { throw EditorError.invalidPath }
                source = .origin(origin)
            } else { source = .legacyPath(address) }
            return ModernCutoverIdentity(source: source, address: address, target: target)
        }
        return ModernCutoverPreparation(archive: archive, bytes: archiveBytes, document: document, mapping: mapping, editor: editor, writing: writing)
    }
}

private func modernCutoverSnapshot(_ bytes: Data) throws -> JSONValue {
    guard bytes.count <= 64_000_000 else { throw EditorError.recoveryCapacityExceeded }
    let wire = try modernWireValue(bytes)
    guard let fields = wire.object, Set(fields.keys).isSubset(of: ["version", "documentID", "epoch", "baseline", "changes", "localHistory"]),
          wire["version"] != nil else { throw EditorError.invalidChange }
    let version = try modernLegacyVersion(wire)
    var batchFields = fields; batchFields.removeValue(forKey: "localHistory")
    let canonical: JSONValue
    if version <= 2 {
        let batch = try JSONDecoder().decode(ChangeBatch.self, from: canonicalEncoder().encode(batchFields))
        canonical = try JSONDecoder().decode(JSONValue.self, from: canonicalEncoder().encode(batch))
    } else {
        let batch = try JSONDecoder().decode(WritingBatch.self, from: canonicalEncoder().encode(batchFields))
        canonical = try JSONDecoder().decode(JSONValue.self, from: canonicalEncoder().encode(batch))
    }
    guard canonical == .object(batchFields) else { throw EditorError.invalidChange }
    if let local = fields["localHistory"] {
        struct History: Codable { let actorID: String; let undo: [ChangeID]; let redo: [ChangeID] }
        let history = try JSONDecoder().decode(History.self, from: canonicalEncoder().encode(local))
        guard validActor(history.actorID), try modernWireValue(canonicalEncoder().encode(history)) == local else { throw EditorError.invalidChange }
    }
    return wire
}
private func modernCutoverRecovery(_ bytes: Data) throws -> Data {
    let wire = try modernWireValue(bytes)
    guard let fields = wire.object, Set(fields.keys) == ["reason", "batch"],
          MergeRecoveryReason(rawValue: wire["reason"]?.string ?? "") != nil, let batch = wire["batch"] else { throw EditorError.invalidChange }
    return try canonicalEncoder().encode(batch)
}
private func modernCutoverContains<Change: Equatable>(_ input: [Change], in final: [Change], id: (Change) -> ChangeID) throws {
    var indexed: [ChangeID: Change] = [:]
    for change in final { guard indexed.updateValue(change, forKey: id(change)) == nil else { throw EditorError.invalidChange } }
    var seen = Set<ChangeID>()
    for change in input {
        guard seen.insert(id(change)).inserted, indexed[id(change)] == change else { throw ModernCutoverError.unreconciledInput }
    }
}
private func modernLegacyVersion(_ value: JSONValue) throws -> Int {
    guard case .number(let number) = value["version"], number.rounded() == number, (1...6).contains(number) else { throw EditorError.invalidChange }
    return Int(number)
}
private func modernCutoverArchiveWire(_ data: Data) throws -> JSONValue {
    guard data.count <= 384_000_000 else { throw EditorError.recoveryCapacityExceeded }
    try inspectModernJSONKeys(data, maximumDepth: 128)
    return try JSONDecoder().decode(JSONValue.self, from: data)
}
private func inspectModernLegacyCollisions(_ blocks: [JSONValue]) throws {
    var pending = blocks
    while let block = pending.popLast() {
        guard let fields = block.object else { throw EditorError.invalidChange }
        guard !["columns", "file"].contains(fields["type"]?.string ?? ""), fields["semanticColor"] == nil,
              fields["semanticBackground"] == nil else { throw ModernCutoverError.incompatibleRepresentation }
        if fields["type"] == .string("toggle") { pending.append(contentsOf: fields["children"]?.array ?? []) }
        // Item/cell metadata stays opaque. Only actual block schemas reserve the
        // modern block-default registers; consumer JSON is never recursively retyped.
    }
}
