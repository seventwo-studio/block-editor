#if canImport(SwiftUI)
import BlockEditorCore
import SwiftUI

/// Native session surface. Assets are rendered only by a host-supplied view;
/// stored source strings never cause automatic network fetches.
@MainActor public struct BlockEditorView: View {
    private let model: EditorModel
    private let asset: (Block) -> AnyView
    public init(model: EditorModel, asset: @escaping (Block) -> AnyView = { block in
        AnyView(Label(block.fields["alt"]?.string ?? "Image", systemImage: "photo"))
    }) { self.model = model; self.asset = asset }

    public var body: some View {
        VStack(alignment: .leading) {
            HStack {
                Button("Undo", systemImage: "arrow.uturn.backward") { model.perform { try $0.undo() } }.disabled(!model.canUndo)
                Button("Redo", systemImage: "arrow.uturn.forward") { model.perform { try $0.redo() } }.disabled(!model.canRedo)
                Button("Paragraph", systemImage: "plus") {
                    model.perform { try $0.insert(.paragraph(id: UUID().uuidString), after: model.document.blocks.last?.id) }
                }
            }
            if let error = model.error { Text(error).foregroundStyle(.red).accessibilityLabel("Editor error: \(error)") }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    ForEach(model.document.blocks) { block in
                        VStack(alignment: .leading) {
                            blockContent(block)
                            HStack {
                                Button("Move up", systemImage: "arrow.up") { moveUp(block) }
                                    .disabled(model.document.blocks.first?.id == block.id)
                                Button("Delete", systemImage: "trash", role: .destructive) { model.perform { try $0.delete(blockID: block.id) } }
                            }.labelStyle(.iconOnly)
                        }.accessibilityElement(children: .contain)
                    }
                }.padding()
            }
        }.id(ObjectIdentifier(model))
    }
    @ViewBuilder private func blockContent(_ block: Block) -> some View {
        switch block.type {
        case "paragraph", "heading", "quote", "callout":
            InlineField(model: model, address: TextAddress(block.id), nodes: block.fields["content"]?.array ?? [])
        case "list":
            ForEach(block.fields["items"]?.array ?? [], id: \.selfID) { item in
                HStack {
                    if block.fields["style"]?.string == "todo" {
                        Toggle("Completed", isOn: Binding(get: { item["checked"] == .bool(true) }, set: { checked in
                            model.perform { try $0.setField(blockID: block.id, path: ["items", item.selfID, "checked"], value: .bool(checked)) }
                        })).labelsHidden()
                    }
                    InlineField(model: model, address: TextAddress(block.id, path: ["items", item.selfID, "content"]), nodes: item["content"]?.array ?? [])
                }
            }
        case "divider": Divider()
        case "image": asset(block)
        case "code": PlainField(model: model, address: TextAddress(block.id, path: ["code"]), text: block.fields["code"]?.string ?? "", label: "Code")
        case "math": PlainField(model: model, address: TextAddress(block.id, path: ["expression"]), text: block.fields["expression"]?.string ?? "", label: "Math")
        case "embed": Text(block.fields["title"]?.string ?? block.fields["url"]?.string ?? "Embedded content")
        default:
            Label("\(block.type.capitalized) content preserved", systemImage: "doc")
        }
    }
    private func moveUp(_ block: Block) {
        guard let index = model.document.blocks.firstIndex(where: { $0.id == block.id }), index > 0 else { return }
        model.perform { try $0.move(blockID: block.id, after: index > 1 ? model.document.blocks[index - 2].id : nil) }
    }
}

private extension JSONValue { var selfID: String { self["id"]?.string ?? "" } }

@MainActor private struct PlainField: View {
    let model: EditorModel
    let address: TextAddress
    let text: String
    let label: String
    @State private var selection = NSRange(location: 0, length: 0)
    var body: some View {
        #if os(macOS)
        MacTextInput(model: model, address: address, label: label, selection: $selection).frame(minHeight: 64)
        #elseif os(iOS) || os(visionOS)
        UIKitTextInput(model: model, address: address, label: label, selection: $selection).frame(minHeight: 64)
        #else
        Text(text)
        #endif
    }
}

@MainActor private struct InlineField: View {
    let model: EditorModel
    let address: TextAddress
    let nodes: [JSONValue]
    @State private var nativeSelection = NSRange(location: 0, length: 0)

    var body: some View {
        #if os(macOS) || os(iOS) || os(visionOS)
        VStack(alignment: .leading) {
            #if os(macOS)
            MacTextInput(model: model, address: address, selection: $nativeSelection).frame(minHeight: 64)
            #else
            UIKitTextInput(model: model, address: address, selection: $nativeSelection).frame(minHeight: 64)
            #endif
            HStack {
                Button("Bold") { formatNative("bold") }
                Button("Italic") { formatNative("italic") }
                Button("Strikethrough") { formatNative("strikethrough") }
                Button("Clear bold") { formatNative("bold", remove: true) }
            }
        }
        #elseif os(watchOS) || os(tvOS)
        PlatformTextField(model: model, address: address)
        #endif
    }
    private func formatNative(_ type: String, remove: Bool = false) {
        model.perform { try $0.format(at: address, range: nativeSelection.location..<NSMaxRange(nativeSelection), markType: type, mark: remove ? nil : .object(["type": .string(type)])) }
    }
}
#endif
