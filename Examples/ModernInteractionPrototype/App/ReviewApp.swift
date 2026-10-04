import BlockEditorCore
import SwiftUI
#if os(macOS)
import AppKit
#endif

@main struct ModernReviewApp: App {
    @State private var model: ReviewModel?
    @State private var failure: String?
    var body: some Scene {
        WindowGroup {
            Group {
                if let model { ReviewCanvas(model:model) }
                else { Text(failure ?? "Loading review fixture…").padding().task { load() } }
            }
        }
        #if os(macOS)
        .defaultSize(width:1120,height:850)
        #endif
    }
    @MainActor private func load() {
        do {
            guard let url = Bundle.main.url(forResource:"rich-blocks",withExtension:"json") else { throw CocoaError(.fileNoSuchFile) }
            model = try ReviewModel(fixture:Data(contentsOf:url))
            #if os(macOS)
            NSApp.setActivationPolicy(.regular)
            NSApp.activate(ignoringOtherApps:true)
            if ProcessInfo.processInfo.environment["EDITOR_REVIEW_PRIMARY_WINDOW"] == "1" {
                DispatchQueue.main.async {
                    guard let screen = NSScreen.screens.first, let window = NSApp.windows.first else { return }
                    let visible = screen.visibleFrame
                    let width = min(1120,visible.width-80), height = min(850,visible.height-80)
                    window.setFrame(NSRect(x:visible.midX-width/2,y:visible.midY-height/2,width:width,height:height),display:true)
                }
            }
            #endif
        } catch { failure = "Review fixture could not be loaded: \(error)" }
    }
}

@MainActor struct ReviewCanvas: View {
    @Bindable var model: ReviewModel
    @FocusState private var titleFocused: Bool
    var body: some View {
        GeometryReader { geometry in
            VStack(spacing:0) {
                if !model.focusMode { chrome }
                HStack(spacing:0) {
                    if model.showOutline && !model.focusMode { outline.frame(width:180) }
                    ScrollViewReader { proxy in
                        ScrollView {
                            VStack(alignment:.leading,spacing:20) {
                                TextField("Untitled",text:$model.title,axis:.vertical)
                                    .font(.system(size:model.bodySize*2.1,weight:.bold)).textFieldStyle(.plain)
                                    .accessibilityIdentifier("Document title").focused($titleFocused)
                                    .onSubmit { model.requestedFocus = ReviewField(node:model.orderedOrigins[0],name:"content").key; titleFocused = false; model.record("Title Enter to body") }
                                if let error = model.error { Label(error,systemImage:"exclamationmark.triangle").foregroundStyle(.red) }
                                selectionTools
                                documentBlocks(width:max(200,geometry.size.width-(model.showOutline ? 180 : 0)-(geometry.size.width < 700 ? 40 : 96)))
                            }
                            .frame(maxWidth:model.layout == nil ? 680 : 960,alignment:.leading)
                            .padding(.horizontal,geometry.size.width < 700 ? 20 : 48).padding(.vertical,32).frame(maxWidth:.infinity)
                        }
                        .onChange(of:model.jumpTarget) { _,value in if let value { withAnimation { proxy.scrollTo(value,anchor:.top) } } }
                    }
                }
                if model.touchTools { touchAccessory }
                if model.focusMode { Button("Leave focus mode") { model.focusMode = false }.padding(8) }
                VStack(spacing:4) {
                    Text(model.trace.last ?? "Ready").accessibilityIdentifier("Review action")
                    Text("ST-121 local interaction study · body: shared protocol 6 · title/columns: review state")
                }.font(.caption).foregroundStyle(.secondary).padding(8).frame(maxWidth:.infinity).background(.thinMaterial)
            }
        }
        .preferredColorScheme(model.dark ? .dark : .light)
        .onChange(of:model.trace.count) { _,_ in exportReceipt() }
        .onChange(of:model.title) { _,_ in exportReceipt() }
    }
    private var chrome: some View {
        ScrollView(.horizontal) { HStack(spacing:12) {
            Button("Outline",systemImage:"list.bullet.indent") { model.showOutline.toggle(); model.record("Toggle personal outline") }
            Button("Focus",systemImage:"viewfinder") { model.focusMode = true; model.record("Enter personal focus mode") }
            Button("Insert",systemImage:"plus") { model.openPicker(after:model.activeField?.node ?? model.orderedOrigins.first) }
            Spacer()
            Toggle("Large text",isOn:$model.largeText).toggleStyle(.button)
            Toggle("Dark",isOn:$model.dark).toggleStyle(.button)
            Toggle("Touch tools",isOn:$model.touchTools).toggleStyle(.button)
        }.padding(12) }.background(.bar)
    }
    private var outline: some View {
        VStack(alignment:.leading,spacing:12) {
            Text("On this page").font(.headline)
            Button(model.title.isEmpty ? "Untitled" : model.title) { model.jumpTarget = "intro" }
            ForEach(model.document.blocks.filter { $0.type == "heading" }) { block in Button(block.text.isEmpty ? "Heading" : block.text) { model.jumpTarget = block.id; model.record("Navigate outline to \(block.id)") } }
            Spacer()
        }.buttonStyle(.plain).padding(16).background(.quaternary.opacity(0.3))
    }
    @ViewBuilder private var selectionTools: some View {
        if !model.selected.isEmpty {
            VStack(alignment:.leading,spacing:8) {
                Text("\(model.selected.count) blocks selected").font(.caption).accessibilityIdentifier("Selection count")
                ViewThatFits(in:.horizontal) { rangeActions; ScrollView(.horizontal) { rangeActions } }
            }.padding(12).background(.tint.opacity(0.08),in:RoundedRectangle(cornerRadius:10))
        }
        if model.pickerOpen && model.pickerTarget == nil { picker }
    }
    private var rangeActions: some View {
        HStack {
            Button("Move up") { model.moveSelected(down:false) }
            Button("Move down") { model.moveSelected(down:true) }
            if model.layout == nil { Button("Create two columns") { model.createColumns() } }
            else {
                Button("First column") { model.moveToColumn(false) }
                Button("Second column") { model.moveToColumn(true) }
            }
            Button("Cancel selection") { model.selected = [] }
        }.buttonStyle(.bordered)
    }
    private var touchAccessory: some View {
        ScrollView(.horizontal) {
            HStack(spacing:12) {
                Button("Insert block") { model.openPicker(after:model.activeField?.node ?? model.orderedOrigins.first) }
                Button("Bold") { model.format("bold") }.disabled(model.activeRange.length == 0)
                Button("Italic") { model.format("italic") }.disabled(model.activeRange.length == 0)
                Button("Select current block") { if let node = model.activeField?.node { model.select(node) } }
                if model.layout != nil { Button("Remove columns") { model.removeColumns() } }
            }.buttonStyle(.bordered).padding(12)
        }.background(.bar)
    }
    @ViewBuilder private func documentBlocks(width:Double) -> some View {
        let members = Set(model.layout?.members ?? [])
        let firstMember = model.orderedOrigins.first(where: { members.contains($0) })
        ForEach(model.document.blocks) { block in
            let node = model.identity(block)
            if node == firstMember, let layout = model.layout { columns(layout,width:min(width,960)).id("columns") }
            if !members.contains(node) { blockRow(block: block,path:[],rootID:block.id,topLevel:true).id(block.id) }
        }
    }
    @ViewBuilder private func columns(_ layout:ReviewLayout,width:Double) -> some View {
        let minimum = model.bodySize*20
        let available = width-48
        let stacked = available < minimum*2
        let split = model.splitPreview ?? layout.split
        let rendered = max(minimum/available,min(1-minimum/available,split))
        VStack(alignment:.leading,spacing:12) {
            HStack {
                Text(stacked ? "Columns stacked in reading order" : "Two columns").font(.caption).accessibilityIdentifier("Column presentation")
                Spacer()
                Button("Remove columns") { model.removeColumns() }
            }
            if !stacked {
                HStack {
                    Text("Split \(Int(split*100)) / \(100-Int(split*100))").font(.caption).accessibilityIdentifier("Split value")
                    Slider(value:Binding(get:{model.splitPreview ?? layout.split},set:{model.previewSplit($0)}),in:0.1...0.9,onEditingChanged:{ active in if !active { model.finishSplit() } })
                        .accessibilityLabel("Column split").accessibilityIdentifier("Column split")
                    Button("Equal split") { model.previewSplit(0.5); model.finishSplit() }
                }
                if model.splitPreview != nil {
                    HStack { Button("Apply split") { model.finishSplit() }; Button("Cancel resize") { model.cancelSplit() } }
                }
            }
            if stacked {
                column(layout.first,name:"First column")
                column(layout.second,name:"Second column")
            } else {
                HStack(alignment:.top,spacing:24) {
                    column(layout.first,name:"First column").frame(width:available*rendered)
                    Divider().overlay(Image(systemName:"arrow.left.and.right").font(.caption).padding(4).background(.background)).frame(width:0)
                    column(layout.second,name:"Second column").frame(width:available*(1-rendered))
                }
            }
        }.padding(12).overlay(RoundedRectangle(cornerRadius:8).stroke(.secondary.opacity(0.35)))
    }
    private func column(_ nodes:[NodeID],name:String) -> some View {
        VStack(alignment:.leading,spacing:16) {
            Text(name).font(.caption).foregroundStyle(.secondary)
            ForEach(model.document.blocks.filter { nodes.contains(model.identity($0)) }) { block in blockRow(block:block,path:[],rootID:block.id,topLevel:true) }
            if nodes.isEmpty { Text("Move a selected block here").foregroundStyle(.secondary).padding(.vertical,20) }
        }.frame(maxWidth:.infinity,alignment:.leading).accessibilityElement(children:.contain).accessibilityLabel(name)
    }
    private var picker: some View {
        VStack(alignment:.leading,spacing:4) {
            if model.slashRange == nil {
                TextField("Search blocks",text:$model.pickerQuery).textFieldStyle(.roundedBorder)
                    .onSubmit { if let option = model.options.first { model.insert(option) } }
            }
            ForEach(Array(model.options.enumerated()),id:\.element) { index,option in
                Button { model.insert(option) } label: {
                    HStack { Text(option); Spacer(); if index == model.pickerIndex { Image(systemName:"checkmark") } }.frame(maxWidth:.infinity,alignment:.leading).padding(8).contentShape(Rectangle())
                }.buttonStyle(.plain).background(index == model.pickerIndex ? Color.accentColor.opacity(0.12) : .clear,in:RoundedRectangle(cornerRadius:6))
            }
            Button("Dismiss picker") { model.closePicker() }.padding(.top,8)
        }.padding(12).frame(maxWidth:288).background(.regularMaterial,in:RoundedRectangle(cornerRadius:12)).overlay(RoundedRectangle(cornerRadius:12).stroke(.secondary.opacity(0.5)))
    }
    @ViewBuilder private func blockRow(block:Block,path:[String],rootID:String,topLevel:Bool) -> some View {
        let address = NodeAddress(rootID,path:path)
        let node = (try? model.session.node(at:address)) ?? model.identity(block)
        HStack(alignment:.top,spacing:8) {
            if topLevel {
                Button { model.select(node) } label: { Image(systemName:model.selected.contains(node) ? "checkmark.circle.fill" : "circle").frame(width:28,height:32) }
                    .buttonStyle(.plain).accessibilityLabel("Select \(block.id)")
            }
            VStack(alignment:.leading,spacing:8) {
                blockContent(block: block,node:node,path:path,rootID:rootID)
                if topLevel {
                    HStack {
                        Menu("Block actions") {
                            Button("Convert to heading") { model.convert(node,to:"heading") }
                            Button("Convert to paragraph") { model.convert(node,to:"paragraph") }
                            Button("Select block") { model.select(node) }
                            Button("Insert after") { model.openPicker(after:node) }
                        }
                        if model.activeField?.node == node && model.activeRange.length > 0 { Button("Bold") { model.format("bold") }; Button("Italic") { model.format("italic") } }
                    }.font(.caption)
                }
                if model.pickerOpen && model.pickerTarget == node { picker }
            }.frame(maxWidth:.infinity,alignment:.leading)
        }.padding(4).background(model.selected.contains(node) ? Color.accentColor.opacity(0.13) : .clear,in:RoundedRectangle(cornerRadius:6))
    }
    @ViewBuilder private func blockContent(block:Block,node:NodeID,path:[String],rootID:String) -> some View {
        switch block.type {
        case "paragraph", "heading", "quote", "callout": input(node,"content",label:"Text \(block.id)",size:block.type == "heading" ? model.bodySize*1.55 : model.bodySize)
        case "code": input(node,"code",label:"Code \(block.id)",size:model.bodySize)
        case "divider": Divider().padding(.vertical,12)
        case "toggle":
            DisclosureGroup {
                ForEach(block.fields["children"]?.array ?? [],id:\.reviewID) { value in
                    if let fields = value.object, let child = try? Block(fields:fields) { AnyView(blockRow(block:child,path:path+["children",child.id],rootID:rootID,topLevel:false)) }
                }
            } label: { input(node,"summary",label:"Toggle \(block.id)",size:model.bodySize) }
        case "list":
            listItems(block.fields["items"]?.array ?? [],path:path+["items"],rootID:rootID,style:block.fields["style"]?.string ?? "unordered")
        case "table":
            ScrollView(.horizontal) {
                VStack(alignment:.leading,spacing:8) {
                    ForEach(block.fields["rows"]?.array ?? [],id:\.reviewID) { row in
                        HStack(alignment:.top,spacing:12) {
                            ForEach(row["cells"]?.array ?? [],id:\.reviewID) { cell in
                                if let identity = try? model.session.node(at:NodeAddress(rootID,path:path+["rows",row.reviewID,"cells",cell.reviewID])) { input(identity,"content",label:"Cell \(cell.reviewID)",size:model.bodySize).frame(width:160) }
                            }
                        }
                    }
                }.padding(12)
            }.overlay(RoundedRectangle(cornerRadius:8).stroke(.secondary.opacity(0.4)))
        case "image":
            ZStack { RoundedRectangle(cornerRadius:8).fill(Color.accentColor.opacity(0.12)); Image(systemName:"mountain.2").font(.system(size:64)).foregroundStyle(.tint) }.frame(height:150).accessibilityLabel("Local coastline illustration")
            input(node,"caption",label:"Media caption",size:model.bodySize*0.88)
        default: Text("\(block.type) content preserved").foregroundStyle(.secondary)
        }
    }
    private func listItems(_ items:[JSONValue],path:[String],rootID:String,style:String) -> some View {
        VStack(alignment:.leading,spacing:8) {
            ForEach(items,id:\.reviewID) { item in
                let identity = try? model.session.node(at:NodeAddress(rootID,path:path+[item.reviewID]))
                HStack(alignment:.top) {
                    if style == "todo", let identity {
                        Toggle("Completed",isOn:Binding(get:{item["checked"] == .bool(true)},set:{ value in model.perform("Toggle checklist") { try model.session.setNodeField(identity,path:["checked"],value:.bool(value)) } })).labelsHidden()
                    } else { Text("•").padding(.top,6) }
                    if let identity { input(identity,"content",label:"List \(item.reviewID)",size:model.bodySize) }
                }
                if let children = item["children"]?.array, !children.isEmpty { AnyView(listItems(children,path:path+[item.reviewID,"children"],rootID:rootID,style:style)).padding(.leading,24) }
            }
        }
    }
    private func input(_ node:NodeID,_ field:String,label:String,size:Double) -> some View {
        ReviewInput(model:model,field:ReviewField(node:node,name:field),label:label,fontSize:size)
            .frame(minHeight:max(size*1.65+8, Double((model.text(ReviewField(node:node,name:field)).count/55)+1)*size*1.65+8))
    }
    private func exportReceipt() {
        guard let path = ProcessInfo.processInfo.environment["EDITOR_REVIEW_RECEIPT"] else { return }
        do {
            var receipt: [String:Any] = ["qualification":"Local prototype only; body protocol6, title/columns local", "title":model.title,"trace":model.trace,"body":try JSONSerialization.jsonObject(with:model.document.json()),"selectedCount":model.selected.count,"pickerOpen":model.pickerOpen]
            if let columns = model.layout { receipt["columns"] = ["first":columns.first.map(String.init(describing:)),"second":columns.second.map(String.init(describing:)),"split":columns.split] }
            let data = try JSONSerialization.data(withJSONObject:receipt,options:[.sortedKeys,.prettyPrinted])
            try data.write(to:URL(fileURLWithPath:path),options:.atomic)
        } catch { model.error = "Could not retain review receipt: \(error)" }
    }
}
private extension JSONValue { var reviewID:String { self["id"]?.string ?? "" } }
