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
                #if os(macOS) || os(iOS) || os(visionOS)
                NativeInsertMenu(model: model, after: model.document.blocks.last?.id)
                #else
                Button("Paragraph", systemImage: "plus") {
                    model.perform { try $0.insert(.paragraph(id: UUID().uuidString), after: model.document.blocks.last?.id) }
                }
                #endif
            }
            if let error = model.error { Text(error).foregroundStyle(.red).accessibilityLabel("Editor error: \(error)") }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    ForEach(model.document.blocks) { block in
                        #if os(macOS) || os(iOS) || os(visionOS)
                        HStack(alignment: .top, spacing: 4) {
                            Menu { NativeNodeActions(model: model, address: NodeAddress(block.id)) } label: {
                                Image(systemName: "ellipsis").frame(width: 24, height: 32)
                            }.accessibilityLabel("Block actions")
                            NativeBlockContent(model: model, rootID: block.id, block: block, path: [], asset: asset)
                        }.accessibilityElement(children: .contain)
                            .id(nativeNodeIdentity(model: model, address: NodeAddress(block.id)))
                        #else
                        NativeBlockContent(model: model, rootID: block.id, block: block, path: [], asset: asset)
                            .contextMenu { NativeNodeActions(model: model, address: NodeAddress(block.id)) }
                            .accessibilityElement(children: .contain)
                            .id(nativeNodeIdentity(model: model, address: NodeAddress(block.id)))
                        #endif
                    }
                }.padding()
            }
        }.id(ObjectIdentifier(model))
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
    @State private var inputAddress: TextAddress
    @State private var nativeSelection = NSRange(location: 0, length: 0)

    init(model: EditorModel, address: TextAddress, nodes: [JSONValue], label: String = "Block text") {
        self.model = model; self.address = address; self.nodes = nodes; self.label = label
        _inputAddress = State(initialValue: (try? model.session.position(at: address, offset: 0).address) ?? address)
    }

    var body: some View {
        #if os(macOS) || os(iOS) || os(visionOS)
        VStack(alignment: .leading) {
            #if os(macOS)
            MacTextInput(model: model, address: inputAddress, label: label, selection: $nativeSelection).frame(minHeight: 32)
            #else
            UIKitTextInput(model: model, address: inputAddress, label: label, selection: $nativeSelection).frame(minHeight: 32)
            #endif
            if nativeSelection.length > 0 {
                HStack {
                    Button("Bold") { formatNative("bold") }
                    Button("Italic") { formatNative("italic") }
                    Button("Strikethrough") { formatNative("strikethrough") }
                    Button("Code") { formatNative("code") }
                    Menu("Remove formatting") {
                        ForEach(["bold", "italic", "strikethrough", "code", "link"], id: \.self) { type in
                            Button(type.capitalized) { formatNative(type, remove: true) }
                        }
                    }
                }
            }
        }
        #elseif os(watchOS) || os(tvOS)
        PlatformTextField(model: model, address: address)
        #endif
    }
    private func formatNative(_ type: String, remove: Bool = false) {
        // Resolve identity before composition commit can release queued remote moves.
        do {
            let selection = try NativeFormattingSelection(session: model.session, address: inputAddress, range: nativeSelection)
            model.perform { try selection.apply(in: $0, type: type, remove: remove) }
        } catch { model.performInput { _ in throw error } }
    }
}
#endif
