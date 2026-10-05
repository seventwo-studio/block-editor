import BlockEditorCore
import Foundation
import Observation

/// Isolated interaction study. Body commands use the existing protocol-6 engine.
/// Title, layout membership/split and viewing preferences are local review state;
/// they are never exported as a modern shared document or used by production hosts.
@MainActor @Observable final class ReviewModel {
    var document: BlockEditorCore.Document
    var title = "Studio field notes"
    var selected: [NodeID] = []
    var activeField: ReviewField?
    var activeRange = NSRange(location: 0, length: 0)
    var requestedFocus: String?
    var pickerTarget: NodeID?
    var pickerOpen = false
    var pickerQuery = ""
    var pickerIndex = 0
    var slashRange: WritingTextRange?
    var error: String?
    var showOutline = false
    var focusMode = false
    #if os(macOS)
    var touchTools = false
    #else
    var touchTools = true
    #endif
    var selectionMode = false
    var hoveredRoot: NodeID?
    var expandedToggles: Set<String> = []
    var largeText = false
    var dark = false
    var layouts: [ReviewLayout] = []
    var activeLayoutID: String?
    var layout: ReviewLayout? { layouts.first { $0.id == activeLayoutID } ?? layouts.last }
    var showResizePanel = false
    var splitPreviewLayoutID: String?
    var splitPreview: Double?
    var trace: [String] = []
    var jumpTarget: String?
    var jumpSerial = 0
    var actionRevision = 0
    @ObservationIgnored var session: WritingSession
    @ObservationIgnored private var serial = 100

    init(fixture: Data) throws {
        let mixed = try JSONDecoder().decode([Block].self, from: fixture)
        let intro = try Block.paragraph(id: "intro", text: "Start with the document. Select words to format, or type / to insert a block.")
        let heading = try Block(fields: ["id": .string("section"), "type": .string("heading"), "level": .number(2), "content": .array([textNode("Structured notes")])])
        let first = try Block.paragraph(id: "first", text: "First thought")
        let second = try Block.paragraph(id: "second", text: "Second thought")
        let image = try Block(fields: ["id": .string("media"), "type": .string("image"), "src": .string("asset://review-coast"), "alt": .string("Coastline illustration"), "caption": .array([textNode("A local visual reference, with no network fetch.")])])
        let tail = try (1...60).map { index in
            try Block.paragraph(id: "note-\(index)", text: "Field note \(index). Longer documents keep a readable rhythm and stable navigation while the tools stay near the action.")
        }
        let code = try Block(fields:["id":.string("review-code"),"type":.string("code"),"language":.string("swift"),"code":.string("\tlet coast = \"世界😀\"\n    print(coast)  \n")])
        let closing = try Block(fields:["id":.string("closing"),"type":.string("heading"),"level":.number(2),"content":.array([textNode("Closing notes")])])
        let baseline = try BlockEditorCore.Document(blocks: [intro, first, second, heading] + mixed + [image,code] + tail + [closing])
        session = try WritingSession(documentID: "st121-review", actorID: "review", epoch: UUID().uuidString, document: baseline, protocolVersion: 6)
        document = baseline
        session.onChange = { [weak self] value, _ in self?.document = value }
    }
    var bodySize: Double { largeText ? 20 : 17 }
    var orderedOrigins: [NodeID] { (try? session.collectionNodes(in: .root)) ?? [] }
    var options: [String] { ["Paragraph", "Heading", "Bulleted list", "Checklist", "Toggle", "Quote", "Callout", "Divider", "Code", "Table", "Two columns"].filter { pickerQuery.isEmpty || $0.localizedCaseInsensitiveContains(pickerQuery) } }
    func identity(_ block: Block) -> NodeID { (try? session.node(at: NodeAddress(block.id))) ?? .baseline(blockID: block.id, path: []) }
    func value(_ field: ReviewField) -> JSONValue? {
        guard let address = try? session.address(of: field.node), let block = document.blocks.first(where: { $0.id == address.blockID }) else { return nil }
        return block.value(at: address.path + [field.name])
    }
    func text(_ field: ReviewField) -> String { (try? session.text(at: session.textAddress(of: field.node, field: field.name))) ?? "" }
    func record(_ action: String) { actionRevision += 1; trace.append(action); if trace.count > 100 { trace.removeFirst() } }
    func navigate(to id: String) { jumpTarget = id; jumpSerial += 1; record("Navigate outline to \(id)") }
    func isActive(_ rootID:String) -> Bool { activeField.flatMap { try? session.address(of:$0.node).blockID } == rootID }
    var reviewRows: [ReviewRow] {
        let members = Set(layouts.flatMap(\.members))
        var rows:[ReviewRow] = []
        for block in document.blocks {
            let node = identity(block)
            rows += layouts.filter { $0.leading == node }.map { .columns($0.id) }
            if !members.contains(node) { rows.append(.block(block.id)) }
        }
        rows += layouts.filter { $0.leading == nil || !orderedOrigins.contains($0.leading!) }.map { .columns($0.id) }
        return rows
    }
    func columnBlocks(_ nodes:[NodeID]) -> [Block] { nodes.compactMap { origin in document.blocks.first { identity($0) == origin } } }
    func chooseLayout(_ id:String) { activeLayoutID = id; record("Choose column layout") }
    func submitTitle() {
        guard let first = orderedOrigins.first else { return }
        activeField = ReviewField(node:first,name:"content"); activeRange = NSRange(location:0,length:0)
        requestedFocus = activeField?.key; record("Title Enter to body")
    }
    func perform(_ name: String, _ operation: () throws -> Void) {
        do { try operation(); error = nil; record(name) } catch { self.error = String(describing: error); record("Rejected \(name)") }
    }
    func update(_ field: ReviewField, text new: String, range: NSRange) {
        guard let address = try? session.textAddress(of: field.node, field: field.name) else { error = "The edited origin no longer exists"; return }
        let old = text(field)
        if old != new {
            let before = Array(old.unicodeScalars), after = Array(new.unicodeScalars)
            var prefix = 0, suffix = 0
            while prefix < min(before.count, after.count), before[prefix] == after[prefix] { prefix += 1 }
            while suffix < min(before.count, after.count)-prefix, before[before.count-1-suffix] == after[after.count-1-suffix] { suffix += 1 }
            let lower = String(String.UnicodeScalarView(before.prefix(prefix))).utf16.count
            let upper = old.utf16.count-String(String.UnicodeScalarView(before.suffix(suffix))).utf16.count
            let replacement = String(String.UnicodeScalarView(after[prefix..<(after.count-suffix)]))
            perform("Edit \(field.key)") { _ = try session.replaceText(at: address, range: lower..<upper, with: replacement) }
        }
        activeField = field; activeRange = range; selected = []
        detectSlash(field)
    }
    func select(_ node: NodeID, extend: Bool = false) {
        if extend, let anchor = selected.first, let a = orderedOrigins.firstIndex(of: anchor), let b = orderedOrigins.firstIndex(of: node) { selected = Array(orderedOrigins[min(a,b)...max(a,b)]) }
        else if selected.contains(node) { selected.removeAll { $0 == node } }
        else { selected.append(node); selected = orderedOrigins.filter { selected.contains($0) } }
        if let containing = layouts.first(where: { $0.members.contains(node) }) { activeLayoutID = containing.id }
        record("Select \(selected.count) blocks")
    }
    func format(_ type: String) {
        guard let field = activeField, activeRange.length > 0 else { return }
        perform("Format \(type)") {
            let address = try session.textAddress(of: field.node, field: field.name)
            try session.format(at: address, range: activeRange.location..<(activeRange.location+activeRange.length), markType: type, mark: .object(["type": .string(type)]))
            requestedFocus = field.key
        }
    }
    func convert(_ node: NodeID, to type: String) {
        perform("Convert \(type)") {
            let address = try session.textAddress(of: node)
            _ = try session.convertBlock(at: address, offset: 0, to: WritingBlockTarget(type: type, level: type == "heading" ? 2 : nil))
            requestedFocus = ReviewField(node: node, name: "content").key
        }
    }
    func moveSelected(down: Bool) {
        guard let first = selected.first, let last = selected.last, let a = orderedOrigins.firstIndex(of: first), let b = orderedOrigins.firstIndex(of: last) else { return }
        if let index = layouts.firstIndex(where:{ Set(selected).isSubset(of:Set($0.first)) || Set(selected).isSubset(of:Set($0.second)) }) {
            let isSecond = Set(selected).isSubset(of:Set(layouts[index].second))
            var nodes = isSecond ? layouts[index].second : layouts[index].first
            let moving = nodes.filter { selected.contains($0) }
            guard let firstIndex = nodes.firstIndex(where:{selected.contains($0)}), let lastIndex = nodes.lastIndex(where:{selected.contains($0)}) else { return }
            let destination = down ? min(nodes.count-moving.count, firstIndex+1) : max(0,firstIndex-1)
            guard (down && lastIndex < nodes.count-1) || (!down && firstIndex > 0) else { return }
            nodes.removeAll { selected.contains($0) }; nodes.insert(contentsOf:moving,at:destination)
            if isSecond { layouts[index].second = nodes } else { layouts[index].first = nodes }
            requestedFocus = activeField?.key; record(down ? "Move range down" : "Move range up"); return
        }
        let order = orderedOrigins
        if down && b+1 < order.count { perform("Move range down") { _ = try session.move(WritingSelection(nodes: selected), into: .root, after: order[b+1]) } }
        if !down && a > 0 { perform("Move range up") { _ = try session.move(WritingSelection(nodes: selected), into: .root, after: a > 1 ? order[a-2] : nil) } }
    }
    func createColumns() {
        let members = Set(layouts.flatMap(\.members))
        let selection = orderedOrigins.filter { selected.contains($0) }
        let invokingRoot = pickerTarget.flatMap { try? session.address(of:$0).blockID }.flatMap { id in document.blocks.first { $0.id == id } }.map(identity)
        guard !selection.contains(where:{members.contains($0)}), !(selection.isEmpty && invokingRoot.map(members.contains) == true) else {
            error = "A column layout cannot contain another column layout"; record("Rejected nested columns"); return
        }
        if !selection.isEmpty {
            let indices = selection.compactMap { orderedOrigins.firstIndex(of:$0) }
            guard indices.count == selected.count, indices.last! - indices.first! + 1 == indices.count else { error = "Choose contiguous root blocks"; record("Rejected column selection"); return }
        }
        let leading:NodeID?
        if let first = selection.first { leading = first }
        else if let target = invokingRoot, let index = orderedOrigins.firstIndex(of:target), index+1 < orderedOrigins.count { leading = orderedOrigins[index+1] }
        else { leading = nil }
        serial += 1
        let columns = ReviewLayout(id:"layout-\(serial)",leading:leading,first:selection,second:[],split:0.5)
        layouts.append(columns); activeLayoutID = columns.id
        requestedFocus = activeField?.key
        record("Create two-column review layout"); selected = []; pickerOpen = false; slashRange = nil
    }
    func moveToColumn(_ second:Bool) {
        guard let target = layout, !selected.isEmpty else { return }
        let moving = selected
        for index in layouts.indices { layouts[index].first.removeAll { moving.contains($0) }; layouts[index].second.removeAll { moving.contains($0) } }
        guard let index = layouts.firstIndex(where:{$0.id == target.id}) else { return }
        if second { layouts[index].second += moving } else { layouts[index].first += moving }
        requestedFocus = activeField?.key
        record(second ? "Move selected into second column" : "Move selected into first column")
    }
    func moveOutOfColumns() {
        guard let columns = layout, !selected.isEmpty else { return }
        let moving = selected
        let destination = columns.members.last(where:{ !moving.contains($0) })
        for index in layouts.indices { layouts[index].first.removeAll { moving.contains($0) }; layouts[index].second.removeAll { moving.contains($0) } }
        perform("Move selected out of columns") {
            _ = try session.move(WritingSelection(nodes:moving),into:.root,after:destination)
            requestedFocus = activeField?.key
        }
    }
    func writeEmptyColumn(_ id:String,second:Bool,text:String) {
        guard !text.isEmpty, let index = layouts.firstIndex(where:{$0.id == id}) else { return }
        let leading = layouts[index].leading
        let before = leading.flatMap { orderedOrigins.firstIndex(of:$0) }.flatMap { $0 > 0 ? orderedOrigins[$0-1] : nil } ?? (leading == nil ? orderedOrigins.last : nil)
        serial += 1
        perform("Write into empty column") {
            let block = try Block.paragraph(id:"review-\(serial)",text:text)
            let result = try session.insertCollectionNodes([.object(block.fields)],into:.root,after:before)
            guard let node = result.nodes.first else { return }
            if second { layouts[index].second.append(node) } else { layouts[index].first.append(node) }
            activeField = ReviewField(node:node,name:"content"); activeRange = NSRange(location:text.utf16.count,length:0); requestedFocus = activeField?.key
        }
    }
    func removeColumns(_ id:String? = nil) {
        guard let columns = id.flatMap({ key in layouts.first { $0.id == key } }) ?? layout else { return }
        let children = columns.first + columns.second
        let root = orderedOrigins, members = Set(children)
        let firstIndex = columns.leading.flatMap { root.firstIndex(of:$0) } ?? root.count
        var previous = root.prefix(firstIndex).last(where:{ !members.contains($0) })
        perform("Remove columns in logical order") {
            // Local study flattens through existing body moves; atomic protocol-7 ownership/Undo remains ST-122.
            for node in children { _ = try session.move(WritingSelection(nodes:[node]),into:.root,after:previous); previous = node }
            layouts.removeAll { $0.id == columns.id }; splitPreview = nil; splitPreviewLayoutID = nil
            selected = children; requestedFocus = activeField?.key
        }
    }
    func previewSplit(_ value:Double,layoutID:String? = nil) {
        guard let id = layoutID ?? layout?.id else { return }
        activeLayoutID = id
        if splitPreview == nil || splitPreviewLayoutID != id { record("Begin resize preview") }
        splitPreviewLayoutID = id; splitPreview = (min(0.9,max(0.1,value))*10000).rounded()/10000
    }
    func displayedSplit(_ columns:ReviewLayout) -> Double { splitPreviewLayoutID == columns.id ? splitPreview ?? columns.split : columns.split }
    func finishSplit() {
        guard let id = splitPreviewLayoutID, let index = layouts.firstIndex(where:{$0.id == id}), let value = splitPreview else { return }
        layouts[index].split = value; splitPreview = nil; splitPreviewLayoutID = nil; showResizePanel = false
        record("Commit split \(Int((value*100).rounded())) / \(100-Int((value*100).rounded()))")
    }
    func cancelSplit() { splitPreview = nil; splitPreviewLayoutID = nil; showResizePanel = false; record("Cancel resize preview") }
    func openResize(_ id:String) { activeLayoutID = id; showResizePanel = true; record("Open resize panel") }
    func openPicker(after node: NodeID?) { pickerTarget = node; pickerOpen = true; pickerQuery = ""; pickerIndex = 0; slashRange = nil; record("Open contextual insert picker") }
    func closePicker() { pickerOpen = false; slashRange = nil; record("Dismiss picker without deleting query"); if let field = activeField { requestedFocus = field.key } }
    func detectSlash(_ field: ReviewField) {
        guard field.name == "content", activeRange.length == 0 else { return }
        let string = text(field) as NSString, end = min(activeRange.location,string.length)
        let prefix = string.substring(to:end)
        guard let slash = prefix.range(of: "/", options: .backwards), !prefix[slash.upperBound...].contains(where: { $0.isWhitespace }) else { return }
        let offset = prefix[..<slash.lowerBound].utf16.count
        guard offset == 0 || prefix[..<slash.lowerBound].last?.isWhitespace == true else { return }
        guard let address = try? session.textAddress(of: field.node, field: field.name), let range = try? session.selectedText(at: address, range: offset..<end) else { return }
        slashRange = range; pickerTarget = field.node; pickerOpen = true; pickerQuery = String(prefix[slash.upperBound...]); pickerIndex = min(pickerIndex,max(options.count-1,0))
    }
    func handleKey(_ key: ReviewKey) -> Bool {
        if key == .escape, splitPreview != nil { cancelSplit(); return true }
        guard pickerOpen else { return false }
        switch key {
        case .escape: closePicker()
        case .down: pickerIndex = min(pickerIndex+1,max(options.count-1,0))
        case .up: pickerIndex = max(pickerIndex-1,0)
        case .enter: if options.indices.contains(pickerIndex) { insert(options[pickerIndex]) }
        }
        return true
    }
    func insert(_ option: String) {
        if option == "Two columns" { createColumns(); return }
        perform("Insert \(option)") {
            if let range = slashRange {
                let a = try session.resolve(range.start), b = try session.resolve(range.end)
                _ = try session.replaceText(at:a.address, range:min(a.offset,b.offset)..<max(a.offset,b.offset), with:"")
            }
            serial += 1
            let id = "review-\(serial)"
            var fields: [String: JSONValue] = ["id":.string(id)]
            switch option {
            case "Heading": fields.merge(["type":.string("heading"),"level":.number(2),"content":.array([])]) { _,new in new }
            case "Quote", "Callout": fields["type"] = .string(option.lowercased()); fields["content"] = .array([]); if option == "Callout" { fields["variant"] = .string("info") }
            case "Bulleted list", "Checklist": fields["type"] = .string("list"); fields["style"] = .string(option == "Checklist" ? "todo" : "unordered"); fields["items"] = .array([.object(["id":.string("item-\(serial)"),"content":.array([])])])
            case "Toggle": fields["type"] = .string("toggle"); fields["summary"] = .array([textNode("Details")]); fields["children"] = .array([])
            case "Divider": fields["type"] = .string("divider")
            case "Code": fields["type"] = .string("code"); fields["code"] = .string(""); fields["language"] = .string("plain")
            case "Table":
                fields["type"] = .string("table")
                let cell: JSONValue = .object(["id":.string("cell-\(serial)"),"content":.array([])])
                fields["rows"] = .array([.object(["id":.string("row-\(serial)"),"cells":.array([cell])])])
            default: fields["type"] = .string("paragraph"); fields["content"] = .array([])
            }
            let inserted = try session.insertCollectionNodes([.object(fields)], into:.root, after:pickerTarget)
            if let node = inserted.nodes.first {
                var field:ReviewField?
                switch option {
                case "Divider": break
                case "Code": field = ReviewField(node:node,name:"code")
                case "Toggle": field = ReviewField(node:node,name:"summary")
                case "Bulleted list", "Checklist": field = ReviewField(node:try session.node(at:NodeAddress(id,path:["items","item-\(serial)"])),name:"content")
                case "Table": field = ReviewField(node:try session.node(at:NodeAddress(id,path:["rows","row-\(serial)","cells","cell-\(serial)"])),name:"content")
                default: field = ReviewField(node:node,name:"content")
                }
                selected = field == nil ? [node] : []
                if let field { activeField = field; activeRange = NSRange(location:0,length:0); requestedFocus = field.key }
            }
            pickerOpen = false; slashRange = nil
        }
    }
}
struct ReviewField: Equatable { let node: NodeID; let name: String; var key: String { "\(node)-\(name)" } }
struct ReviewLayout { let id: String; let leading:NodeID?; var first: [NodeID]; var second: [NodeID]; var split: Double; var members: [NodeID] { first+second } }
enum ReviewKey { case up, down, enter, escape }

enum ReviewRow:Identifiable { case block(String),columns(String); var id:String { switch self { case .block(let id):"block-"+id;case .columns(let id):"columns-"+id } } }
