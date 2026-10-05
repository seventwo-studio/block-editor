@testable import BlockEditorCore
import Foundation
import Testing

@Suite struct ModernListStructureTests {
    private func text(_ s: String) -> JSONValue { .array([.object(["type":.string("text"),"text":.string(s),"marks":.array([.object(["type":.string("bold")])])])]) }
    private func plain(_ s: String) -> JSONValue { .array([.object(["type":.string("text"),"text":.string(s)])]) }
    private func item(_ id: String, checked: Bool = false, children: [JSONValue] = []) -> JSONValue { .object(["id":.string(id),"content":text(id),"checked":.bool(checked),"consumer":.string("keep-"+id),"children":.array(children)]) }
    private func list(_ id: String = "L", style: String = "todo", items: [JSONValue]? = nil) -> JSONValue { .object(["id":.string(id),"type":.string("list"),"style":.string(style),"consumer":.string("root"),"items":.array(items ?? [item("a",children:[item("existing")]),item("b",checked:true,children:[item("kid")]),item("c"),item("d")])]) }
    private func document(_ blocks: [JSONValue]? = nil) throws -> ModernDocument {
        let root=URL(fileURLWithPath:#filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        var fields=try ModernDocument(json:Data(contentsOf:root.appendingPathComponent("docs/acceptance/modern-editor/documents/unicode.json"))).fields
        fields["blocks"] = .array(blocks ?? [list()]); return try ModernDocument(fields:fields)
    }
    private func session(_ actor: String, _ doc: ModernDocument? = nil) throws -> ModernSession { let d=try doc ?? document(); return try ModernSession(documentID:d.documentID,actorID:actor,epoch:"lists",document:d) }
    private func node(_ s: ModernSession, _ id: String, root: String = "L", path: [String] = []) throws -> NodeID { try s.node(at:NodeAddress(root,path:path.isEmpty ? ["items",id] : path)) }
    private func target(_ s: ModernSession, _ nodes: [NodeID], caret: WritingPosition? = nil) throws -> ModernListTarget { ModernListTarget(selection:try s.captureListNodes(nodes),caret:caret) }
    private func exchange(_ a: ModernSession, _ b: ModernSession) throws { let aa=try a.changes(),bb=try b.changes(); try a.receive(bb);try b.receive(aa);try a.receive(bb);try b.receive(aa) }

    @Test(arguments:["a","z"])
    func multiItemIndentPreservesRichMetadataChildrenPeerTextCaretAndSingleUndo(actor: String) throws {
        let a=try session(actor),b=try session("m"), n=try [node(a,"b"),node(a,"c")], f=try a.field(node:n[0])
        let caret=try a.position(in:f,offset:1), capture=try target(a,n,caret:caret), before=a.document
        _ = try a.listStructure(capture,action:.indent)
        #expect(try a.node(at:NodeAddress("L",path:["items","a","children","b"])) == n[0])
        #expect(a.document.blocks[0].fields["items"]?.array?.map { $0["id"]?.string } == ["a","d"])
        #expect(a.document.blocks[0].fields["items"]?.array?[0]["children"]?.array?.map { $0["id"]?.string } == ["existing","b","c"])
        #expect(try a.resolve(caret).address.identity == n[0] && a.resolve(caret).offset == 1)
        try b.replaceText(in:f,range:1..<1,with:" peer"); let kid=try b.field(node:b.node(at:NodeAddress("L",path:["items","b","children","kid"])))
        try b.replaceText(in:kid,range:0..<0,with:"X");try exchange(a,b)
        #expect(try a.document == b.document && a.text(in:f) == "b peer" && a.text(in:kid) == "Xkid")
        let moved=try #require(a.document.blocks[0].fields["items"]?.array?[0]["children"]?.array?[1]); #expect(moved["checked"] == .bool(true) && moved["consumer"] == .string("keep-b"))
        let reopened=try ModernSession.restore(a.save(),actorID:actor);try reopened.undo()
        #expect(reopened.document.blocks[0].fields["items"]?.array?.map { $0["id"]?.string } == ["a","b","c","d"] && !reopened.canUndo)
        #expect(try reopened.text(in:f) == "b peer" && reopened.resolve(caret).address.identity == n[0])
        try reopened.redo();#expect(reopened.document == a.document && reopened.document != before)
    }
    @Test func multiItemOutdentKeepsUnselectedChildrenAndReopenedPeerEdits() throws {
        let doc=try document([list(items:[item("a",children:[item("b"),item("c",checked:true),item("remaining")]),item("d")])]),a=try session("a",doc),b=try session("b",doc)
        let nodes=try [node(a,"b",path:["items","a","children","b"]),node(a,"c",path:["items","a","children","c"])], f=try a.field(node:nodes[0])
        _ = try a.listStructure(target(a,nodes),action:.outdent)
        #expect(a.document.blocks[0].fields["items"]?.array?.map { $0["id"]?.string } == ["a","b","c","d"])
        #expect(a.document.blocks[0].fields["items"]?.array?[0]["children"]?.array?.map { $0["id"]?.string } == ["remaining"])
        try b.replaceText(in:f,range:1..<1,with:" peer");try exchange(a,b);#expect(a.document == b.document)
        let reopened=try ModernSession.restore(a.save(),actorID:"a");try reopened.undo();#expect(try reopened.node(at:NodeAddress("L",path:["items","a","children","b"])) == nodes[0] && reopened.text(in:f) == "b peer")
        try reopened.redo();#expect(reopened.document == a.document)
    }
    @Test func styleChangesDeduplicateContainingOwnersAndPreserveCheckedRichAndOpaqueFields() throws {
        let doc=try document([list(),list("M",style:"unordered",items:[item("m")])]),a=try session("a",doc)
        let selection=try target(a,[node(a,"b"),node(a,"c"),a.node(at:NodeAddress("M"))]),before=a.document
        _ = try a.listStructure(selection,action:.setStyle,style:"ordered")
        #expect(a.document.blocks.allSatisfy { $0.fields["style"] == .string("ordered") })
        #expect(a.document.blocks[0].fields["items"] == before.blocks[0].fields["items"] && a.document.blocks[0].fields["consumer"] == .string("root"))
        guard case .edit(let ops)=try a.changes().changes.last?.body,case .listStructure(let descriptor)=ops.first else { Issue.record("Missing list plan");return }
        #expect(descriptor.operations.count == 2)
        let saved=try a.save(); _ = try a.listStructure(target(a,selection.selection.nodes),action:.setStyle,style:"ordered");#expect(try a.save() == saved)
        let reopened=try ModernSession.restore(a.save(),actorID:"a");try reopened.undo();#expect(reopened.document == before);try reopened.redo();#expect(reopened.document == a.document)
    }
    @Test func checklistUpdatesOnlyChangedItemsAndOneUndoRetainsDisjointPeerWrites() throws {
        let a=try session("a"),b=try session("b"),nodes=try [node(a,"a"),node(a,"b")]
        _ = try a.listStructure(target(a,nodes),action:.setChecked,checked:false)
        _ = try b.listStructure(target(b,nodes),action:.setChecked,checked:true)
        try exchange(a,b)
        let items=try #require(a.document.blocks[0].fields["items"]?.array);#expect(items[0]["checked"] == .bool(true) && items[1]["checked"] == .bool(false))
        let reopened=try ModernSession.restore(a.save(),actorID:"a");try reopened.undo();#expect(reopened.document.blocks[0].fields["items"]?.array?[0]["checked"] == .bool(true) && reopened.document.blocks[0].fields["items"]?.array?[1]["checked"] == .bool(true))
        try reopened.redo();#expect(reopened.document == a.document)
        let saved=try a.save();_ = try a.listStructure(target(a,[nodes[0]]),action:.setChecked,checked:true);#expect(try a.save() == saved)
    }
    @Test func concurrentListStylesConvergeAndUndoRevealsPeerWinner() throws {
        let doc=try document([list(style:"unordered")]),a=try session("a",doc),b=try session("b",doc),root=try a.node(at:NodeAddress("L"))
        _ = try a.listStructure(target(a,[root]),action:.setStyle,style:"ordered");_ = try b.listStructure(target(b,[root]),action:.setStyle,style:"todo")
        try exchange(a,b);#expect(a.document == b.document && a.document.blocks[0].fields["style"] == .string("todo"))
        try b.undo();try exchange(a,b);#expect(a.document.blocks[0].fields["style"] == .string("ordered"))
        try a.undo();try exchange(a,b);#expect(a.document == doc)
    }
    @Test func capturedItemsFollowObservedPeerMovesBeforeStyleAndChecklistCommands() throws {
        let doc=try document([list(items:[item("a"),item("b"),item("c")]),list("M",style:"todo",items:[item("m")])]),a=try session("a",doc),b=try session("b",doc)
        let id=try node(a,"b"), captured=try target(a,[id]), f=try a.field(node:id)
        let boundary = try b.captureListBoundary(in:NodeCollection(owner:b.node(at:NodeAddress("M")),field:"items"),after:node(b,"m",root:"M"))
        _ = try b.listStructure(ModernListTarget(selection:b.captureListNodes([id]),boundary:boundary),action:.reorder);try a.receive(b.changes())
        _ = try a.listStructure(captured,action:.setChecked,checked:true)
        #expect(try a.node(at:NodeAddress("M",path:["items","b"])) == id)
        _ = try a.listStructure(captured,action:.setStyle,style:"ordered")
        #expect(try a.text(in:f) == "b" && a.document.blocks[0].fields["style"] == .string("todo") && a.document.blocks[1].fields["style"] == .string("ordered"))
        try exchange(a,b);#expect(a.document == b.document)
    }
    @Test func hierarchyHistoryRetainsLateBirthRecoveryUntilCreatorPacketArrives() throws {
        let doc=try document([.object(["id":.string("A"),"type":.string("paragraph"),"content":plain("ABC")])]),a=try session("a",doc),b=try session("b",doc),receiver=try session("receiver",doc)
        let source=try a.field(node:a.node(at:NodeAddress("A")))
        _ = try a.convertBlock(in:a.captureTextRange(in:source,start:1,end:1),to:WritingBlockTarget(type:"list"));let birth=try a.changes();try b.receive(birth)
        let f=try b.field(node:b.node(at:NodeAddress("A",path:["items","A-item"])))
        let split=try b.splitBlock(in:b.captureTextRange(in:f,start:1,end:1),newBlockID:"tail")
        guard case .text(let caret)=split.focus else { Issue.record("Missing split field");return }
        _ = try b.listStructure(target(b,[caret.field.node]),action:.indent)
        let incremental=try b.changes(since:WritingSyncState(documentID:b.documentID,epoch:b.epoch,received:birth.changes.map(\.id),version:7))
        #expect(throws:ModernSessionError.self){try receiver.receive(incremental)};#expect(receiver.mergeRecovery?.reason == .schemaConstraint && receiver.syncState.received.isEmpty)
        try receiver.receive(birth);#expect(receiver.mergeRecovery == nil && receiver.document == b.document)
        let reopened=try ModernSession.restore(receiver.save(),actorID:"receiver");#expect(reopened.document == b.document)
    }
    @Test func peerStyleAndChecklistHistorySurviveListCreationUndoAndRedo() throws {
        let doc=try document([.object(["id":.string("A"),"type":.string("paragraph"),"content":plain("ABC")])]),a=try session("a",doc),b=try session("b",doc),source=try a.field(node:a.node(at:NodeAddress("A")))
        _ = try a.convertBlock(in:a.captureTextRange(in:source,start:0,end:0),to:WritingBlockTarget(type:"list",style:"todo"));try b.receive(a.changes())
        let item=try b.node(at:NodeAddress("A",path:["items","A-item"]))
        _ = try b.listStructure(target(b,[item]),action:.setChecked,checked:true)
        _ = try b.listStructure(target(b,[item]),action:.setStyle,style:"ordered")
        try a.undo();try exchange(a,b)
        #expect(a.document == b.document && a.document.blocks[0].type == "paragraph" && a.document.blocks[0].fields["style"] == .string("ordered"))
        let reopened=try ModernSession.restore(a.save(),actorID:"a");try reopened.redo()
        #expect(reopened.document.blocks[0].type == "list" && reopened.document.blocks[0].fields["style"] == .string("ordered") && reopened.document.blocks[0].fields["items"]?.array?[0]["checked"] == .bool(true))
        try b.receive(reopened.changes());#expect(b.document == reopened.document)
    }
    @Test func concurrentNestedMovesPreserveBothAuthorsAndUndoUsesRemainingPlacement() throws {
        let a=try session("a"),b=try session("b"),ids=try [node(a,"b"),node(a,"c")]
        _ = try a.listStructure(target(a,ids),action:.indent);_ = try b.listStructure(target(b,[ids[1]]),action:.indent)
        try exchange(a,b);#expect(a.document == b.document)
        #expect(try a.node(at:NodeAddress("L",path:["items","a","children","b","children","c"])) == ids[1])
        try b.undo();try exchange(a,b);#expect(try a.node(at:NodeAddress("L",path:["items","a","children","c"])) == ids[1])
        try a.undo();try exchange(a,b);#expect(a.document == (try document()))
    }
    @Test(arguments:["first","rootOutdent","noncontiguous","reverse","ancestor","wrongCaret","crossList","collision"])
    func invalidHierarchyTargetsRejectWithoutStateHistoryOrReceiptChanges(fault: String) throws {
        var blocks=[list(),list("M",items:[item("m")])]
        if fault == "collision" { blocks[0] = list(items:[item("a",children:[item("b")]),item("b")]) }
        let a=try session("a",document(blocks)), saved=try a.save(), receipt=a.syncState
        let action:ModernListAction=fault == "rootOutdent" ? .outdent:.indent
        #expect(throws:(any Error).self){
            let nodes:[NodeID]
            switch fault {
            case "first":nodes=try [node(a,"a")]
            case "noncontiguous":nodes=try [node(a,"b"),node(a,"d")]
            case "reverse":nodes=try [node(a,"c"),node(a,"b")]
            case "ancestor":nodes=try [node(a,"b"),node(a,"kid",path:["items","b","children","kid"])]
            case "crossList":nodes=try [node(a,"b"),node(a,"m",root:"M")]
            default:nodes=try [node(a,"b")]
            }
            let caret=fault == "wrongCaret" ? try a.position(in:a.field(node:node(a,"a")),offset:0):nil
            _ = try a.listStructure(target(a,nodes,caret:caret),action:action)
        }
        #expect(try a.save() == saved && a.syncState == receipt && a.mergeRecovery == nil)
    }
    @Test func compositionAndReducedActionPolicyRejectLocalStyleButPreserveRemoteStyleAndChecks() throws {
        let a=try session("a"),b=try session("b"),id=try node(a,"b"),captured=try target(a,[id]),before=try a.save()
        a.isComposing=true;#expect(throws:ModernSessionError.compositionActive){_ = try a.listStructure(captured,action:.indent)};a.isComposing=false
        a.allowedCommands=["listStructure","undo"];a.allowedListActions=[.setChecked]
        #expect(throws:ModernSessionError.unavailable("hostPolicy")){_ = try a.listStructure(captured,action:.setStyle,style:"ordered")};#expect(try a.save() == before)
        _ = try b.listStructure(target(b,[id]),action:.setStyle,style:"ordered");try a.receive(b.changes())
        #expect(a.document == b.document)
        #expect(throws:EditorError.self){_ = try a.listStructure(captured,action:.setChecked,checked:false)}
        a.allowedListActions=nil;_ = try a.listStructure(captured,action:.setStyle,style:"todo")
        a.allowedListActions=[.setChecked];_ = try a.listStructure(target(a,[id]),action:.setChecked,checked:false)
        #expect(a.document.blocks[0].fields["items"]?.array?[1]["checked"] == .bool(false))
    }
    @Test func reorderBetweenListsPreservesOriginsCheckedStatePeerTextAndNoopHistory() throws {
        let doc=try document([list(),list("M",items:[item("m")])]),a=try session("a",doc),b=try session("b",doc),ids=try [node(a,"b"),node(a,"c")]
        let owner=try a.node(at:NodeAddress("M")), anchor=try node(a,"m",root:"M"), f=try a.field(node:ids[0]), caret=try a.position(in:f,offset:1)
        let boundary=try a.captureListBoundary(in:NodeCollection(owner:owner,field:"items"),after:anchor)
        let selected=try a.captureListNodes(ids), captured=ModernListTarget(selection:selected,caret:caret,boundary:boundary)
        _ = try a.listStructure(captured,action:.reorder)
        #expect(try a.node(at:NodeAddress("M",path:["items","b"])) == ids[0] && a.resolve(caret).address.identity == ids[0])
        #expect(a.document.blocks[0].fields["items"]?.array?.map{$0["id"]?.string} == ["a","d"] && a.document.blocks[1].fields["items"]?.array?.map{$0["id"]?.string} == ["m","b","c"])
        try b.replaceText(in:f,range:1..<1,with:" peer");try exchange(a,b)
        let saved=try a.save(), fresh=ModernListTarget(selection:try a.captureListNodes(ids),caret:caret,boundary:try a.captureListBoundary(in:boundary.collection,after:anchor))
        _ = try a.listStructure(fresh,action:.reorder);#expect(try a.save() == saved)
        let reopened=try ModernSession.restore(a.save(),actorID:"a");try reopened.undo()
        #expect(try reopened.node(at:NodeAddress("L",path:["items","b"])) == ids[0] && reopened.text(in:f) == "b peer")
        try reopened.redo();#expect(reopened.document == a.document && reopened.document == b.document)
    }
    @Test func genericBlockCommandsKeepItemTableAndDocumentBoundariesClosed() throws {
        let a=try session("a"),id=try node(a,"b"),saved=try a.save()
        #expect(throws:EditorError.self){_ = try a.captureNodes([id])}
        #expect(throws:EditorError.self){try a.move(id,into:.root)}
        #expect(throws:EditorError.self){_ = try a.insertBlock(Block.paragraph(id:"p",text:"P"),into:NodeCollection(owner:id,field:"children"))}
        #expect(throws:EditorError.self){_ = try a.captureListBoundary(in:.root)}
        #expect(throws:EditorError.self){_ = try a.listStructure(target(a,[a.node(at:NodeAddress("L"))]),action:.indent)}
        #expect(try a.save() == saved && a.syncState.received.isEmpty)
    }
    @Test(arguments:["delete","rootMove","wrongPlacement","wrongAnchor","extraSetter","duplicate","empty","wrongScope","futureCapture","futureCaret"])
    func forgedListPlansRejectEvenWhenDisabledWithoutAcknowledgment(fault:String) throws {
        let a=try session("a"),id=try node(a,"b");_ = try a.listStructure(target(a,[id]),action:.indent)
        let change=try #require(try a.changes().changes.last)
        guard case .edit(let edits)=change.body,case .listStructure(let honest)=edits.first else { Issue.record("Missing list proof");return }
        var operations=honest.operations, selection=honest.target.selection, caret=honest.target.caret
        switch fault {
        case "delete":operations=[.structure(.deleteNodes(identities:[id]))]
        case "extraSetter":operations.append(.structure(.setNodeField(identity:id,path:["consumer"],value:.bool(false))))
        case "duplicate":operations += operations
        case "empty":operations=[]
        case "wrongScope":selection=ModernNodeSelection(documentID:"wrong",epoch:selection.epoch,nodes:selection.nodes,observed:selection.observed)
        case "futureCapture":selection=ModernNodeSelection(documentID:selection.documentID,epoch:selection.epoch,nodes:selection.nodes,observed:[change.id])
        case "futureCaret":caret=WritingPosition(documentID:a.documentID,epoch:a.epoch,field:WritingField(node:id,name:"content"),anchor:WritingAtomKey(origin:WritingField(node:id,name:"content"),element:ElementID(change:change.id,index:77)),affinity:.after)
        default:
            guard case .structure(.moveNode(let node,let collection,let placement,let after))=operations[0] else { Issue.record("Missing move");return }
            operations[0] = .structure(.moveNode(identity:node,collection:fault == "rootMove" ? .root:collection,
                placement:fault == "wrongPlacement" ? ElementID(change:placement.change,index:placement.index+1):placement,
                after:fault == "wrongAnchor" ? .initial(try self.node(a,"d")):after))
        }
        let malformed=ModernListStructure(target:ModernListTarget(selection:selection,caret:caret),action:honest.action,style:honest.style,checked:honest.checked,operations:operations)
        for inactive in [false,true] {
            let receiver=try session("receiver"),saved=try receiver.save(),receipt=receiver.syncState
            var changes=[ModernChange(id:change.id,observed:change.observed,body:.edit([.listStructure(malformed)]))]
            if inactive { changes.append(ModernChange(id:ChangeID(counter:change.id.counter+1,actor:change.id.actor),observed:[change.id],body:.setActive(targets:[change.id],active:false))) }
            #expect(throws:(any Error).self){try receiver.receive(ModernBatch(documentID:a.documentID,epoch:a.epoch,baseline:a.baseline,changes:changes))}
            #expect(try receiver.save() == saved && receiver.syncState == receipt && receiver.mergeRecovery == nil)
        }
    }
    @Test func inactiveInlineConversionDoesNotConflictWithPeerCodeShape() throws {
        let doc=try document([.object(["id":.string("A"),"type":.string("paragraph"),"content":plain("ABC")])]),a=try session("z",doc),b=try session("a",doc),f=try a.field(node:a.node(at:NodeAddress("A")))
        _ = try a.convertBlock(in:a.captureTextRange(in:f,start:1,end:1),to:WritingBlockTarget(type:"heading",level:2))
        _ = try b.convertBlock(in:b.captureTextRange(in:f,start:1,end:1),to:WritingBlockTarget(type:"code"))
        try a.undo();try exchange(a,b)
        #expect(a.document == b.document && a.document.blocks[0].type == "code" && a.document.blocks[0].fields["code"] == .string("ABC"))
        let reopened=try ModernSession.restore(a.save(),actorID:"z");#expect(reopened.document == a.document)
    }

    @Test func directListStyleConversionPreservesPeerStyleAfterCreatorUndo() throws {
        let doc=try document([.object(["id":.string("A"),"type":.string("paragraph"),"content":plain("ABC")])]),a=try session("a",doc),b=try session("b",doc),f=try a.field(node:a.node(at:NodeAddress("A")))
        _ = try a.convertBlock(in:a.captureTextRange(in:f,start:0,end:0),to:WritingBlockTarget(type:"list"));try b.receive(a.changes())
        let item=try b.field(node:b.node(at:NodeAddress("A",path:["items","A-item"])))
        _ = try b.convertBlock(in:b.captureTextRange(in:item,start:0,end:0),to:WritingBlockTarget(type:"list",style:"ordered"))
        try a.undo();try exchange(a,b);#expect(a.document == b.document && a.document.blocks[0].type == "paragraph" && a.document.blocks[0].fields["style"] == .string("ordered"))
        let reopened=try ModernSession.restore(a.save(),actorID:"a");try reopened.redo();#expect(reopened.document.blocks[0].type == "list" && reopened.document.blocks[0].fields["style"] == .string("ordered"))
    }
    @Test func activeInlineCodeUnionRetainsAcceptedStateUntilAuthorRepair() throws {
        let doc=try document([.object(["id":.string("A"),"type":.string("paragraph"),"content":plain("ABC")])]),a=try session("z",doc),b=try session("a",doc),f=try a.field(node:a.node(at:NodeAddress("A")))
        _ = try a.convertBlock(in:a.captureTextRange(in:f,start:1,end:1),to:WritingBlockTarget(type:"heading",level:2))
        _ = try b.convertBlock(in:b.captureTextRange(in:f,start:1,end:1),to:WritingBlockTarget(type:"code"))
        let own=try #require(try a.changes().changes.last),accepted=a.document,receipt=a.syncState
        #expect(throws:ModernSessionError.self){try a.receive(b.changes())};#expect(a.document == accepted && a.syncState == receipt && a.mergeRecovery?.reason == .schemaConstraint)
        let saved=try a.save(),recovery=try #require(try a.exportRecovery()),reopened=try ModernSession.restore(saved,actorID:"z")
        #expect(throws:ModernSessionError.self){try reopened.restoreRecovery(recovery)}
        try reopened.repairUndo([own.id]);try b.receive(reopened.changes());#expect(reopened.mergeRecovery == nil && reopened.document == b.document && reopened.document.blocks[0].fields["code"] == .string("ABC"))
    }
    @Test func nativeJSONEnvelopeChecksListArgumentsPolicyCapturesAndFocus() throws {
        let bridge=EditorBridge(),doc=try document()
        func value<T:Encodable>(_ value:T)throws->JSONValue{try JSONDecoder().decode(JSONValue.self,from:JSONEncoder().encode(value))}
        func call(_ command:String,_ args:[String:JSONValue]=[:])throws->JSONValue{
            var input=args;input["command"] = .string(command);input["session"] = .string("list")
            return try JSONDecoder().decode(JSONValue.self,from:bridge.call(JSONEncoder().encode(input)))
        }
        func success(_ result:JSONValue)throws->JSONValue{#expect(result["ok"] == .bool(true));return try #require(result["value"])}
        _ = try success(call("createModern",["actorID":.string("list"),"documentID":.string(doc.documentID),"epoch":.string("lists"),"collaborationVersion":.number(7),"document":.object(doc.fields),"allowedListActions":.array([.string("setChecked"),.string("reorder")])]))
        let id=NodeID.baseline(blockID:"L",path:["items","b"]),selected=try success(call("modernCaptureListNodes",["nodes":value([id])]))
        let capability=try success(call("modernCapabilities"));#expect(capability["listActions"] == .array([.string("reorder"),.string("setChecked")]))
        let before=try success(call("modernSave"))
        func command(_ args:[String:JSONValue])throws->JSONValue{
            try call("modernCommand",["request":.object(["documentID":.string(doc.documentID),"epoch":.string("lists"),"command":.string("listStructure"),"target":.object(["selection":selected]),"arguments":.object(args)])])
        }
        let denied=try success(command(["action":.string("setStyle"),"style":.string("ordered")]));#expect(denied["status"] == .string("unavailable") && denied["reason"] == .string("hostPolicy"))
        let malformed=try success(command(["action":.string("setChecked"),"checked":.number(0)]));#expect(malformed["status"] == .string("unavailable") && malformed["transaction"] == .null)
        #expect(try success(call("modernSave")) == before)
        let checked=try success(command(["action":.string("setChecked"),"checked":.bool(false)]))
        #expect(try checked["status"] == .string("applied") && checked["transaction"]?["actor"] == .string("list") && checked["selectionIntent"]?["nodes"]?["_0"]?["nodes"] == (try value([id])))
        #expect(checked["document"]?["blocks"]?.array?[0]["items"]?.array?[1]["checked"] == .bool(false))
        _ = try success(call("modernSetListPolicy",["allowedListActions":.null]))
        let changed=try success(command(["action":.string("setStyle"),"style":.string("ordered")]))
        #expect(changed["status"] == .string("applied") && changed["document"]?["blocks"]?.array?[0]["style"] == .string("ordered"))
    }

}
