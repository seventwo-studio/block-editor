import BlockEditorCore
import Foundation
import Observation

/// The host calls save from its own autosave lifecycle. Provider requests use
/// this same queue so a stale captured checkpoint cannot overwrite a newer pair.
@MainActor public final class ModernPersistenceController {
    public let model: ModernEditorModel
    public let store: ModernHostStore
    public private(set) var revision: UUID?
    private var tail: Task<ModernHostCheckpoint, Error>?
    public init(model: ModernEditorModel, store: ModernHostStore, loadedRevision: UUID? = nil) {
        self.model = model; self.store = store; revision = loadedRevision
    }
    @discardableResult public func save() async throws -> ModernHostCheckpoint {
        let previous = tail
        let task = Task { @MainActor in
            _ = try? await previous?.value
            // Capture only after the previous write finishes. All local sidecars
            // and accepted history belong to this single immutable checkpoint.
            let checkpoint = try model.checkpoint()
            do {
                let saved = try await store.save(checkpoint, replacing: revision)
                revision = saved.revision
                return saved
            } catch ModernHostStoreError.durabilityUnconfirmed(let proposed) {
                // A rename may already have published the proposed pair. Read
                // its actual revision before another compare-and-swap attempt.
                if let actual = try await store.load(), actual.revision == proposed { revision = actual.revision }
                throw ModernHostStoreError.durabilityUnconfirmed(revision: proposed)
            }
        }
        tail = task
        return try await task.value
    }
}

public typealias ModernProvider = @Sendable (ModernAsyncTarget) async throws -> [String: JSONValue]

/// Restored records are presentation only. Hosts explicitly start/retry work;
/// neither reopening nor rendering starts an upload or network request.
@MainActor @Observable public final class ModernProviderController {
    public private(set) var records: [ModernAsyncRecord]
    public private(set) var error: String?
    @ObservationIgnored private let persistence: ModernPersistenceController
    @ObservationIgnored private let provider: ModernProvider
    @ObservationIgnored private var tasks: [String: Task<Void, Never>] = [:]
    @ObservationIgnored private var unsaved: [String: (ModernAsyncTarget, [String: JSONValue])] = [:]
    private var model: ModernEditorModel { persistence.model }
    public init(persistence: ModernPersistenceController, provider: @escaping ModernProvider) {
        self.persistence = persistence; self.provider = provider; records = persistence.model.session.asyncRequests
    }
    private func refresh() { records = model.session.asyncRequests }
    @discardableResult public func start(node: NodeID) throws -> ModernAsyncTarget {
        guard model.isActive, model.isEditable else { throw ModernSessionError.unavailable("inactiveHost") }
        // Reserve the maximum checked metadata result before invoking the host.
        // The bound includes worst-case JSON escaping for all three text fields.
        guard tasks.count < 8, try model.session.exportAsyncRequests().count + (tasks.count + 1) * 2_000_000 < 16_000_000 else {
            throw EditorError.recoveryCapacityExceeded
        }
        let target = try model.session.beginAsyncBlock(node, requestID: UUID().uuidString)
        let generation = model.invocationGeneration
        refresh()
        tasks[target.requestID] = Task { @MainActor [self] in
            defer { tasks.removeValue(forKey: target.requestID); refresh() }
            do {
                try await persistence.save() // durable invocation precedes work
                guard model.isActive, model.invocationGeneration == generation,
                      model.session.asyncRequests.contains(where: { $0.target == target && $0.status == .pending }) else { return }
                let metadata = try await provider(target)
                // Keep the raw successful result until paired persistence has
                // succeeded, including failures while retaining the core record.
                unsaved[target.requestID] = (target, metadata)
                try model.session.retainAsyncBlockResult(target, metadata: metadata)
                refresh()
                try await persistence.save()
                unsaved.removeValue(forKey: target.requestID)
                guard model.isActive, model.isEditable, model.invocationGeneration == generation else { return }
                _ = try model.session.completeAsyncBlock(target, metadata: metadata)
                refresh()
                try await persistence.save() // accepted receipt pairs with result
                error = nil
            } catch {
                self.error = String(describing: error)
                // Never turn a successfully retained response into a failed
                // provider invocation; Retry result must still be available.
                if model.session.asyncRequests.contains(where: { $0.target == target && $0.status == .pending }), unsaved[target.requestID] == nil {
                    try? model.session.failAsyncBlock(target, reason: String(describing: error).prefix(1000).description)
                    _ = try? await persistence.save()
                }
            }
        }
        return target
    }
    public func waitForRequest(_ target: ModernAsyncTarget) async { await tasks[target.requestID]?.value }
    public func retryResult(_ target: ModernAsyncTarget) async throws {
        let generation = model.invocationGeneration
        guard model.isActive, model.isEditable else { throw ModernSessionError.unavailable("inactiveHost") }
        let metadata = unsaved[target.requestID]?.1 ?? records.first(where: { $0.target == target })?.result
        guard let metadata else { throw ModernSessionError.unavailable("noRetainedResult") }
        try model.session.retainAsyncBlockResult(target, metadata: metadata)
        refresh()
        try await persistence.save()
        unsaved.removeValue(forKey: target.requestID)
        guard model.isActive, model.isEditable, model.invocationGeneration == generation else { return }
        _ = try model.session.completeAsyncBlock(target, metadata: metadata)
        refresh()
        try await persistence.save()
        error = nil
    }
    public func cancel(_ target: ModernAsyncTarget) async throws {
        try model.session.cancelAsyncBlock(target)
        tasks[target.requestID]?.cancel()
        refresh()
        try await persistence.save()
    }
}
