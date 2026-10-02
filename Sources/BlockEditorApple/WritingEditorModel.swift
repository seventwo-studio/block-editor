#if canImport(SwiftUI)
import BlockEditorCore
import Observation
import SwiftUI

/// Explicit protocol-4 native editor. Hosts own persistence, transport and assets.
/// Legacy EditorModel/EditorSession consumers retain their existing epoch and API.
public struct WritingPendingDraft {
    public let address: TextAddress
    public let text: String
    public let selection: NSRange
    public let reason: String
}

@MainActor @Observable public final class WritingEditorModel {
    public private(set) var document: BlockEditorCore.Document
    public private(set) var canUndo: Bool
    public private(set) var canRedo: Bool
    public private(set) var error: String?
    public var isEditable = true
    public private(set) var pendingDrafts: [UUID: WritingPendingDraft] = [:]
    public var allowedBlockTypes: Set<String>? { didSet { session.allowedBlockTypes = allowedBlockTypes } }
    @ObservationIgnored public let session: WritingSession
    @ObservationIgnored public var onChange: ((BlockEditorCore.Document, WritingChange?) -> Void)?
    @ObservationIgnored private var inputs: [UUID: (before: () -> Void, after: () -> Void, commit: () throws -> Void, caret: (WritingPosition) -> Void)] = [:]
    @ObservationIgnored private var compositions = Set<UUID>()
    @ObservationIgnored var pendingCaret: WritingPosition?
    @ObservationIgnored var pendingCaretInput: UUID?
    @ObservationIgnored var commandCaret: WritingPosition?
    @ObservationIgnored private var performingCommand = false
    #if os(macOS) || os(iOS) || os(visionOS)
    @ObservationIgnored let focus = WritingNativeFocus()
    #endif

    public init(session: WritingSession) throws {
        guard session.protocolVersion == 4 else { throw EditorError.unsupportedVersion(session.protocolVersion) }
        self.session = session; document = session.document
        canUndo = session.canUndo; canRedo = session.canRedo; allowedBlockTypes = session.allowedBlockTypes
        session.onWillReceive = { [weak self] in guard let self else { return }; Array(self.inputs.values).forEach { $0.before() } }
        session.onChange = { [weak self] document, change in
            guard let self else { return }
            self.document = document; self.canUndo = self.session.canUndo; self.canRedo = self.session.canRedo
            if !self.performingCommand { Array(self.inputs.values).forEach { $0.after() } }; self.onChange?(document, change)
        }
    }
    func observeInput(id: UUID, before: @escaping () -> Void, after: @escaping () -> Void,
                      commit: @escaping () throws -> Void, caret: @escaping (WritingPosition) -> Void) -> () -> Void {
        inputs[id] = (before, after, commit, caret)
        return { [weak self] in self?.inputs.removeValue(forKey: id) }
    }
    func composing(_ id: UUID, _ active: Bool) {
        if active { compositions.insert(id) } else { compositions.remove(id) }
        session.isComposing = !compositions.isEmpty
    }
    /// Commit platform composition before any author command. Failures retain the
    /// accepted shared state and remain visible to the host.
    public func perform(_ operation: (WritingSession) throws -> Void) {
        _ = performCommand { session in try operation(session); return nil }
    }
    /// Rendered callbacks retain opaque origins. Validate liveness before any
    /// composition commit so deleted controls cannot mutate a replacement label.
    func perform(on identity: NodeID, _ operation: (WritingSession) throws -> Void) {
        _ = performCommand(on: identity) { session in try operation(session); return nil }
    }
    @discardableResult func performCommand(on identity: NodeID, source: UUID? = nil, _ operation: (WritingSession) throws -> WritingPosition?) -> Bool {
        guard isEditable else { return false }
        do { _ = try session.address(of: identity) }
        catch { self.error = String(describing: error); return false }
        return performCommand(source: source, operation)
    }
    func checkedSetter(for identity: NodeID) -> (Bool) -> Void {
        { [weak self] value in
            self?.perform(on: identity) { try $0.setNodeField(identity, path: ["checked"], value: .bool(value)) }
        }
    }
    @discardableResult func performCommand(source: UUID? = nil, preservingCaret: Bool = false, _ operation: (WritingSession) throws -> WritingPosition?) -> Bool {
        guard isEditable, !performingCommand else { return false }
        var previousCaret = pendingCaret, previousSource = pendingCaretInput
        defer { commandCaret = nil }
        do {
            for input in Array(inputs.values) { try input.commit() }
            previousCaret = pendingCaret; previousSource = pendingCaretInput
            commandCaret = source != nil && previousSource == source ? previousCaret : nil
            Array(inputs.values).forEach { $0.before() }
            performingCommand = true
            pendingCaret = nil; pendingCaretInput = nil
            #if os(macOS) || os(iOS) || os(visionOS)
            focus.cancelExplicitCaret()
            #endif
            let returned = try operation(session)
            pendingCaret = returned ?? (preservingCaret && previousSource == source ? previousCaret : nil)
            pendingCaretInput = pendingCaret == nil ? nil : source
            performingCommand = false; error = nil
            if let returned, let source { inputs[source]?.caret(returned) }
            Array(inputs.values).forEach { $0.after() }
            #if os(macOS) || os(iOS) || os(visionOS)
            focus.requestCaret(returned)
            #endif
            return true
        } catch {
            performingCommand = false
            if let previousCaret, (try? session.resolve(previousCaret)) != nil {
                pendingCaret = previousCaret; pendingCaretInput = previousSource
            }
            Array(inputs.values).forEach { $0.after() }
            #if os(macOS) || os(iOS) || os(visionOS)
            focus.requestCaret(pendingCaret)
            #endif
            self.error = String(describing: error); return false
        }
    }
    func finishCaretTransfer() {
        pendingCaret = nil; pendingCaretInput = nil
        Array(inputs.values).forEach { $0.after() }
    }
    @discardableResult func performInput(_ operation: () throws -> Void) -> Bool {
        do { try operation(); error = nil; return true }
        catch { self.error = String(describing: error); return false }
    }
    func retainDraft(_ draft: WritingPendingDraft, id: UUID) { pendingDrafts[id] = draft }
    /// Hosts may archive a recovered draft before explicitly removing it.
    public func removePendingDraft(_ id: UUID) { pendingDrafts.removeValue(forKey: id) }
    func field(_ address: TextAddress) throws -> JSONValue {
        let identity = try session.position(at: address, offset: 0).field.node
        let live = try session.address(of: identity), field = address.path.last ?? "content"
        guard let block = document.blocks.first(where: { $0.id == live.blockID }),
              let value = JSONValue.object(block.fields).value(at: live.path + [field]) else { throw EditorError.invalidPath }
        return value
    }
    func collection(containing identity: NodeID) throws -> NodeCollection {
        let address = try session.address(of: identity)
        guard !address.path.isEmpty else { return .root }
        let parent = try session.node(at: NodeAddress(address.blockID, path: Array(address.path.dropLast(2))))
        return NodeCollection(owner: parent, field: address.path[address.path.count - 2])
    }
    func nodeValue(_ identity: NodeID) throws -> JSONValue {
        let address = try session.address(of: identity)
        guard let block = document.blocks.first(where: { $0.id == address.blockID }),
              let value = JSONValue.object(block.fields).value(at: address.path) else { throw EditorError.invalidPath }
        return value
    }
}
#endif
