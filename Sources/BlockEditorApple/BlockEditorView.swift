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
                        #if os(macOS) || os(iOS) || os(visionOS)
                        HStack(alignment: .top, spacing: 4) {
                            Menu { blockActions(block) } label: {
                                Image(systemName: "ellipsis").frame(width: 24, height: 32)
                            }.accessibilityLabel("Block actions")
                            NativeBlockContent(model: model, rootID: block.id, block: block, path: [], asset: asset)
                        }.accessibilityElement(children: .contain)
                        #else
                        NativeBlockContent(model: model, rootID: block.id, block: block, path: [], asset: asset)
                            .contextMenu { blockActions(block) }
                            .accessibilityElement(children: .contain)
                        #endif
                    }
                }.padding()
            }
        }.id(ObjectIdentifier(model))
    }
    @ViewBuilder private func blockActions(_ block: Block) -> some View {
        Button("Move up", systemImage: "arrow.up") { moveUp(block) }
            .disabled(model.document.blocks.first?.id == block.id)
        Button("Delete", systemImage: "trash", role: .destructive) {
            model.perform { try $0.delete(blockID: block.id) }
        }
    }
    private func moveUp(_ block: Block) {
        guard let index = model.document.blocks.firstIndex(where: { $0.id == block.id }), index > 0 else { return }
        model.perform { try $0.move(blockID: block.id, after: index > 1 ? model.document.blocks[index - 2].id : nil) }
    }
}

extension JSONValue { var selfID: String { self["id"]?.string ?? "" } }

@MainActor struct PlainField: View {
    let model: EditorModel
    let address: TextAddress
    let text: String
    let label: String
    @State private var selection = NSRange(location: 0, length: 0)
    var body: some View {
        #if os(macOS)
        MacTextInput(model: model, address: address, label: label, selection: $selection).frame(minHeight: 32)
        #elseif os(iOS) || os(visionOS)
        UIKitTextInput(model: model, address: address, label: label, selection: $selection).frame(minHeight: 32)
        #else
        Text(text)
        #endif
    }
}

@MainActor struct InlineField: View {
    let model: EditorModel
    let address: TextAddress
    let nodes: [JSONValue]
    var label = "Block text"
    @State private var nativeSelection = NSRange(location: 0, length: 0)

    var body: some View {
        #if os(macOS) || os(iOS) || os(visionOS)
        VStack(alignment: .leading) {
            #if os(macOS)
            MacTextInput(model: model, address: address, label: label, selection: $nativeSelection).frame(minHeight: 32)
            #else
            UIKitTextInput(model: model, address: address, label: label, selection: $nativeSelection).frame(minHeight: 32)
            #endif
            if nativeSelection.length > 0 {
                HStack {
                    Button("Bold") { formatNative("bold") }
                    Button("Italic") { formatNative("italic") }
                    Button("Strikethrough") { formatNative("strikethrough") }
                    Button("Clear bold") { formatNative("bold", remove: true) }
                }
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
