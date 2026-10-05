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
    @State private var dragStartingSplit: Double?
    var body: some View {
        GeometryReader { geometry in
            VStack(spacing:0) {
                if !model.focusMode { chrome }
                HStack(spacing:0) {
                    if geometry.size.width >= 700 && model.showOutline && !model.focusMode { outline(narrow:false).frame(width:180) }
                    ScrollViewReader { proxy in
                        ScrollView {
                            VStack(alignment:.leading,spacing:20) {
                                ReviewTitle(model:model).id("review-title").frame(maxWidth:.infinity,alignment:.leading)
                                if let error = model.error { Label(error,systemImage:"exclamationmark.triangle").foregroundStyle(.red) }
                                selectionTools
                                documentBlocks(width:max(200,geometry.size.width-(geometry.size.width >= 700 && model.showOutline && !model.focusMode ? 180 : 0)-(geometry.size.width < 700 ? 40 : 96)))
                            }
                            .frame(maxWidth:model.layouts.isEmpty ? 680 : 960,alignment:.leading)
                            .padding(.horizontal,geometry.size.width < 700 ? 20 : 48).padding(.vertical,32).frame(maxWidth:.infinity)
                        }
                        .onChange(of:model.jumpSerial) { _,_ in if let value = model.jumpTarget { withAnimation { proxy.scrollTo("block-"+value,anchor:.top) } } }
                    }
                }
                if model.touchTools { touchAccessory }
                if model.focusMode { Button("Leave focus mode") { model.focusMode = false }.padding(8) }
                VStack(spacing:4) {
                    Text(model.trace.last ?? "Ready").accessibilityIdentifier("Review action")
                    Text("ST-121 local interaction study · body: shared protocol 6 · title/columns: review state")
                }.font(.caption).foregroundStyle(.secondary).padding(8).frame(maxWidth:.infinity).background(.thinMaterial)
            }
            .sheet(isPresented:Binding(get:{geometry.size.width < 700 && model.showOutline && !model.focusMode},set:{if !$0 { model.showOutline = false }})) {
                VStack { outline(narrow:true); Button("Close outline") { model.showOutline = false }.padding() }
                    .presentationDetents([.medium,.large])
            }
        }
        .sheet(isPresented:$model.showResizePanel,onDismiss:{ if model.splitPreview != nil { model.cancelSplit() } }) {
            if let columns = model.layout {
                VStack(alignment:.leading,spacing:20) {
                    Text("Column proportions").font(.headline)
                    splitControls(columns)
                    HStack { Button("Apply split") { model.finishSplit() }.disabled(model.splitPreview == nil); Button("Cancel resize") { model.cancelSplit() } }
                }.padding(24).frame(minWidth:300,minHeight:220).presentationDetents([.height(300)])
            }
        }
        .preferredColorScheme(model.dark ? .dark : .light)
        .onChange(of:model.actionRevision) { _,_ in exportReceipt() }
        .onChange(of:model.title) { _,_ in exportReceipt() }
    }
    private var chrome: some View {
        ScrollView(.horizontal) { HStack(spacing:12) {
            Button("Outline",systemImage:"list.bullet.indent") { model.showOutline.toggle(); model.record("Toggle personal outline") }
            Button("Focus",systemImage:"viewfinder") { model.focusMode = true; model.showOutline = false; model.selectionMode = false; model.selected = []; model.record("Enter personal focus mode") }
            Button("Insert",systemImage:"plus") { model.openPicker(after:model.activeField?.node ?? model.orderedOrigins.first) }
            Toggle("Select blocks",isOn:$model.selectionMode).toggleStyle(.button)
            Spacer()
            Toggle("Large text",isOn:$model.largeText).toggleStyle(.button)
            Toggle("Dark",isOn:$model.dark).toggleStyle(.button)
            Toggle("Touch tools",isOn:$model.touchTools).toggleStyle(.button)
        }.padding(12) }.background(.bar)
    }
    private func outline(narrow:Bool) -> some View {
        VStack(alignment:.leading,spacing:12) {
            Text("On this page").font(.headline)
            Button(model.title.isEmpty ? "Untitled" : model.title) { model.navigate(to:"intro"); if narrow { model.showOutline = false } }
            ForEach(model.document.blocks.filter { $0.type == "heading" }) { block in
                Button(block.text.isEmpty ? "Heading" : block.text) { model.navigate(to:block.id); if narrow { model.showOutline = false } }
            }
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
            Button("Create two columns") { model.createColumns() }
            if model.layout != nil {
                Button("First column") { model.moveToColumn(false) }
                Button("Second column") { model.moveToColumn(true) }
                Button("Move out of columns") { model.moveOutOfColumns() }
            }
            Button("Cancel selection") { model.selected = []; model.selectionMode = false }
        }.buttonStyle(.bordered)
    }
    private var touchAccessory: some View {
        ScrollView(.horizontal) {
            HStack(spacing:12) {
                Button("Insert block") { model.openPicker(after:model.activeField?.node ?? model.orderedOrigins.first) }
                Button("Bold") { model.format("bold") }.disabled(model.activeRange.length == 0).accessibilityIdentifier("Accessory bold")
                Button("Italic") { model.format("italic") }.disabled(model.activeRange.length == 0).accessibilityIdentifier("Accessory italic")
                Button("Select current block") { if let node = model.activeField?.node { model.select(node) } }
                if let columns = model.layout { Button("Resize columns") { model.openResize(columns.id) }.accessibilityIdentifier("Accessory resize") }
            }.buttonStyle(.bordered).padding(12)
        }.background(.bar)
    }
    @ViewBuilder private func documentBlocks(width:Double) -> some View {
        ForEach(model.reviewRows) { row in
            switch row {
            case .block(let id):
                if let block = model.document.blocks.first(where:{$0.id == id}) { blockRow(block:block,path:[],rootID:block.id,topLevel:true).id("block-"+block.id) }
            case .columns(let id):
                if let layout = model.layouts.first(where:{$0.id == id}) { columns(layout,width:min(width,960)).id("columns-"+id) }
            }
        }
    }
    private func splitControls(_ columns:ReviewLayout) -> some View {
        VStack(alignment:.leading,spacing:12) {
            Text("Split \(Int((model.displayedSplit(columns)*100).rounded())) / \(100-Int((model.displayedSplit(columns)*100).rounded()))").font(.caption).accessibilityIdentifier("Split value")
            Slider(value:Binding(get:{model.displayedSplit(columns)},set:{model.previewSplit($0,layoutID:columns.id)}),in:0.1...0.9,onEditingChanged:{ active in if !active { model.finishSplit() } })
                .accessibilityLabel("Column split").accessibilityIdentifier("Column split")
            HStack {
                Button("50 / 50") { model.previewSplit(0.5,layoutID:columns.id) }
                Button("70 / 30") { model.previewSplit(0.7,layoutID:columns.id) }
                Button("30 / 70") { model.previewSplit(0.3,layoutID:columns.id) }
            }.buttonStyle(.bordered)
            #if os(macOS)
            HStack {
                Button("Decrease first column") { model.previewSplit(model.displayedSplit(columns)-0.05,layoutID:columns.id); model.finishSplit() }
                    .keyboardShortcut(.leftArrow,modifiers:[.command,.option])
                Button("Increase first column") { model.previewSplit(model.displayedSplit(columns)+0.05,layoutID:columns.id); model.finishSplit() }
                    .keyboardShortcut(.rightArrow,modifiers:[.command,.option])
            }.font(.caption).disabled(model.layout?.id != columns.id)
            #endif
        }
    }
    @ViewBuilder private func columns(_ layout:ReviewLayout,width:Double) -> some View {
        let minimum = model.bodySize*20
        let available = width-48
        let stacked = available < minimum*2
        let split = model.displayedSplit(layout)
        let rendered = max(minimum/available,min(1-minimum/available,split))
        VStack(alignment:.leading,spacing:12) {
            ViewThatFits(in:.horizontal) {
                HStack { columnHeader(layout,stacked:stacked); Spacer(); columnActions(layout) }
                VStack(alignment:.leading,spacing:8) { columnHeader(layout,stacked:stacked); columnActions(layout) }
            }
            if !stacked {
                splitControls(layout)
                if model.splitPreviewLayoutID == layout.id {
                    HStack { Button("Apply split") { model.finishSplit() }; Button("Cancel resize") { model.cancelSplit() } }
                }
            } else {
                Text("Split \(Int((layout.split*100).rounded())) / \(100-Int((layout.split*100).rounded()))").font(.caption).accessibilityIdentifier("Stacked split value")
            }
            if stacked {
                column(layout.first,name:"First column",layout:layout,second:false)
                column(layout.second,name:"Second column",layout:layout,second:true)
            } else {
                HStack(alignment:.top,spacing:24) {
                    column(layout.first,name:"First column",layout:layout,second:false).frame(width:available*rendered)
                    RoundedRectangle(cornerRadius:3).fill(.secondary.opacity(0.5)).frame(width:8,height:48)
                        .overlay(Image(systemName:"arrow.left.and.right").font(.caption).padding(4).background(.background))
                        .contentShape(Rectangle()).accessibilityLabel("Drag column divider")
                        .gesture(DragGesture(minimumDistance:0).onChanged { value in
                            if dragStartingSplit == nil { dragStartingSplit = layout.split }
                            model.previewSplit((dragStartingSplit ?? layout.split)+value.translation.width/available,layoutID:layout.id)
                        }.onEnded { _ in model.finishSplit(); dragStartingSplit = nil })
                    column(layout.second,name:"Second column",layout:layout,second:true).frame(width:available*(1-rendered))
                }
            }
        }.padding(12).overlay(RoundedRectangle(cornerRadius:8).stroke(.secondary.opacity(0.35)))
    }
    private func columnHeader(_ columns:ReviewLayout,stacked:Bool) -> some View {
        Button(stacked ? "Columns stacked in reading order" : "Two columns") { model.chooseLayout(columns.id) }
            .font(.caption).buttonStyle(.plain).accessibilityIdentifier("Column presentation \(columns.id)")
    }
    private func columnActions(_ columns:ReviewLayout) -> some View {
        HStack { Button("Resize columns") { model.openResize(columns.id) }; Button("Remove columns") { model.removeColumns(columns.id) } }.font(.caption)
    }
    private func column(_ nodes:[NodeID],name:String,layout:ReviewLayout,second:Bool) -> some View {
        VStack(alignment:.leading,spacing:16) {
            Text(name).font(.caption).foregroundStyle(.secondary)
            ForEach(model.columnBlocks(nodes)) { block in blockRow(block:block,path:[],rootID:block.id,topLevel:true) }
            if nodes.isEmpty {
                TextField("Start writing",text:Binding(get:{""},set:{model.writeEmptyColumn(layout.id,second:second,text:$0)}))
                    .textFieldStyle(.plain).accessibilityIdentifier("Empty \(name) \(layout.id)").padding(.vertical,12)
            }
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
                }.buttonStyle(.plain).accessibilityIdentifier("Insert option \(option)").background(index == model.pickerIndex ? Color.accentColor.opacity(0.12) : .clear,in:RoundedRectangle(cornerRadius:6))
            }
            Button("Dismiss picker") { model.closePicker() }.padding(.top,8)
        }.padding(12).frame(maxWidth:288).background(.regularMaterial,in:RoundedRectangle(cornerRadius:12)).overlay(RoundedRectangle(cornerRadius:12).stroke(.secondary.opacity(0.5)))
    }
    @ViewBuilder private func blockRow(block:Block,path:[String],rootID:String,topLevel:Bool) -> some View {
        let address = NodeAddress(rootID,path:path)
        let node = (try? model.session.node(at:address)) ?? model.identity(block)
        HStack(alignment:.top,spacing:8) {
            if topLevel && (model.selectionMode || !model.selected.isEmpty) {
                Button { model.select(node) } label: { Image(systemName:model.selected.contains(node) ? "checkmark.circle.fill" : "circle").frame(width:28,height:32) }
                    .buttonStyle(.plain).accessibilityLabel("Select \(block.id)")
            }
            VStack(alignment:.leading,spacing:8) {
                blockContent(block: block,node:node,path:path,rootID:rootID)
                if topLevel && (model.isActive(rootID) || model.selected.contains(node) || model.hoveredRoot == node) {
                    HStack {
                        Menu(block.type == "heading" ? "Heading" : "Block actions") {
                            Button("Convert to heading") { model.convert(node,to:"heading") }
                            Button("Convert to paragraph") { model.convert(node,to:"paragraph") }
                            Button("Select block") { model.select(node) }
                            Button("Insert after") { model.openPicker(after:node) }
                        }.accessibilityIdentifier("Block actions \(block.id)").accessibilityValue(block.type)
                        if model.activeField?.node == node && model.activeRange.length > 0 { Button("Bold") { model.format("bold") }; Button("Italic") { model.format("italic") } }
                    }.font(.caption)
                }
                if model.pickerOpen && model.pickerTarget == node { picker }
            }.frame(maxWidth:.infinity,alignment:.leading)
        }.onHover { hover in if topLevel { model.hoveredRoot = hover ? node : nil } }.padding(4).background(model.selected.contains(node) ? Color.accentColor.opacity(0.13) : .clear,in:RoundedRectangle(cornerRadius:6))
    }
    @ViewBuilder private func blockContent(block:Block,node:NodeID,path:[String],rootID:String) -> some View {
        switch block.type {
        case "paragraph", "heading", "quote", "callout": input(node,"content",label:"Text \(block.id)",size:block.type == "heading" ? model.bodySize*1.55 : model.bodySize)
        case "code": input(node,"code",label:"Code \(block.id)",size:model.bodySize)
        case "divider": Divider().padding(.vertical,12)
        case "toggle":
            DisclosureGroup(isExpanded:Binding(get:{model.expandedToggles.contains(block.id)},set:{ expanded in if expanded { model.expandedToggles.insert(block.id) } else { model.expandedToggles.remove(block.id) } })) {
                ForEach(block.fields["children"]?.array ?? [],id:\.reviewID) { value in
                    if let fields = value.object, let child = try? Block(fields:fields) { AnyView(blockRow(block:child,path:path+["children",child.id],rootID:rootID,topLevel:false)) }
                }
            } label: {
                HStack {
                    input(node,"summary",label:"Toggle \(block.id)",size:model.bodySize)
                    Button(model.expandedToggles.contains(block.id) ? "Hide details" : "Show details") {
                        if model.expandedToggles.contains(block.id) { model.expandedToggles.remove(block.id) } else { model.expandedToggles.insert(block.id) }
                        model.record("Toggle personal disclosure")
                    }.font(.caption).accessibilityIdentifier("Disclosure \(block.id)")
                }
            }
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
        ReviewInput(model:model,field:ReviewField(node:node,name:field),label:label,fontSize:size).id(ReviewField(node:node,name:field).key)
    }
    private func exportReceipt() {
        guard let path = ProcessInfo.processInfo.environment["EDITOR_REVIEW_RECEIPT"] else { return }
        do {
            var receipt: [String:Any] = ["qualification":"Local prototype only; body protocol6, title/columns local", "title":model.title,"trace":model.trace,"body":try JSONSerialization.jsonObject(with:model.document.json()),"selectedCount":model.selected.count,"pickerOpen":model.pickerOpen]
            receipt["layouts"] = model.layouts.map { columns in ["id":columns.id,"first":columns.first.map(String.init(describing:)),"second":columns.second.map(String.init(describing:)),"split":columns.split] as [String:Any] }
            receipt["actionRevision"] = model.actionRevision
            receipt["selectionUTF16"] = ["location":model.activeRange.location,"length":model.activeRange.length]
            if let field = model.activeField { receipt["activeField"] = field.key }
            let data = try JSONSerialization.data(withJSONObject:receipt,options:[.sortedKeys,.prettyPrinted])
            try data.write(to:URL(fileURLWithPath:path),options:.atomic)
        } catch { model.error = "Could not retain review receipt: \(error)" }
    }
}
private extension JSONValue { var reviewID:String { self["id"]?.string ?? "" } }
