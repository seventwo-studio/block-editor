#if canImport(SwiftUI)
import BlockEditorCore
import SwiftUI

/// A rendering owns its own irreversible lease. Reappearance creates a fresh
/// token so retained callbacks cannot regain authority after move/Undo/reuse.
@MainActor final class WritingRenderedOrigin {
    private weak var model: WritingEditorModel?
    let identity: NodeID
    private let address: NodeAddress?
    private var observation: UUID?
    private(set) var isActive = true
    init(model: WritingEditorModel, identity: NodeID) {
        self.model = model; self.identity = identity
        address = try? model.session.address(of: identity)
        observation = model.observeRenderedOrigin { [weak self] in
            guard let self else { return false }
            if !self.locationCurrent { self.close() }
            return self.isActive
        }
    }
    isolated deinit {
        if let observation { model?.removeRenderedOrigin(observation) }
    }
    func close() {
        isActive = false
        if let observation { model?.removeRenderedOrigin(observation) }
        observation = nil
    }
    var locationCurrent: Bool {
        guard isActive, let model, let address else { return false }
        return (try? model.session.address(of: identity)) == address
    }
    var canAuthor: Bool { locationCurrent && model?.isEditable == true }
    @discardableResult func perform(_ command: (WritingSession) throws -> Void) -> Bool {
        guard canAuthor, let model else { return false }
        return model.performCommand(on: identity) { session in
            guard self.canAuthor else { throw EditorError.invalidRange }
            try command(session); return nil
        }
    }
    @discardableResult func convert(at target: TextAddress, requiring targetLease: WritingRenderedOrigin,
                                   to type: String) -> Bool {
        guard canAuthor, targetLease.canAuthor, target.identity == targetLease.identity, let model,
              model.allowedBlockTypes?.contains(type) != false else { return false }
        return model.performCommand(on: identity) { session in
            guard self.canAuthor, targetLease.canAuthor,
                  model.allowedBlockTypes?.contains(type) != false else { throw EditorError.invalidRange }
            return try session.convertBlock(at: target, offset: 0, to: WritingBlockTarget(type: type))
        }
    }
    func checkedSetter() -> (Bool) -> Void {
        { [weak self] value in
            guard let self else { return }
            self.perform { try $0.setNodeField(self.identity, path: ["checked"], value: .bool(value)) }
        }
    }
    func canMove(down: Bool) -> Bool {
        guard canAuthor, let model, let bounds = try? model.siblingBounds(identity) else { return false }
        return down ? bounds.index + 1 < bounds.count : bounds.index > 0
    }
    @discardableResult func move(down: Bool) -> Bool {
        // Reject an already impossible action before native composition commits.
        guard canMove(down: down), let model else { return false }
        return perform { session in
            let collection = try model.collection(containing: self.identity)
            let siblings = try session.collectionNodes(in: collection)
            guard let index = siblings.firstIndex(of: self.identity), down ? index + 1 < siblings.count : index > 0 else { throw EditorError.invalidRange }
            try session.move(WritingSelection(nodes: [self.identity]), into: collection,
                after: down ? siblings[index + 1] : index > 1 ? siblings[index - 2] : nil)
        }
    }
    private var itemCollection: NodeCollection? {
        guard canAuthor, let model, let value = try? model.nodeValue(identity), value["type"] == nil,
              let collection = try? model.collection(containing: identity) else { return nil }
        if collection.field == "items" { return collection }
        if collection.field == "children", let owner = collection.owner,
           let parent = try? model.nodeValue(owner), parent["type"] == nil, parent["content"]?.array != nil { return collection }
        return nil
    }
    var isListItem: Bool { itemCollection != nil }
    var canIndent: Bool { itemCollection != nil && canMove(down: false) }
    var canOutdent: Bool { itemCollection?.field == "children" }
    @discardableResult func indent() -> Bool {
        guard canIndent, let model else { return false }
        return perform { session in
            let collection = try model.collection(containing: self.identity), siblings = try session.collectionNodes(in: collection)
            guard let index = siblings.firstIndex(of: self.identity), index > 0 else { throw EditorError.invalidRange }
            let target = NodeCollection(owner: siblings[index - 1], field: "children")
            try session.move(WritingSelection(nodes: [self.identity]), into: target, after: session.collectionNodes(in: target).last)
        }
    }
    @discardableResult func outdent() -> Bool {
        guard canOutdent, let model else { return false }
        return perform { session in
            let collection = try model.collection(containing: self.identity)
            guard collection.field == "children", let parent = collection.owner,
                  try model.nodeValue(parent)["type"] == nil else { throw EditorError.invalidRange }
            try session.move(WritingSelection(nodes: [self.identity]), into: model.collection(containing: parent), after: parent)
        }
    }
}

/// The body captures the current token by value. A retired token never re-arms,
/// even if SwiftUI preserves this wrapper's State across a later appearance.
@MainActor struct WritingRenderedNode<Content: View>: View {
    let model: WritingEditorModel
    let identity: NodeID
    let content: (WritingRenderedOrigin) -> Content
    @State private var token: WritingRenderedOrigin
    init(model: WritingEditorModel, identity: NodeID, @ViewBuilder content: @escaping (WritingRenderedOrigin) -> Content) {
        self.model = model; self.identity = identity; self.content = content
        _token = State(initialValue: WritingRenderedOrigin(model: model, identity: identity))
    }
    var body: some View {
        let rendered = token
        content(rendered)
            .onDisappear { rendered.close() }
            .onAppear { renewIfNeeded() }
            .onChange(of: model.document) { _, _ in renewIfNeeded() }
    }
    private func renewIfNeeded() {
        if !token.locationCurrent {
            token.close()
            token = WritingRenderedOrigin(model: model, identity: identity)
        }
    }
}
#endif
