#if canImport(SwiftUI)
import BlockEditorCore
import SwiftUI

/// Version-4 native surface. Stored asset strings never initiate network access;
/// hosts supply rendering, storage, sync, presence and publication.
@MainActor public struct WritingBlockEditorView: View {
    private let model: WritingEditorModel
    private let asset: (Block) -> AnyView
    public init(model: WritingEditorModel, asset: @escaping (Block) -> AnyView = { block in
        AnyView(Label(block.fields["alt"]?.string ?? "Image", systemImage: "photo"))
    }) { self.model = model; self.asset = asset }
    public var body: some View {
        VStack(alignment: .leading) {
            HStack {
                Button("Undo", systemImage: "arrow.uturn.backward") { model.perform { try $0.undo() } }.disabled(!model.canUndo)
                Button("Redo", systemImage: "arrow.uturn.forward") { model.perform { try $0.redo() } }.disabled(!model.canRedo)
                WritingActionGroup("Insert block", systemImage: "plus") {
                    ForEach(NativeBlockInsertion.allCases.filter { model.allowedBlockTypes?.contains($0.blockType) != false }) { insertion in
                        Button(insertion.title) { model.perform { session in
                            let after = try session.collectionNodes(in: .root).last
                            try session.insertCollectionNodes([.object(insertion.block().fields)], into: .root, after: after)
                        } }
                    }
                }
            }
            if let error = model.error { Text(error).foregroundStyle(.red).accessibilityLabel("Editor error: \(error)") }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    ForEach(model.document.blocks) { block in
                        WritingBlockContent(model: model, rootID: block.id, block: block, path: [], asset: asset)
                            .id(identity(NodeAddress(block.id)))
                    }
                }.padding()
            }
        }.id(ObjectIdentifier(model)).disabled(!model.isEditable)
    }
    private func identity(_ address: NodeAddress) -> NodeID { (try? model.session.node(at: address)) ?? .baseline(blockID: address.blockID, path: address.path) }
}

@MainActor private struct WritingBlockContent: View {
    let model: WritingEditorModel
    let rootID: String
    let block: Block
    let path: [String]
    let asset: (Block) -> AnyView
    @State private var expanded = true
    var body: some View {
        WritingRenderedNode(model: model, identity: identity(path)) { lease in
            VStack(alignment: .leading) {
                #if os(watchOS)
                content(lease)
                WritingActionGroup("Block actions", systemImage: "ellipsis") { WritingNodeActions(model: model, lease: lease) }
                #else
                content(lease).contextMenu { WritingNodeActions(model: model, lease: lease) }
                #endif
                if ["paragraph", "heading", "quote", "callout"].contains(block.type), let children = block.fields["children"]?.array {
                    WritingListItems(model: model, rootID: rootID, items: children, path: path + ["children"], style: block.fields["style"]?.string ?? "unordered", authorCollection: false)
                }
            }.accessibilityElement(children: .contain)
        }
    }
    @ViewBuilder private func content(_ lease: WritingRenderedOrigin) -> some View {
        switch block.type {
        case "paragraph", "heading", "quote", "callout":
            field("content").accessibilityAddTraits(block.type == "heading" ? .isHeader : [])
        case "list":
            WritingListItems(model: model, rootID: rootID, items: block.fields["items"]?.array ?? [], path: path + ["items"], style: block.fields["style"]?.string ?? "unordered", authorCollection: true)
        case "toggle":
            HStack { Button(expanded ? "Collapse toggle" : "Expand toggle", systemImage: expanded ? "chevron.down" : "chevron.right") { expanded.toggle() }.labelStyle(.iconOnly); field("summary", label: "Toggle title") }
            if expanded {
                ForEach(block.fields["children"]?.array ?? [], id: \.selfID) { value in
                    if let fields = value.object, let child = try? Block(fields: fields) {
                        WritingBlockContent(model: model, rootID: rootID, block: child, path: path + ["children", child.id], asset: asset)
                            .id(identity(path + ["children", child.id]))
                    }
                }.padding(.leading, 20)
                Button("Add paragraph") { insertChild(.object(["id": .string(UUID().uuidString), "type": .string("paragraph"), "content": .array([])]), field: "children", lease: lease) }
                    .disabled(!lease.canAuthor || model.allowedBlockTypes?.contains("paragraph") == false)
            }
        case "table":
            ScrollView(.horizontal) {
                Grid(alignment: .topLeading) {
                    ForEach(block.fields["rows"]?.array ?? [], id: \.selfID) { row in
                        let rowOrigin = identity(path + ["rows", row.selfID])
                        WritingRenderedNode(model: model, identity: rowOrigin) { rowLease in
                        GridRow {
                            ForEach(row["cells"]?.array ?? [], id: \.selfID) { cell in
                                WritingInputField(model: model, address: TextAddress(rootID, path: path + ["rows", row.selfID, "cells", cell.selfID, "content"]), label: "Table cell")
                                    .id(identity(path + ["rows", row.selfID, "cells", cell.selfID])).frame(minWidth: 140)
                            }
                        }
                        Button("Add cell") {
                            rowLease.perform { session in
                                let collection = NodeCollection(owner: rowOrigin, field: "cells")
                                try session.insertCollectionNodes([.object(["id": .string(UUID().uuidString), "content": .array([])])], into: collection, after: session.collectionNodes(in: collection).last)
                            }
                        }.disabled(!rowLease.canAuthor || model.allowedBlockTypes?.contains("table") == false)
                        }
                    }
                }
            }
            Button("Add row") { insertChild(.object(["id": .string(UUID().uuidString), "cells": .array([.object(["id": .string(UUID().uuidString), "content": .array([])])])]), field: "rows", lease: lease) }
                .disabled(!lease.canAuthor || model.allowedBlockTypes?.contains("table") == false)
        case "code": field("code", label: "Code")
        case "math": field("expression", label: "Math")
        case "image": asset(block); if block.fields["caption"] != nil { field("caption", label: "Image caption") }
        case "embed": Text(block.fields["title"]?.string ?? block.fields["url"]?.string ?? "Embedded content")
        case "divider": Divider()
        default: Label("\(block.type.capitalized) content preserved", systemImage: "doc")
        }
    }
    private func field(_ name: String, label: String = "Block text") -> some View {
        WritingInputField(model: model, address: TextAddress(rootID, path: path + [name]), label: label)
    }
    private func identity(_ path: [String]) -> NodeID { (try? model.session.node(at: NodeAddress(rootID, path: path))) ?? .baseline(blockID: rootID, path: path) }
    private func insertChild(_ value: JSONValue, field: String, lease: WritingRenderedOrigin) {
        lease.perform { session in
            let collection = NodeCollection(owner: lease.identity, field: field)
            try session.insertCollectionNodes([value], into: collection, after: session.collectionNodes(in: collection).last)
        }
    }
}

@MainActor private struct WritingListItems: View {
    let model: WritingEditorModel
    let rootID: String
    let items: [JSONValue]
    let path: [String]
    let style: String
    let authorCollection: Bool
    var body: some View {
        ForEach(Array(items.enumerated()), id: \.element.selfID) { index, item in
            let itemOrigin = identity(item.selfID)
            WritingRenderedNode(model: model, identity: itemOrigin) { lease in
            VStack(alignment: .leading) {
                HStack(alignment: .top) {
                    if style == "todo" {
                        Toggle("Completed", isOn: Binding(get: { item["checked"] == .bool(true) }, set: lease.checkedSetter())).labelsHidden()
                    } else { Text(style == "ordered" ? "\(index + 1)." : "•").accessibilityHidden(true) }
                    WritingInputField(model: model, address: TextAddress(rootID, path: path + [item.selfID, "content"]), label: "List item")
                }
                if let children = item["children"]?.array, !children.isEmpty {
                    WritingListItems(model: model, rootID: rootID, items: children, path: path + [item.selfID, "children"], style: style, authorCollection: authorCollection).padding(.leading, 20)
                }
                #if os(watchOS)
                WritingActionGroup("Item actions", systemImage: "ellipsis") { WritingNodeActions(model: model, lease: lease) }
                #endif
            }.id(itemOrigin)
            #if !os(watchOS)
            .contextMenu { WritingNodeActions(model: model, lease: lease) }
            #endif
            }
        }
    }
    private func identity(_ item: String) -> NodeID { (try? model.session.node(at: NodeAddress(rootID, path: path + [item]))) ?? .baseline(blockID: rootID, path: path + [item]) }
}

/// watchOS exposes actions inline; other families retain their native menus.
@MainActor private struct WritingActionGroup<Content: View>: View {
    let title: String
    let systemImage: String
    let content: Content
    @State private var expanded = false
    init(_ title: String, systemImage: String, @ViewBuilder content: () -> Content) {
        self.title = title; self.systemImage = systemImage; self.content = content()
    }
    @ViewBuilder var body: some View {
        #if os(watchOS)
        VStack(alignment: .leading) {
            Button { expanded.toggle() } label: { Label(title, systemImage: systemImage) }
                .accessibilityValue(expanded ? "Expanded" : "Collapsed")
            if expanded { content }
        }
        #else
        Menu { content } label: { Label(title, systemImage: systemImage) }
        #endif
    }
}

@MainActor private struct WritingNodeActions: View {
    let model: WritingEditorModel
    let lease: WritingRenderedOrigin
    var body: some View {
        let identity = lease.identity
        Button("Move up") { lease.move(down: false) }.disabled(!lease.canMove(down: false))
        Button("Move down") { lease.move(down: true) }.disabled(!lease.canMove(down: true))
        if lease.isListItem {
            Button("Indent") { lease.indent() }.disabled(!lease.canIndent)
            Button("Outdent") { lease.outdent() }.disabled(!lease.canOutdent)
        }
        Button("Duplicate") { lease.perform { session in
            try session.duplicate(WritingSelection(nodes: [identity]), into: model.collection(containing: identity), after: identity)
        } }.disabled(!lease.canAuthor)
        if let value = try? model.nodeValue(identity), ["paragraph", "heading", "quote", "callout", "code", "list"].contains(value["type"]?.string ?? "") {
            let field = value["type"] == .string("code") ? "code" : "content"
            let targetOrigin: NodeID? = {
                if value["type"] == .string("list"), let first = value["items"]?.array?.first?.selfID,
                   let live = try? model.session.address(of: identity) {
                    return try? model.session.node(at: NodeAddress(live.blockID, path: live.path + ["items", first]))
                }
                return identity
            }()
            if let targetOrigin {
                let target = targetOrigin.textAddressForApple(field)
                let targetLease = targetOrigin == identity ? lease : WritingRenderedOrigin(model: model, identity: targetOrigin)
                WritingActionGroup("Convert block", systemImage: "arrow.triangle.2.circlepath") {
                    ForEach(["paragraph", "heading", "quote", "callout", "list", "code"], id: \.self) { type in
                        Button(type.capitalized) { lease.convert(at: target, requiring: targetLease, to: type) }
                            .disabled(!lease.canAuthor || !targetLease.canAuthor || model.allowedBlockTypes?.contains(type) == false)
                    }
                }
            }
        }

        Button("Delete", role: .destructive) { lease.perform { try $0.delete(WritingSelection(nodes: [identity])) } }.disabled(!lease.canAuthor)
    }
}

@MainActor struct WritingInputField: View {
    let model: WritingEditorModel
    let address: TextAddress
    var label = "Block text"
    var body: some View {
        #if os(macOS)
        WritingMacTextInput(model: model, address: address, label: label).frame(minHeight: 32)
        #elseif os(iOS) || os(visionOS)
        WritingUIKitTextInput(model: model, address: address, label: label).frame(minHeight: 32)
        #else
        WritingPlatformTextField(model: model, address: address, label: label)
        #endif
    }
}
#endif
