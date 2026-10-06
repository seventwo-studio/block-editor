import BlockEditorCore
import SwiftUI

public struct ModernEditorLinkSuggestion: Identifiable, Sendable {
    public enum Availability: String, Sendable { case available, denied, unavailable }
    public let id: String
    public let entityType: String
    public let label: String
    public let availability: Availability
    public init(id: String, entityType: String, label: String, availability: Availability = .available) {
        self.id = id; self.entityType = entityType; self.label = label; self.availability = availability
    }
}

public struct ModernEditorHostActions {
    public var insertAsset: ((ModernInsertionDescriptor, ModernBlockBoundary) -> Void)?
    public var insertAssetSelection: ((ModernInsertionDescriptor, ModernBlockBoundary, ModernTextRange?) -> Void)?
    public var openReference: ((String) -> Void)?
    public var suggestLinks: ((String) async throws -> [ModernEditorLinkSuggestion])?
    public var copyBlockLink: ((NodeID) -> Void)?
    public var resolveMedia: ((NodeID, JSONValue) async throws -> ModernMediaPresentation)?
    public init(insertAsset: ((ModernInsertionDescriptor, ModernBlockBoundary) -> Void)? = nil,
                openReference: ((String) -> Void)? = nil, suggestLinks: ((String) async throws -> [ModernEditorLinkSuggestion])? = nil, copyBlockLink: ((NodeID) -> Void)? = nil,
                resolveMedia: ((NodeID, JSONValue) async throws -> ModernMediaPresentation)? = nil,
                insertAssetSelection: ((ModernInsertionDescriptor, ModernBlockBoundary, ModernTextRange?) -> Void)? = nil) {
        self.insertAsset = insertAsset; self.openReference = openReference; self.suggestLinks = suggestLinks; self.copyBlockLink = copyBlockLink
        self.resolveMedia = resolveMedia; self.insertAssetSelection = insertAssetSelection
    }
}

#if os(macOS) || os(iOS) || os(visionOS)
/// Public protocol-7 surface. Menus, outline, disclosure, drag and split previews
/// are personal state; every committed author action goes through ModernSession.
@MainActor public struct ModernBlockEditorView: View {
    @Bindable private var model: ModernEditorModel
    private let host: ModernEditorHostActions
    private let providers: ModernProviderController?
    @State private var outline = false
    @State private var focusMode = false
    @State private var selection: ModernNodeSelection?
    @State private var insertion: ModernBlockBoundary?
    @State private var insertionRange: ModernTextRange?
    @State private var query = ""
    @State private var collapsed = Set<NodeID>()
    @State private var splitPreview: [NodeID: Double] = [:]
    @State private var imagePreview: [NodeID: Double] = [:]
    @State private var imageTarget: [NodeID: ModernMediaTarget] = [:]
    @State private var linkRange: ModernTextRange?
    @State private var link = ""
    @State private var internalLink = false
    @State private var suggestions: [ModernEditorLinkSuggestion] = []
    @State private var suggestionsLoading = false
    @State private var paletteTarget: ModernSemanticTarget?
    @State private var textSpan: [ModernTextRange] = []
    @State private var formattingRanges: [ModernTextRange]?
    @State private var emptyText = ""
    @State private var drag: ModernNodeSelection?
    @State private var drop: ModernBlockBoundary?
    @State private var dropNode: NodeID?
    @State private var dropBefore = false
    @State private var viewportBounds = CGRect.zero
    @State private var rowBounds: [NodeID: CGRect] = [:]
    @State private var scrollRequest: NodeID?
    @State private var catalogIndex = 0
    @ScaledMetric(relativeTo: .body) private var textScale = 1.0
    public init(model: ModernEditorModel, host: ModernEditorHostActions = .init(), providers: ModernProviderController? = nil) {
        self.model = model; self.host = host; self.providers = providers
    }
    private var bodySize: Double { (model.document.appearance.fontSize == .small ? 15 : model.document.appearance.fontSize == .large ? 20 : 17) * textScale }
    private var pageWidth: Double { model.document.appearance.pageWidth == .wide ? 960 : 680 }
    public var body: some View {
        GeometryReader { geometry in
            ScrollViewReader { proxy in
                VStack(spacing: 0) {
                    if !focusMode { toolbar(proxy: proxy) }
                    ScrollView {
                        VStack(alignment: .leading, spacing: 16) {
                            field(model.session.titleField, label: "Document title", submit: titleEnter)
                                .id("title")
                            if model.document.blocks.isEmpty {
                                ModernEmptyTextInput(model: model)
                                if !focusMode { Button("Choose a starter") { openInsertion(.root) } }
                            }
                            collection(.root, width: max(1, min(pageWidth, geometry.size.width - 48)))
                            ForEach(Array(model.pendingInputs.keys).sorted { $0.uuidString < $1.uuidString }, id: \.self) { id in
                                if let draft = model.pendingInputs[id] {
                                    VStack(alignment: .leading) {
                                        Text("Input retained: \(draft.reason)").font(.caption)
                                        Text(draft.nativeText ?? draft.text).textSelection(.enabled)
                                        if model.isRestoredInput(id) { Button(draft.reason == "Target unavailable" ? "Recover as plain text" : "Retry original input") { run { try model.retryRestoredInput(id, allowingPlainTextFallback: draft.reason == "Target unavailable") } }.disabled(!model.isEditable) }
                                    }
                                }
                            }
                            if let error = model.error { Text(error).foregroundStyle(.red).textSelection(.enabled).accessibilityLabel("Editor error") }
                            if let providers {
                                ForEach(providers.records.filter { $0.status != .applied }, id: \.target.requestID) { record in
                                    HStack {
                                        Text(record.reason ?? record.status.rawValue).font(.caption)
                                        if record.result != nil { Button("Retry result") { Task { do { try await providers.retryResult(record.target) } catch { model.report(error) } } } }
                                        else if record.status != .pending { Button("Retry request") { run { _ = try providers.start(node: record.target.origin.node) } } }
                                    }
                                }
                            }
                        }.frame(maxWidth: pageWidth).padding(24).frame(maxWidth: .infinity, alignment: .top)
                    }
                    contextualTools
                }
                .font(.system(size: bodySize, design: model.document.appearance.fontFamily == .serif ? .serif : model.document.appearance.fontFamily == .monospace ? .monospaced : .default))
                .coordinateSpace(name: "modern-canvas")
                .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { viewportBounds = $0 }
                .onChange(of: scrollRequest) { _, node in if let node { withAnimation(.easeOut(duration: 0.1)) { proxy.scrollTo(node, anchor: .bottom) } } }
                #if !os(macOS)
                .sheet(isPresented: Binding(get: { insertion != nil }, set: { if !$0 { insertion = nil; insertionRange = nil } })) { insertionPicker }
                .sheet(isPresented: Binding(get: { formattingRanges != nil }, set: { if !$0 { formattingRanges = nil; model.restoreInteractionFocus() } })) { formattingPicker }
                #else
                .popover(isPresented: Binding(get: { insertion != nil && insertionRange == nil }, set: { if !$0 { insertion = nil; model.restoreInteractionFocus() } })) { insertionPicker }
                #endif
                .sheet(isPresented: Binding(get: { linkRange != nil }, set: { if !$0 { linkRange = nil; model.restoreInteractionFocus() } })) { linkEditor }
                .sheet(isPresented: Binding(get: { paletteTarget != nil }, set: { if !$0 { paletteTarget = nil; model.restoreInteractionFocus() } })) { palette }
                .onChange(of: model.document) { _, _ in detectSlash() }
            }
        }
    }
    private func run(_ action: () throws -> Void) { do { try action() } catch { model.report(error) } }
    private func command(_ action: (ModernSession) throws -> ModernFocusIntent?) { run { try model.perform(action) } }
    private func openInsertion(_ collection: NodeCollection, after: NodeID? = nil) {
        run { try? model.captureInteractionFocus(); insertion = try model.session.captureBoundary(in: collection, after: after); insertionRange = nil; query = "" }
    }
    private func detectSlash() {
        if host.suggestLinks != nil, linkRange == nil, !model.session.isComposing,
           let range = try? model.captureTextSelection(), range.start.field.name == "content",
           let value = try? model.session.text(in: range.start.field), let marker = value.range(of: "[[", options: .backwards), !value[marker.upperBound...].contains("]]") {
            run { try? model.captureInteractionFocus(); linkRange = try model.session.captureTextRange(in: range.start.field, start: value[..<marker.lowerBound].utf16.count, end: value.utf16.count); link = String(value[marker.upperBound...]); internalLink = true }
            return
        }
        guard insertion == nil, !model.session.isComposing,
              let range = try? model.captureTextSelection(), range.start.field != model.session.titleField,
              range.start.field.name == "content", let text = try? model.session.text(in: range.start.field), text.hasPrefix("/"), !text.contains("\n") else { return }
        run {
            try? model.captureInteractionFocus()
            insertionRange = try model.session.captureTextRange(in: range.start.field, start: 0, end: text.utf16.count)
            insertion = try model.session.captureInsertionBoundary(after: range.start.field)
            query = String(text.dropFirst())
        }
    }
    private func startWriting(_ text: String) {
        guard !text.isEmpty, model.document.blocks.isEmpty else { return }
        command { session in
            let result = try session.paste(ModernClipboard.multiline(text), at: .init(boundary: session.captureBoundary()))
            emptyText = ""; return result.focus
        }
    }
    private func titleEnter() -> Bool {
        guard !model.session.isComposing else { return false }
        command { session in
            if let first = try firstField(in: .root) { return .text(try session.position(in: first, offset: 0)) }
            return try session.insertBlock(ModernInsertionCatalog.block("paragraph", id: UUID().uuidString), at: session.captureBoundary()).focus
        }
        return true
    }
    private func enter(_ field: WritingField) -> Bool {
        guard !model.session.isComposing, !["code", "caption"].contains(field.name) else { return false }
        guard let range = try? model.captureTextSelection(), range.start.field == field else { return false }
        if field.name == "summary" {
            collapsed.remove(field.node)
            command { try $0.insertBlock(ModernInsertionCatalog.block("paragraph", id: UUID().uuidString), at: $0.captureBoundary(in: NodeCollection(owner: field.node, field: "children"))).focus }; return true
        }
        command { session in
            return try session.splitBlock(in: range, newBlockID: UUID().uuidString).focus
        }
        return true
    }
    @ViewBuilder private func field(_ field: WritingField, label: String, submit: (() -> Bool)? = nil) -> some View {
        #if os(macOS) || os(iOS) || os(visionOS)
        ModernTextInput(model: model, field: field, label: label, onSubmit: submit, onBoundary: { boundary(field, selector: $0) })
            #if os(macOS)
            .popover(isPresented: Binding(get: { insertion != nil && insertionRange?.start.field == field }, set: { if !$0 { insertion = nil; insertionRange = nil; model.restoreInteractionFocus() } }), arrowEdge: .bottom) { insertionPicker }
            .popover(isPresented: Binding(get: { formattingRanges?.last?.end.field == field }, set: { if !$0 { formattingRanges = nil; model.restoreInteractionFocus() } }), arrowEdge: .bottom) { formattingPicker }
            #endif
        #else
        TextField(label, text: Binding(get: { (try? model.session.text(in: field)) ?? "" }, set: { value in
            command { session in
                let old = try session.text(in: field)
                return .text(try session.replaceText(in: field, range: 0..<old.utf16.count, with: value))
            }
        }), axis: .vertical).disabled(!model.isEditable).onSubmit { _ = submit?() }
        #endif
    }
    private func boundary(_ field: WritingField, selector: String) -> Bool {
        guard !model.session.isComposing, let range = try? model.captureTextSelection(), range.start.field == field,
              let start = try? model.session.resolve(range.start).offset, let end = try? model.session.resolve(range.end).offset,
              start == end, let text = try? model.session.text(in: field) else { return false }
        let backward = ["deleteBackward:", "moveLeft:", "moveUp:", "moveLeftAndModifySelection:", "moveUpAndModifySelection:"].contains(selector)
        let forward = ["deleteForward:", "moveRight:", "moveDown:", "moveRightAndModifySelection:", "moveDownAndModifySelection:"].contains(selector)
        if selector == "insertTab:" || selector == "insertBacktab:" {
            if field.name == "code" {
                command { .text(try $0.replaceText(in: range, with: "\t")) }; return true
            }
            if let collection = try? model.session.parentCollection(of: field.node), ["items", "children"].contains(collection.field),
               let items = try? model.session.captureListNodes([field.node]) {
                command { try $0.listStructure(ModernListTarget(selection: items), action: selector == "insertBacktab:" ? .outdent : .indent).focus }; return true
            }
            if let collection = try? model.session.parentCollection(of: field.node), collection.field == "cells" {
                return navigate(field, direction: selector == "insertBacktab:" ? -1 : 1)
            }
            return false
        }
        guard (backward && start == 0) || (forward && start == text.utf16.count) else { return false }
        if selector.hasPrefix("delete"), field != model.session.titleField, field.name == "content" {
            run {
                let collection = try model.session.parentCollection(of: field.node), siblings = try model.session.nodes(in: collection)
                guard let index = siblings.firstIndex(of: field.node) else { return }
                if collection.field == "items" || collection.field == "children", let items = try? model.session.captureListNodes([field.node]), backward {
                    if text.isEmpty { command { try $0.splitBlock(in: range, newBlockID: UUID().uuidString).focus } }
                    else { command { try $0.listStructure(ModernListTarget(selection: items), action: .outdent).focus } }
                } else if (backward && index > 0) || (forward && index + 1 < siblings.count) {
                    let pair = backward ? [siblings[index - 1], field.node] : [field.node, siblings[index + 1]]
                    let captured = try model.session.captureNodes(pair)
                    command { try $0.mergeBlocks(captured).focus }
                }
            }
            // Rejected/lossy merges leave the captured document untouched.
            return true
        }
        if selector.contains("ModifySelection") {
            extendTextSelection(backward: backward); return true
        }
        return navigate(field, direction: backward ? -1 : 1)
    }
    private func extendTextSelection(backward: Bool) {
        run {
            let range = try model.captureTextSelection(), fields = try model.session.logicalFields(collapsed: collapsed, includingTitle: false)
            let endpoint = textSpan.isEmpty ? range.end : backward ? textSpan[0].end : textSpan.last!.end
            guard let index = fields.firstIndex(of: endpoint.field), fields.indices.contains(index + (backward ? -1 : 1)) else { return }
            let next = fields[index + (backward ? -1 : 1)], destination = try model.session.position(in: next, offset: backward ? model.session.text(in: next).utf16.count : 0)
            textSpan = try model.session.captureTextSpan(from: textSpan.isEmpty ? range.start : backward ? textSpan.last!.start : textSpan[0].start, to: destination, collapsed: collapsed)
        }
    }
    private func textTargets() throws -> [ModernTextRange] { textSpan.isEmpty ? [try model.captureTextSelection()] : textSpan }
    private func openPalette() {
        run { try? model.captureInteractionFocus(); if let selection { paletteTarget = ModernSemanticTarget(nodes: selection) } else { paletteTarget = ModernSemanticTarget(range: try model.captureTextSelection()) } }
    }
    private func semanticLabel(_ target: ModernSemanticTarget, kind: ModernSemanticKind) -> String {
        switch try? model.session.semanticState(target, kind: kind) { case .role(let role): role.capitalized; case .mixed: "Mixed"; default: "Default" }
    }
    private func reveal(_ node: NodeID) {
        var current = node
        while let parent = try? model.session.parentCollection(of: current), let owner = parent.owner { collapsed.remove(owner); current = owner }
    }
    private var palette: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Color").font(.headline)
            if let target = paletteTarget {
                ForEach([ModernSemanticKind.ink, .fill], id: \.rawValue) { kind in
                    Text(kind == .ink ? "Text color" : "Background").font(.headline)
                    Text(semanticLabel(target, kind: kind)).font(.caption)
                    HStack { ForEach(["neutral", "green", "blue", "purple", "amber", "red"], id: \.self) { role in
                        Button(role.capitalized) { command { try $0.setSemanticColor(target, kind: kind, role: role).focus } }
                    } }
                    Button("Reset") { command { try $0.setSemanticColor(target, kind: kind, role: nil).focus } }
                }
            }
            Button("Done") { paletteTarget = nil }
        }.padding(24)
    }
    private func navigate(_ field: WritingField, direction: Int) -> Bool {
        guard let fields = try? model.session.logicalFields(collapsed: collapsed), let index = fields.firstIndex(of: field), fields.indices.contains(index + direction) else { return false }
        let next = fields[index + direction]
        command { .text(try $0.position(in: next, offset: direction < 0 ? $0.text(in: next).utf16.count : 0)) }; return true
    }
    private func numeric(_ value: JSONValue?) -> Double? { if case .number(let number) = value { return number }; return nil }
    private func nodeValue(_ node: NodeID) -> JSONValue? {
        guard let address = try? model.session.address(of: node), let block = model.document.blocks.first(where: { $0.id == address.blockID }) else { return nil }
        return JSONValue.object(block.fields).value(at: address.path)
    }
    private func parentCollection(_ node: NodeID) throws -> NodeCollection {
        let address = try model.session.address(of: node)
        if address.path.isEmpty { return .root }
        let parent = try model.session.node(at: NodeAddress(address.blockID, path: Array(address.path.dropLast(2))))
        return NodeCollection(owner: parent, field: address.path[address.path.count - 2])
    }
    private func firstField(in collection: NodeCollection) throws -> WritingField? {
        for node in try model.session.nodes(in: collection) {
            for name in ["content", "summary", "code", "caption"] { if let field = try? model.session.field(node: node, name: name) { return field } }
            if let value = nodeValue(node) {
                for key in ["columns", "children", "items", "rows", "cells"] where value[key]?.array != nil {
                    if let field = try firstField(in: NodeCollection(owner: node, field: key)) { return field }
                }
            }
        }
        return nil
    }
    private func collection(_ collection: NodeCollection, width: Double) -> AnyView {
        AnyView(VStack(alignment: .leading, spacing: 12) {
            ForEach((try? model.session.nodes(in: collection)) ?? [], id: \.self) { node in row(node, collection: collection, width: width).id(node) }
        })
    }
    private func row(_ node: NodeID, collection: NodeCollection, width: Double) -> AnyView {
        guard let value = nodeValue(node) else { return AnyView(EmptyView()) }
        return AnyView(HStack(alignment: .top, spacing: 8) {
            #if !os(watchOS) && !os(tvOS)
            Button { select(node, extending: false) } label: { Image(systemName: "ellipsis") }.accessibilityLabel("Select block")
                .frame(minWidth: 36, minHeight: 44).contextMenu { blockActions(node) }
            #endif
            block(node, value: value, width: max(1, width - 44)).frame(maxWidth: .infinity, alignment: .leading)
        }.padding(4).background(selection?.nodes.contains(node) == true ? Color.accentColor.opacity(0.12) : .clear, in: RoundedRectangle(cornerRadius: 8))
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { rowBounds[node] = $0 }
            .overlay(alignment: dropBefore ? .top : .bottom) { if dropNode == node { Rectangle().fill(.tint).frame(height: 2) } }
            .onDrag { drag = (try? model.session.captureNodes(selection?.nodes.contains(node) == true ? selection!.nodes : [node])); return NSItemProvider(object: "modern-local-block" as NSString) }
            .onDrop(of: ["public.text"], delegate: ModernLocalDropDelegate(allowed: { drag != nil && model.isEditable }, preview: { location in
                run {
                    let siblings = try model.session.nodes(in: collection), index = siblings.firstIndex(of: node) ?? 0
                    let before = location.y < (rowBounds[node]?.height ?? 44) / 2
                    drop = try model.session.captureBoundary(in: collection, after: before ? (index > 0 ? siblings[index - 1] : nil) : node)
                    dropNode = node; dropBefore = before
                    if let frame = rowBounds[node] {
                        let y = frame.minY + location.y
                        if y > viewportBounds.maxY - 64, index + 1 < siblings.count { scrollRequest = siblings[index + 1] }
                        else if y < viewportBounds.minY + 64, index > 0 { scrollRequest = siblings[index - 1] }
                    }
                }
            }, cancel: { drop = nil; dropNode = nil }, commit: {
                guard let drag, let drop else { return false }
                command { try $0.move(ModernMoveTarget(selection: drag, boundary: drop)).focus }
                self.drag = nil; self.drop = nil; dropNode = nil; scrollRequest = nil; return true
            })))
    }
    private func block(_ node: NodeID, value: JSONValue, width: Double) -> AnyView {
        let type = value["type"]?.string ?? ""
        switch type {
        case "columns": return columns(node, value: value, width: width)
        case "table": return table(node)
        case "list": return list(node, style: value["style"]?.string ?? "unordered", width: width)
        case "toggle":
            return AnyView(VStack(alignment: .leading) {
                HStack {
                    Button { collapse(node) } label: { Image(systemName: collapsed.contains(node) ? "chevron.right" : "chevron.down") }.accessibilityLabel("Toggle contents")
                    if let field = try? model.session.field(node: node, name: "summary") { self.field(field, label: "Toggle title", submit: { enter(field) }) }
                }
                if !collapsed.contains(node) {
                    collection(NodeCollection(owner: node, field: "children"), width: width - 16).padding(.leading, 16)
                    Button("Add inside toggle") { openInsertion(NodeCollection(owner: node, field: "children"), after: (try? model.session.nodes(in: NodeCollection(owner: node, field: "children")))?.last) }
                }
            })
        case "image":
            return AnyView(VStack(alignment: .leading) {
                ModernResolvedMediaView(node: node, value: value, resolve: host.resolveMedia, open: host.openReference)
                    .frame(maxWidth: min(width, imagePreview[node] ?? numeric(value["width"]) ?? width))
                if let caption = try? model.session.field(node: node, name: "caption") { field(caption, label: "Image caption") }
                Slider(value: Binding(get: { imagePreview[node] ?? numeric(value["width"]) ?? width }, set: { imagePreview[node] = $0 }), in: 64...max(64, width), onEditingChanged: { editing in
                    if editing { imageTarget[node] = try? model.session.captureMediaTarget(node) }
                    else if let target = imageTarget.removeValue(forKey: node), let size = imagePreview.removeValue(forKey: node) {
                        let oldWidth = numeric(value["width"]) ?? width, oldHeight = numeric(value["height"]) ?? width
                        command { try $0.mediaProperties(target, metadata: ["width": .number(size.rounded()), "height": .number(max(1, (oldHeight * size / max(1, oldWidth)).rounded()))]).focus }
                    }
                }).accessibilityLabel("Image width").disabled(!model.isEditable)
                if let providers { Button("Resolve or replace image") { run { _ = try providers.start(node: node) } }.disabled(!model.isEditable) }

            })
        case "file", "embed":
            return AnyView(VStack(alignment: .leading) {
                ModernResolvedMediaView(node: node, value: value, resolve: host.resolveMedia, open: host.openReference)
                if let providers { Button("Replace \(type)") { run { _ = try providers.start(node: node) } }.disabled(!model.isEditable) }
            })
        case "divider": return AnyView(Divider())
        case "code":
            return AnyView(VStack(alignment: .leading) {
                HStack { Menu(value["language"]?.string ?? "Plain text") {
                    Button("Plain text") { run { let target = try model.session.captureCodeTarget(node); command { try $0.codeProperties(target, language: nil).focus } } }
                    ForEach(ModernCodeLanguages.supported, id: \.self) { language in Button(language) { run { let target = try model.session.captureCodeTarget(node); command { try $0.codeProperties(target, language: language).focus } } } }
                }.disabled(!model.isEditable); Spacer(); Button("Copy code") { run { if let f = try? model.session.field(node: node, name: "code") { let text = try model.session.text(in: f); let range = try model.session.captureTextRange(in: f, start: 0, end: text.utf16.count); _ = try model.clipboard.copy(ModernDeleteTarget(ranges: [range]), to: ModernNativeClipboard()) } } } }
                if let f = try? model.session.field(node: node, name: "code") { field(f, label: "Code") }
            }.padding(12).background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 8)))
        default:
            if let field = try? model.session.field(node: node) {
                return AnyView(self.field(field, label: type == "heading" ? "Heading" : "Block text", submit: { enter(field) })
                    .padding(.leading, type == "quote" || type == "callout" ? 12 : 0))
            }
            return AnyView(Text("Unsupported content preserved").font(.caption))
        }
    }
    private func list(_ node: NodeID, style: String, width: Double) -> AnyView {
        let items = (try? model.session.nodes(in: NodeCollection(owner: node, field: "items"))) ?? []
        return AnyView(VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(items.enumerated()), id: \.element) { index, item in listItem(item, style: style, number: index + 1, width: width) }
            if items.isEmpty {
                Button("Add list item") {
                    command { session in
                        let item = JSONValue.object(["id": .string(UUID().uuidString), "content": .array([]), "checked": .bool(false)])
                        return try session.paste(ModernClipboard(parts: [.node(value: item, kind: "item")]), at: .init(boundary: session.captureListBoundary(in: NodeCollection(owner: node, field: "items")))).focus
                    }
                }.disabled(!model.isEditable)
            }
        })
    }
    private func listItem(_ item: NodeID, style: String, number: Int, width: Double) -> AnyView {
        AnyView(VStack(alignment: .leading) {
            HStack(alignment: .top) {
                if style == "todo" {
                    Toggle("Completed", isOn: Binding(get: { nodeValue(item)?["checked"] == .bool(true) }, set: { checked in command { try $0.listStructure(ModernListTarget(selection: $0.captureListNodes([item])), action: .setChecked, checked: checked).focus } })).labelsHidden().disabled(!model.isEditable)
                } else { Text(style == "ordered" ? "\(number)." : "•").frame(width: 24) }
                if let f = try? model.session.field(node: item) { field(f, label: "List item", submit: { enter(f) }) }
            }
            ForEach((try? model.session.nodes(in: NodeCollection(owner: item, field: "children"))) ?? [], id: \.self) { child in listItem(child, style: style, number: 1, width: width - 16).padding(.leading, 16) }
        })
    }
    private func table(_ node: NodeID) -> AnyView {
        let rows = (try? model.session.nodes(in: NodeCollection(owner: node, field: "rows"))) ?? []
        return AnyView(ScrollView(.horizontal) {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(rows, id: \.self) { row in
                    HStack(spacing: 0) {
                        ForEach((try? model.session.nodes(in: NodeCollection(owner: row, field: "cells"))) ?? [], id: \.self) { cell in
                            if let f = try? model.session.field(node: cell) {
                                field(f, label: nodeValue(cell)?["header"] == .bool(true) ? "Table header" : "Table cell")
                                    .frame(width: 160).padding(8).overlay(Rectangle().stroke(.quaternary))
                                    .contextMenu { tableActions(node, row: row, cell: cell) }
                            }
                        }
                    }
                }
            }
        })
    }
    @ViewBuilder private func tableActions(_ table: NodeID, row: NodeID, cell: NodeID) -> some View {
        let captured = try? model.session.captureTableTarget(table: table, row: row, cell: cell)
        let cellCount = (try? model.session.nodes(in: NodeCollection(owner: row, field: "cells")).count) ?? 0
        let rowCount = (try? model.session.nodes(in: NodeCollection(owner: table, field: "rows")).count) ?? 0
        ForEach(ModernTableAction.allCases, id: \.rawValue) { action in
            Button(action.rawValue) {
                command { session in
                    guard let target = captured else { throw EditorError.invalidPath }
                    let count = action == .insertRow ? cellCount + 1 : action == .insertColumn ? rowCount : 0
                    return try session.tableStructure(target, action: action, newIDs: (0..<count).map { _ in UUID().uuidString }, header: action == .setHeader ? nodeValue(cell)?["header"] != .bool(true) : nil).focus
                }
            }
        }
    }
    private func columns(_ node: NodeID, value: JSONValue, width: Double) -> AnyView {
        let containers = (try? model.session.nodes(in: NodeCollection(owner: node, field: "columns"))) ?? []
        guard containers.count == 2 else { return AnyView(Text("Incompatible column layout preserved")) }
        let usable = width - 24, minimum = bodySize * 20, stacked = usable < minimum * 2
        let stored = (numeric(value["splitBasisPoints"]) ?? 5000) / 10000, preview = splitPreview[node] ?? stored
        let rendered = max(minimum / max(1, usable), min(1 - minimum / max(1, usable), preview))
        return AnyView(VStack(alignment: .leading, spacing: 12) {
            let layout = stacked ? AnyLayout(VStackLayout(alignment: .leading, spacing: 12)) : AnyLayout(HStackLayout(alignment: .top, spacing: 24))
            layout {
                ForEach(Array(containers.enumerated()), id: \.element) { index, container in
                    let columnWidth = stacked ? width : usable * (index == 0 ? rendered : 1 - rendered)
                    collection(NodeCollection(owner: container, field: "children"), width: columnWidth).frame(width: columnWidth)
                }
            }
            Slider(value: Binding(get: { splitPreview[node] ?? stored }, set: { splitPreview[node] = $0 }), in: 0.1...0.9, onEditingChanged: { active in
                if !active, let preview = splitPreview.removeValue(forKey: node) { command { try $0.resizeColumns(ModernColumnTarget(layout: node), splitBasisPoints: Int((preview * 10000).rounded())).focus } }
            }).accessibilityLabel("Column split").disabled(!model.isEditable)
            HStack {
                ForEach(Array(containers.enumerated()), id: \.element) { index, container in Button("Add to column \(index + 1)") { openInsertion(NodeCollection(owner: container, field: "children"), after: (try? model.session.nodes(in: NodeCollection(owner: container, field: "children")))?.last) } }
                Button("Remove columns") { command { try $0.removeColumns(ModernColumnTarget(layout: node)).focus } }
            }.font(.caption)
        })
    }
    private func collapse(_ node: NodeID) {
        if collapsed.contains(node) { collapsed.remove(node); return }
        // Move focus to the disclosure title before unmounting its descendants.
        command { session in
            guard let field = try? session.field(node: node, name: "summary") else { return nil }
            return .text(try session.position(in: field, offset: 0))
        }
        collapsed.insert(node)
    }
    private func select(_ node: NodeID, extending: Bool) {
        run {
            let siblings = try model.session.nodes(in: parentCollection(node))
            if extending, let first = selection?.nodes.first, let a = siblings.firstIndex(of: first), let b = siblings.firstIndex(of: node) { selection = try model.session.captureNodes(Array(siblings[min(a, b)...max(a, b)])) }
            else { selection = try model.session.captureNodes([node]) }
        }
    }
    @ViewBuilder private func blockActions(_ node: NodeID) -> some View {
        Button("Select") { select(node, extending: false) }
        Button("Extend selection") { select(node, extending: true) }
        Button("Insert after") { run { openInsertion(try parentCollection(node), after: node) } }
        Button("Copy link") { host.copyBlockLink?(node) }.disabled(host.copyBlockLink == nil)
        Button("Duplicate") { select(node, extending: false); duplicateSelection() }
        Button("Delete", role: .destructive) { select(node, extending: false); deleteSelection() }
    }
    private func duplicateSelection() {
        guard let selection, let last = selection.nodes.last else { return }
        command { session in try session.duplicate(ModernDuplicateTarget(selection: selection, boundary: session.captureBoundary(in: parentCollection(last), after: last)), newBlockIDs: selection.nodes.map { _ in UUID().uuidString }).focus }
    }
    private func deleteSelection() {
        guard let selection else { return }
        command { try $0.delete(ModernDeleteTarget(nodes: selection)).focus }; self.selection = nil
    }
    private func moveSelection(down: Bool) {
        guard let selection, let first = selection.nodes.first else { return }
        command { session in
            let collection = try parentCollection(first), siblings = try session.nodes(in: collection)
            guard let index = siblings.firstIndex(of: first) else { throw EditorError.invalidPath }
            let after: NodeID?
            if down { guard index + selection.nodes.count < siblings.count else { return nil }; after = siblings[index + selection.nodes.count] }
            else { guard index > 0 else { return nil }; after = index > 1 ? siblings[index - 2] : nil }
            return try session.move(ModernMoveTarget(selection: selection, boundary: session.captureBoundary(in: collection, after: after))).focus
        }
    }
    private var contextualTools: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 12) {
                if let selection {
                    Text("\(selection.nodes.count) selected")
                    Button("Move up") { moveSelection(down: false) }; Button("Move down") { moveSelection(down: true) }
                    Menu("Convert") {
                        ForEach(["paragraph", "heading", "quote", "callout", "list", "code"], id: \.self) { type in
                            Button(type.capitalized) { command { try $0.convertBlocks(selection, to: WritingBlockTarget(type: type)).focus } }
                        }
                    }
                    Menu("Move to") {
                        Button("Document end") { command { try $0.move(ModernMoveTarget(selection: selection, boundary: $0.captureBoundary(after: $0.nodes().last))).focus } }
                        ForEach((try? model.session.nodes()) ?? [], id: \.self) { node in
                            if nodeValue(node)?["type"] == .string("columns") {
                                ForEach(Array(((try? model.session.nodes(in: NodeCollection(owner: node, field: "columns"))) ?? []).enumerated()), id: \.element) { index, container in
                                    Button("Column \(index + 1)") { command { session in let collection = NodeCollection(owner: container, field: "children"); return try session.move(ModernMoveTarget(selection: selection, boundary: session.captureBoundary(in: collection, after: session.nodes(in: collection).last))).focus } }
                                }
                            }
                        }
                    }
                    Button("Duplicate") { duplicateSelection() }; Button("Delete") { deleteSelection() }
                    Button("Copy link") { if let node = selection.nodes.first { host.copyBlockLink?(node) } }.disabled(host.copyBlockLink == nil)
                    Button("Color") { openPalette() }
                    Button("Cancel selection") { self.selection = nil; command { try $0.resolvedLocalSelection()?.focus } }
                } else {
                    Button("Insert") { run { try? model.captureInteractionFocus(); if let range = try? model.captureTextSelection() { insertion = try model.session.captureInsertionBoundary(after: range.start.field) } else { insertion = try model.session.captureBoundary(after: model.session.nodes().last) }; insertionRange = nil; query = "" } }
                    Button("Format") { run { try model.captureInteractionFocus(); formattingRanges = try textTargets() } }
                    Button("Link") { run { try? model.captureInteractionFocus(); linkRange = try model.captureTextSelection(); link = ""; internalLink = false } }
                    Button("Undo") { run { try model.undo() } }.disabled(!model.canUndo)
                    Menu("More") {
                        Button("Redo") { run { try model.redo() } }.disabled(!model.canRedo)
                        Button("Color") { openPalette() }
                        Button("Extend text selection") { extendTextSelection(backward: false) }
                        Button("Copy selection") { run { _ = try model.clipboard.copy(ModernDeleteTarget(ranges: textTargets()), to: ModernNativeClipboard()) } }
                        Button("Delete text selection") { run { let target = ModernDeleteTarget(ranges: try textTargets()); command { try $0.delete(target).focus }; textSpan = [] } }
                    }
                    if !textSpan.isEmpty { Text("Text across \(textSpan.count) fields"); Button("Cancel text selection") { textSpan = [] } }
                    if focusMode { Button("Leave focus mode") { focusMode = false } }
                }
            }.buttonStyle(.bordered).padding(12)
        }.background(.bar).disabled(!model.isEditable || model.session.isComposing)
    }
    private var formattingPicker: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(["bold", "italic", "strikethrough", "code"], id: \.self) { mark in
                let state = formattingRanges.flatMap { try? model.session.markState(in: $0, type: mark) } ?? .off
                Button("\(mark.capitalized)\(state == .on ? " ✓" : state == .mixed ? " — Mixed" : "")") {
                    guard let captured = formattingRanges else { return }
                    command { try $0.format(in: captured, markType: mark, mark: state == .on ? nil : .object(["type": .string(mark)])).focus }
                    formattingRanges = nil
                }
            }
            Button("Cancel") { formattingRanges = nil; model.restoreInteractionFocus() }
        }.padding(24).frame(minWidth: 240).disabled(!model.isEditable || model.session.isComposing)
    }
    private var insertionPicker: some View {
        VStack(alignment: .leading, spacing: 12) {
            TextField("Search blocks", text: $query).onChange(of: query) { _, _ in catalogIndex = 0 }
                .onSubmit { let values = ModernInsertionCatalog.search(query).filter { model.session.allowedBlockTypes?.contains($0.blockType) ?? true }; if values.indices.contains(catalogIndex) { insert(values[catalogIndex]) } }
                #if os(macOS)
                .onMoveCommand { direction in let count = ModernInsertionCatalog.search(query).filter { model.session.allowedBlockTypes?.contains($0.blockType) ?? true }.count; if direction == .down { catalogIndex = min(max(0, count - 1), catalogIndex + 1) }; if direction == .up { catalogIndex = max(0, catalogIndex - 1) } }
                #endif
            ScrollView {
                ForEach(Array(ModernInsertionCatalog.search(query).filter { model.session.allowedBlockTypes?.contains($0.blockType) ?? true }.enumerated()), id: \.element.id) { index, descriptor in
                    Button { insert(descriptor) } label: { VStack(alignment: .leading) { Text(descriptor.title); Text(descriptor.description).font(.caption).foregroundStyle(.secondary) }.frame(maxWidth: .infinity, alignment: .leading).padding(8).background(index == catalogIndex ? Color.accentColor.opacity(0.12) : .clear, in: RoundedRectangle(cornerRadius: 8)) }
                }
            }
            Button("Cancel") { insertion = nil; insertionRange = nil; model.restoreInteractionFocus() }
        }.padding(24).frame(minWidth: 280, idealHeight: 440)
    }
    private func insert(_ descriptor: ModernInsertionDescriptor) {
        guard let insertion else { return }
        if descriptor.requiresHost {
            if let action = host.insertAssetSelection { action(descriptor, insertion, insertionRange) }
            else { host.insertAsset?(descriptor, insertion) }
            self.insertion = nil; insertionRange = nil; return
        }
        command { session in
            if descriptor.id == "columns" {
                let layout = JSONValue.object(["id": .string(UUID().uuidString), "type": .string("columns"), "splitBasisPoints": .number(5000), "columns": .array((0..<2).map { _ in .object(["id": .string(UUID().uuidString), "children": .array([])]) })])
                let result = try insertionRange.map { range in try session.paste(ModernClipboard(parts: [.node(value: layout, kind: "block")]), at: .init(boundary: insertion, selection: ModernDeleteTarget(ranges: [range])), focusInserted: true) } ?? session.createColumns(.init(boundary: insertion), layout: layout)
                self.insertion = nil; insertionRange = nil; return result.focus
            }
            let count = descriptor.blockType == "list" ? 1 : descriptor.blockType == "table" ? 6 : 0
            let block = try ModernInsertionCatalog.block(descriptor.id, id: UUID().uuidString, childIDs: (0..<count).map { _ in UUID().uuidString })
            let result: ModernStructuralResult
            if let insertionRange { result = try session.paste(ModernClipboard(parts: [.node(value: .object(block.fields), kind: "block")]), at: .init(boundary: insertion, selection: ModernDeleteTarget(ranges: [insertionRange])), focusInserted: true) }
            else { result = try session.insertBlock(block, at: insertion) }
            self.insertion = nil; insertionRange = nil; return result.focus
        }
    }
    private var linkEditor: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Link").font(.headline); TextField(internalLink ? "Search internal links" : "URL", text: $link)
            if internalLink {
                if suggestionsLoading { ProgressView("Finding links…") }
                ForEach(suggestions) { suggestion in
                    Button(suggestion.label + (suggestion.availability == .available ? "" : " — " + suggestion.availability.rawValue)) {
                        guard let target = linkRange else { return }
                        command { session in
                            let value: JSONValue = .object(["type": .string("entity-ref"), "entityId": .string(suggestion.id), "entityType": .string(suggestion.entityType), "label": .string(suggestion.label)])
                            return try session.paste(ModernClipboard(parts: [.inline([value])]), at: .init(range: target)).focus
                        }; linkRange = nil
                    }.disabled(suggestion.availability != .available)
                }
                if !suggestionsLoading && suggestions.isEmpty { Text("No available matches").font(.caption) }
            } else {
                Button("Apply link") { guard let target = linkRange else { return }; command { try $0.setLink(in: target, href: link).focus }; linkRange = nil }
                Button("Remove link") { guard let target = linkRange else { return }; command { try $0.setLink(in: target, href: nil).focus }; linkRange = nil }
                Button("Find internal link") { internalLink = true }.disabled(host.suggestLinks == nil)
            }
            Button("Cancel") { let target = linkRange; linkRange = nil; if let target { command { _ in .text(target.end) } } }
        }.padding(24).task(id: link + String(internalLink)) {
            guard internalLink, let suggest = host.suggestLinks else { suggestions = []; return }
            suggestionsLoading = true
            do { let results = try await suggest(link); if !Task.isCancelled { suggestions = results } }
            catch { if !Task.isCancelled { suggestions = []; model.report(error) } }
            if !Task.isCancelled { suggestionsLoading = false }
        }
    }
    private func toolbar(proxy: ScrollViewProxy) -> some View {
        HStack {
            Menu("Outline") {
                ForEach(headings(), id: \.0) { node, title in Button(title.isEmpty ? "Heading" : title) { reveal(node); proxy.scrollTo(node, anchor: .top); command { session in guard let f = try? session.field(node: node) else { return nil }; return .text(try session.position(in: f, offset: 0)) } } }
            }
            Button("Focus") { focusMode = true }
            Spacer()
            Menu("Appearance") {
                ForEach(["sans", "serif", "monospace"], id: \.self) { value in appearance("fontFamily", value) }
                ForEach(["small", "default", "large"], id: \.self) { value in appearance("fontSize", value) }
                ForEach(["readable", "wide"], id: \.self) { value in appearance("pageWidth", value) }
            }
        }.padding(12).background(.bar)
    }
    private func appearance(_ field: String, _ value: String) -> some View { Button(value.capitalized) { command { try $0.setAppearance(field: field, value: value); return nil } } }
    private func headings() -> [(NodeID, String)] {
        var result: [(NodeID, String)] = []
        func visit(_ collection: NodeCollection) {
            for node in (try? model.session.nodes(in: collection)) ?? [] {
                guard let value = nodeValue(node) else { continue }
                if value["type"] == .string("heading") { result.append((node, (try? model.session.text(in: model.session.field(node: node))) ?? "")) }
                for key in ["columns", "children"] where value[key]?.array != nil { visit(NodeCollection(owner: node, field: key)) }
            }
        }
        visit(.root); return result
    }
}

#endif
