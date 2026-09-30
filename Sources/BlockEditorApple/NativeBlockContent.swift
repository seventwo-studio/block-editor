#if canImport(SwiftUI)
import BlockEditorCore
import SwiftUI

/// Nested fields retain the containing root ID and stable child-ID path.
@MainActor struct NativeBlockContent: View {
    let model: EditorModel
    let rootID: String
    let block: Block
    let path: [String]
    let asset: (Block) -> AnyView
    @State private var expanded = true

    var body: some View {
        switch block.type {
        case "paragraph":
            inline("content")
        case "heading": inline("content").accessibilityAddTraits(.isHeader)
        case "quote":
            HStack(alignment: .top) {
                Rectangle().fill(.secondary).frame(width: 3)
                inline("content")
            }
        case "callout":
            HStack(alignment: .top) {
                Image(systemName: "info.circle").accessibilityHidden(true)
                inline("content")
            }.padding(12).background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
        case "list":
            NativeListItems(model: model, rootID: rootID, items: block.fields["items"]?.array ?? [],
                            path: path + ["items"], style: block.fields["style"]?.string ?? "unordered")
        case "toggle":
            VStack(alignment: .leading) {
                HStack(alignment: .top) {
                    Button(expanded ? "Collapse toggle" : "Expand toggle", systemImage: expanded ? "chevron.down" : "chevron.right") {
                        expanded.toggle()
                    }.labelStyle(.iconOnly)
                    inline("summary", label: "Toggle title")
                }
                if expanded {
                    ForEach(block.fields["children"]?.array ?? [], id: \.selfID) { child in
                        if let fields = child.object, let childBlock = try? Block(fields: fields) {
                            NativeBlockContent(model: model, rootID: rootID, block: childBlock,
                                               path: path + ["children", childBlock.id], asset: asset)
                        }
                    }.padding(.leading, 20)
                }
            }
        case "table":
            ScrollView(.horizontal) {
                Grid(alignment: .topLeading, horizontalSpacing: 12, verticalSpacing: 8) {
                    ForEach(Array((block.fields["rows"]?.array ?? []).enumerated()), id: \.element.selfID) { rowIndex, row in
                        GridRow {
                            ForEach(Array((row["cells"]?.array ?? []).enumerated()), id: \.element.selfID) { cellIndex, cell in
                                #if os(watchOS) || os(tvOS)
                                Text(plainText(cell["content"]?.array ?? []))
                                #else
                                InlineField(model: model,
                                            address: TextAddress(rootID, path: path + ["rows", row.selfID, "cells", cell.selfID, "content"]),
                                            nodes: cell["content"]?.array ?? [], label: "Row \(rowIndex + 1), column \(cellIndex + 1)")
                                    .frame(minWidth: 140)
                                    .padding(8)
                                    .overlay(Rectangle().stroke(.separator, lineWidth: 1))
                                #endif
                            }
                        }
                    }
                }
            }
        case "divider": Divider()
        case "image": asset(block)
        case "code": plain("code", label: "Code")
        case "math": plain("expression", label: "Math")
        case "embed": Text(block.fields["title"]?.string ?? block.fields["url"]?.string ?? "Embedded content")
        default: Label("\(block.type.capitalized) content preserved", systemImage: "doc")
        }
    }
    private func inline(_ field: String, label: String = "Block text") -> some View {
        InlineField(model: model, address: TextAddress(rootID, path: path + [field]),
                    nodes: block.fields[field]?.array ?? [], label: label)
    }
    private func plain(_ field: String, label: String) -> some View {
        PlainField(model: model, address: TextAddress(rootID, path: path + [field]),
                   text: block.fields[field]?.string ?? "", label: label)
    }
}

@MainActor private struct NativeListItems: View {
    let model: EditorModel
    let rootID: String
    let items: [JSONValue]
    let path: [String]
    let style: String
    var body: some View {
        ForEach(Array(items.enumerated()), id: \.element.selfID) { index, item in
            VStack(alignment: .leading) {
                HStack(alignment: .top) {
                    if style == "todo" {
                        Toggle("Completed", isOn: Binding(get: { item["checked"] == .bool(true) }, set: { value in
                            model.perform { try $0.setField(blockID: rootID, path: path + [item.selfID, "checked"], value: .bool(value)) }
                        })).labelsHidden()
                    } else {
                        Text(style == "ordered" ? "\(index + 1)." : "•").accessibilityHidden(true)
                    }
                    InlineField(model: model, address: TextAddress(rootID, path: path + [item.selfID, "content"]),
                                nodes: item["content"]?.array ?? [], label: "List item")
                }
                if let children = item["children"]?.array, !children.isEmpty {
                    NativeListItems(model: model, rootID: rootID, items: children,
                                    path: path + [item.selfID, "children"], style: style)
                        .padding(.leading, 20)
                }
            }
        }
    }
}
#endif
