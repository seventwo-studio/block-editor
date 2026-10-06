#if os(watchOS) || os(tvOS)
import BlockEditorCore
import SwiftUI

/// Reduced platforms preserve the complete admitted document and expose only
/// reading, text, checklist and reorder operations. Rich fields never become a
/// replacement JSON document merely because this host cannot render every tool.
@MainActor public struct ModernBlockEditorView: View {
    @Bindable private var model: ModernEditorModel
    public init(model: ModernEditorModel, host: ModernEditorHostActions = .init(), providers: ModernProviderController? = nil) { self.model = model }
    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                ReducedModernField(model: model, field: model.session.titleField, label: "Document title")
                collection(.root)
                if let error = model.error { Text(error).foregroundStyle(.red) }
            }.padding()
        }
    }
    private func value(_ node: NodeID) -> JSONValue? {
        guard let address = try? model.session.address(of: node), let block = model.document.blocks.first(where: { $0.id == address.blockID }) else { return nil }
        return JSONValue.object(block.fields).value(at: address.path)
    }
    private func collection(_ collection: NodeCollection) -> AnyView {
        let nodes = (try? model.session.nodes(in: collection)) ?? []
        return AnyView(VStack(alignment: .leading, spacing: 12) {
            ForEach(Array(nodes.enumerated()), id: \.element) { index, node in
                VStack(alignment: .leading) {
                    if let value = value(node) {
                        if value["checked"] != nil {
                            Toggle("Completed", isOn: Binding(get: { value["checked"] == .bool(true) }, set: { checked in
                                do { try model.perform { try $0.listStructure(ModernListTarget(selection: $0.captureListNodes([node])), action: .setChecked, checked: checked).focus } } catch { model.report(error) }
                            })).disabled(!model.isEditable)
                        }
                        ForEach(["content", "summary", "code", "caption"], id: \.self) { name in
                            if let field = try? model.session.field(node: node, name: name) { ReducedModernField(model: model, field: field, label: name == "code" ? "Code" : "Text") }
                        }
                        if let name = value["name"]?.string ?? value["alt"]?.string ?? value["title"]?.string { Text(name) }
                        ForEach(["columns", "children", "items", "rows", "cells"], id: \.self) { field in
                            if value[field]?.array != nil { self.collection(NodeCollection(owner: node, field: field)).padding(.leading, 8) }
                        }
                        if value["type"]?.string != "columns", collection.field == "blocks" || collection.field == "children" {
                            HStack {
                                Button("Move up") { move(node, nodes: nodes, index: index, down: false, collection: collection) }.disabled(index == 0 || !model.isEditable)
                                Button("Move down") { move(node, nodes: nodes, index: index, down: true, collection: collection) }.disabled(index + 1 == nodes.count || !model.isEditable)
                            }
                        }
                    }
                }
            }
        })
    }
    private func move(_ node: NodeID, nodes: [NodeID], index: Int, down: Bool, collection: NodeCollection) {
        do { try model.perform { session in
            let after = down ? nodes[index + 1] : index > 1 ? nodes[index - 2] : nil
            if (try? session.captureListNodes([node])) != nil {
                return try session.listStructure(ModernListTarget(selection: session.captureListNodes([node]), boundary: session.captureListBoundary(in: collection, after: after)), action: .reorder).focus
            }
            return try session.move(ModernMoveTarget(selection: session.captureNodes([node]), boundary: session.captureBoundary(in: collection, after: after))).focus
        } } catch { model.report(error) }
    }
}

@MainActor private struct ReducedModernField: View {
    let model: ModernEditorModel
    let field: WritingField
    let label: String
    @State private var buffer = ""
    @State private var original = ""
    @State private var editing = false
    var body: some View {
        TextField(label, text: $buffer, onEditingChanged: { active in
            editing = active
            if active { original = (try? model.session.text(in: field)) ?? buffer }
        }).disabled(!model.isEditable).onAppear { buffer = (try? model.session.text(in: field)) ?? "" }
            .onChange(of: model.document) { _, _ in if !editing { buffer = (try? model.session.text(in: field)) ?? buffer } }
            .onSubmit {
                do {
                    guard try model.session.text(in: field) == original else { throw ModernSessionError.unavailable("pendingNativeInputRequiresReview") }
                    let old = Array(original.unicodeScalars), next = Array(buffer.unicodeScalars)
                    var prefix = 0, suffix = 0
                    while prefix < min(old.count, next.count), old[prefix] == next[prefix] { prefix += 1 }
                    while suffix < min(old.count, next.count) - prefix, old[old.count - 1 - suffix] == next[next.count - 1 - suffix] { suffix += 1 }
                    let lower = String(String.UnicodeScalarView(old.prefix(prefix))).utf16.count
                    let upper = original.utf16.count - String(String.UnicodeScalarView(old.suffix(suffix))).utf16.count
                    let replacement = String(String.UnicodeScalarView(next[prefix..<(next.count - suffix)]))
                    try model.perform { session in .text(try session.replaceText(in: field, range: lower..<upper, with: replacement)) }
                    original = buffer
                } catch { model.report(error) } // keep the full local buffer visible
            }
    }
}
#endif
