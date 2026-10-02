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
        VStack(alignment: .leading) {
            #if os(watchOS)
            content
            WritingActionGroup("Block actions", systemImage: "ellipsis") { WritingNodeActions(model: model, address: NodeAddress(rootID, path: path)) }
            #else
            content.contextMenu { WritingNodeActions(model: model, address: NodeAddress(rootID, path: path)) }
            #endif
            if ["paragraph", "heading", "quote", "callout"].contains(block.type), let children = block.fields["children"]?.array {
                WritingListItems(model: model, rootID: rootID, items: children, path: path + ["children"], style: block.fields["style"]?.string ?? "unordered", authorCollection: false)
            }
        }.accessibilityElement(children: .contain)
    }
    @ViewBuilder private var content: some View {
        let owner = identity(path)
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
                Button("Add paragraph") { insertChild(.object(["id": .string(UUID().uuidString), "type": .string("paragraph"), "content": .array([])]), field: "children", owner: owner) }
                    .disabled(model.allowedBlockTypes?.contains("paragraph") == false)
            }
        case "table":
            ScrollView(.horizontal) {
                Grid(alignment: .topLeading) {
                    ForEach(block.fields["rows"]?.array ?? [], id: \.selfID) { row in
                        let rowOrigin = identity(path + ["rows", row.selfID])
                        GridRow {
                            ForEach(row["cells"]?.array ?? [], id: \.selfID) { cell in
                                WritingInputField(model: model, address: TextAddress(rootID, path: path + ["rows", row.selfID, "cells", cell.selfID, "content"]), label: "Table cell")
                                    .id(identity(path + ["rows", row.selfID, "cells", cell.selfID])).frame(minWidth: 140)
                            }
                        }
                        Button("Add cell") {
                            model.perform(on: rowOrigin) { session in
                                let collection = NodeCollection(owner: rowOrigin, field: "cells")
                                try session.insertCollectionNodes([.object(["id": .string(UUID().uuidString), "content": .array([])])], into: collection, after: session.collectionNodes(in: collection).last)
                            }
                        }.disabled(model.allowedBlockTypes?.contains("table") == false)
                    }
                }
            }
            Button("Add row") { insertChild(.object(["id": .string(UUID().uuidString), "cells": .array([.object(["id": .string(UUID().uuidString), "content": .array([])])])]), field: "rows", owner: owner) }
                .disabled(model.allowedBlockTypes?.contains("table") == false)
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
    private func insertChild(_ value: JSONValue, field: String, owner target: NodeID) {
        model.perform(on: target) { session in
            let collection = NodeCollection(owner: target, field: field)
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
            VStack(alignment: .leading) {
                HStack(alignment: .top) {
                    if style == "todo" {
                        Toggle("Completed", isOn: Binding(get: { item["checked"] == .bool(true) }, set: model.checkedSetter(for: itemOrigin))).labelsHidden()
                    } else { Text(style == "ordered" ? "\(index + 1)." : "•").accessibilityHidden(true) }
                    WritingInputField(model: model, address: TextAddress(rootID, path: path + [item.selfID, "content"]), label: "List item")
                }
                if let children = item["children"]?.array, !children.isEmpty {
                    WritingListItems(model: model, rootID: rootID, items: children, path: path + [item.selfID, "children"], style: style, authorCollection: authorCollection).padding(.leading, 20)
                }
                #if os(watchOS)
                WritingActionGroup("Item actions", systemImage: "ellipsis") { WritingNodeActions(model: model, address: NodeAddress(rootID, path: path + [item.selfID])) }
                #endif
            }.id(itemOrigin)
            #if !os(watchOS)
            .contextMenu { WritingNodeActions(model: model, address: NodeAddress(rootID, path: path + [item.selfID])) }
            #endif
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
    let address: NodeAddress
    var body: some View {
        if let identity = try? model.session.node(at: address) {
            Button("Move up") { move(identity, down: false) }
            Button("Move down") { move(identity, down: true) }
            Button("Duplicate") { model.perform(on: identity) { session in try session.duplicate(WritingSelection(nodes: [identity]), into: model.collection(containing: identity), after: identity) } }
            if let value = try? model.nodeValue(identity), ["paragraph", "heading", "quote", "callout", "code", "list"].contains(value["type"]?.string ?? "") {
                WritingActionGroup("Convert block", systemImage: "arrow.triangle.2.circlepath") {
                    ForEach(["paragraph", "heading", "quote", "callout", "list", "code"], id: \.self) { type in
                        let field = value["type"] == .string("code") ? "code" : "content"
                        let target: TextAddress? = {
                            if value["type"] == .string("list"), let first = value["items"]?.array?.first?.selfID,
                               let live = try? model.session.address(of: identity),
                               let node = try? model.session.node(at: NodeAddress(live.blockID, path: live.path + ["items", first])) {
                                return node.textAddressForApple("content")
                            }
                            return identity.textAddressForApple(field)
                        }()
                        Button(type.capitalized) {
                            if let target { model.performCommand(on: identity) { try $0.convertBlock(at: target, offset: 0, to: WritingBlockTarget(type: type)) } }
                        }.disabled(model.allowedBlockTypes?.contains(type) == false)
                    }
                }
            }
            Button("Delete", role: .destructive) { model.perform(on: identity) { try $0.delete(WritingSelection(nodes: [identity])) } }
        }
    }
    private func move(_ identity: NodeID, down: Bool) {
        model.perform(on: identity) { session in
            let collection = try model.collection(containing: identity), siblings = try session.collectionNodes(in: collection)
            guard let index = siblings.firstIndex(of: identity), down ? index + 1 < siblings.count : index > 0 else { throw EditorError.invalidRange }
            try session.move(WritingSelection(nodes: [identity]), into: collection, after: down ? siblings[index + 1] : index > 1 ? siblings[index - 2] : nil)
        }
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
