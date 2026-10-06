@testable import BlockEditorCore
import Foundation
import Testing

@Suite struct ModernListRoleTests {
    private func document(_ blocks: [JSONValue]) throws -> ModernDocument {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        var fields = try ModernDocument(json: Data(contentsOf: root.appendingPathComponent("docs/acceptance/modern-editor/documents/unicode.json"))).fields
        fields["blocks"] = .array(blocks); return try ModernDocument(fields: fields)
    }
    private func text(_ value: String) -> JSONValue { .array([.object(["type": .string("text"), "text": .string(value)])]) }
    private func list(empty: Int = 1, exhaust: Bool = false) -> JSONValue {
        .object(["id": .string("list"), "type": .string("list"), "style": .string("todo"), "rootExtra": .string("keep"), "items": .array((0..<3).map { i in
            .object(["id": .string("i\(i)"), "content": text(i == empty || exhaust && i == 0 ? "" : "item\(i)"), "checked": .bool(i == 0), "itemExtra": .number(Double(i)), "children": i == empty ? .array([.object(["id": .string("kid"), "content": text("child"), "childExtra": .bool(true)])]) : .array([])])
        })])
    }
    private func session(_ actor: String, _ document: ModernDocument) throws -> ModernSession { try ModernSession(documentID: document.documentID, actorID: actor, epoch: "roles", document: document) }
    private func field(_ s: ModernSession, _ id: String, path: [String] = [], name: String = "content") throws -> WritingField { try s.field(node: s.node(at: NodeAddress(id, path: path)), name: name) }
    private func exchange(_ a: ModernSession, _ b: ModernSession) throws { let aa = try a.changes(), bb = try b.changes(); try a.receive(bb); try b.receive(aa); try a.receive(bb); try b.receive(aa) }

    @Test(arguments: [0, 1, 2], ["a", "z"])
    func emptyRootExitKeepsOwnerItemChildrenPeerTextAndReopenedUndo(index: Int, actor: String) throws {
        let doc = try document([list(empty: index)]), a = try session(actor, doc), b = try session("m", doc)
        let f = try field(a,"list",path:["items","i\(index)"]), root = try a.node(at: NodeAddress("list")), item = f.node
        let child = try field(a,"list",path:["items","i\(index)","children","kid"])
        let result = try a.splitBlock(in:a.captureTextRange(in:f,start:0,end:0),newBlockID:"tail")
        #expect(a.document.blocks.map(\.id) == (index == 0 ? ["i0","list"] : index == 1 ? ["list","i1","tail"] : ["list","i2"]))
        #expect(try a.node(at:NodeAddress("i\(index)")) == item && a.node(at:NodeAddress("list")) == root)
        let paragraph = try #require(a.document.blocks.first { $0.id == "i\(index)" })
        #expect(paragraph.fields["itemExtra"] == .number(Double(index)) && paragraph.fields["checked"] == .bool(index == 0))
        guard case .text(let caret) = result.focus else { Issue.record("Missing Enter caret"); return }
        #expect(try a.resolve(caret).address.identity == item && a.resolve(caret).offset == 0)
        try b.replaceText(in:f,range:0..<0,with:"peer"); try b.replaceText(in:child,range:0..<0,with:"Y")
        for i in 0..<3 where i != index { try b.replaceText(in:field(b,"list",path:["items","i\(i)"]),range:0..<0,with:"X") }
        try exchange(a,b); #expect(try a.document == b.document && a.text(in:f) == "peer" && a.text(in:child) == "Ychild")
        let reopened = try ModernSession.restore(a.save(),actorID:actor)
        try reopened.undo(); #expect(reopened.document.blocks.count == 1 && reopened.document.blocks[0].id == "list")
        #expect(try reopened.node(at:NodeAddress("list",path:["items","i\(index)"])) == item && reopened.text(in:f) == "peer")
        try reopened.redo(); #expect(reopened.document == a.document)
        _ = try reopened.splitBlock(in:reopened.captureTextRange(in:f,start:2,end:2),newBlockID:"split")
        try b.receive(reopened.changes()); #expect(reopened.document == b.document)
    }
    @Test func nestedEmptyOutdentRetainsMetadataDescendantsCapturedCaretAndUndo() throws {
        let child: JSONValue = .object(["id":.string("nested"),"content":text(""),"checked":.bool(true),"extra":.string("keep"),"children":.array([.object(["id":.string("grandchild"),"content":text("G")])])])
        let block: JSONValue = .object(["id":.string("list"),"type":.string("list"),"style":.string("todo"),"items":.array([.object(["id":.string("outer"),"content":text("O"),"checked":.bool(false),"children":.array([child])])])])
        let doc = try document([block]), a = try session("a",doc), b = try session("b",doc)
        let f = try field(a,"list",path:["items","outer","children","nested"]), kid = try field(a,"list",path:["items","outer","children","nested","children","grandchild"])
        let range = try a.captureTextRange(in:f,start:0,end:0), before = a.document
        _ = try a.splitBlock(in:range,newBlockID:"unused")
        #expect(a.document.blocks[0].fields["items"]?.array?.map { $0["id"]?.string } == ["outer","nested"])
        #expect(try a.resolve(range.start).address.identity == f.node && a.text(in:kid) == "G")
        try b.replaceText(in:f,range:0..<0,with:"peer"); try exchange(a,b)
        #expect(a.document == b.document && a.document.blocks[0].fields["items"]?.array?[1]["extra"] == .string("keep"))
        let reopened = try ModernSession.restore(a.save(),actorID:"a"); try reopened.undo()
        #expect(try reopened.node(at:NodeAddress("list",path:["items","outer","children","nested"])) == f.node && reopened.text(in:f) == "peer")
        try reopened.redo(); #expect(reopened.document == a.document && reopened.document != before)
    }
    private func exposed(_ actor: String = "a") throws -> (ModernSession, ModernSession, WritingField, NodeID) {
        let doc = try document([.object(["id":.string("A"),"type":.string("paragraph"),"content":text("ABC")])])
        let a = try session(actor,doc), b = try session("peer",doc), f = try field(a,"A")
        _ = try a.convertBlock(in:a.captureTextRange(in:f,start:1,end:1),to:WritingBlockTarget(type:"list"))
        try b.receive(a.changes()); let item = try field(b,"A",path:["items","A-item"])
        _ = try b.splitBlock(in:b.captureTextRange(in:item,start:1,end:1),newBlockID:"retained")
        try a.undo(); try exchange(a,b)
        let peer = try field(a,"retained"); #expect(try a.text(in:peer) == "BC")
        return (a,b,peer,f.node)
    }
    @Test(arguments: ["heading","code","list","split","move","delete","insert","columns"])
    func retainedPeerParagraphSupportsModernCommandsAndReopenedHistory(command: String) throws {
        let (a,b,f,root) = try exposed(), before = a.document
        switch command {
        case "heading","code","list": _ = try a.convertBlock(in:a.captureTextRange(in:f,start:1,end:1),to:WritingBlockTarget(type:command))
        case "split": _ = try a.splitBlock(in:a.captureTextRange(in:f,start:1,end:1),newBlockID:"cut")
        case "move": try a.move(f.node,into:.root,after:nil)
        case "delete": try a.delete(f.node)
        case "insert": _ = try a.insertBlock(Block.paragraph(id:"following",text:"F"),at:a.captureBoundary(after:f.node))
        default: _ = try a.createColumns(ModernCreateColumnsTarget(selection:a.captureNodes([root,f.node])),layout:.object(["id":.string("layout"),"type":.string("columns"),"splitBasisPoints":.number(5000),"columns":.array([.object(["id":.string("left"),"children":.array([])]),.object(["id":.string("right"),"children":.array([])])])]))
        }
        try exchange(a,b); #expect(a.document == b.document && a.document != before)
        let reopened = try ModernSession.restore(a.save(),actorID:a.actorID)
        try reopened.undo(); #expect(reopened.document == before)
        try reopened.redo(); #expect(reopened.document == a.document)
    }
    @Test func retainedRoleSurvivesOriginalCreationRedoAndUndoAndKeepsFollowingAnchor() throws {
        let (a,b,f,_) = try exposed()
        _ = try b.convertBlock(in:b.captureTextRange(in:f,start:0,end:0),to:WritingBlockTarget(type:"heading",level:2))
        _ = try b.insertBlock(Block.paragraph(id:"following",text:"F"),at:b.captureBoundary(after:f.node))
        try a.redo(); try exchange(a,b)
        #expect(a.document.blocks.map(\.id) == ["A","retained","following"] && a.document.blocks[1].type == "heading")
        try a.undo(); try exchange(a,b); #expect(a.document == b.document && a.document.blocks[1].type == "heading")
        try b.undo(); try b.undo(); try exchange(a,b)
        #expect(a.document.blocks.map(\.id) == ["A","retained"] && a.document.blocks[1].type == "paragraph")
    }
    @Test func codeBornCaretCanSplitAfterParagraphConversion() throws {
        let doc = try document([.object(["id":.string("C"),"type":.string("code"),"code":.string("ABC")])]), a = try session("a",doc)
        let f = try field(a,"C",name:"code"), range = try a.captureTextRange(in:f,start:1,end:1)
        _ = try a.convertBlock(in:range,to:WritingBlockTarget(type:"paragraph"))
        _ = try a.splitBlock(in:range,newBlockID:"tail")
        #expect(try a.text(in:f) == "A" && a.text(in:field(a,"tail")) == "BC")
        let reopened = try ModernSession.restore(a.save(),actorID:"a"); try reopened.undo(); try reopened.undo(); #expect(reopened.document == doc)
    }
    @Test func capturedEmptyItemWithObservedPeerTypingSplitsWithoutReinterpretingAsExit() throws {
        let doc = try document([list()]), a = try session("a",doc), b = try session("b",doc), f = try field(a,"list",path:["items","i1"])
        let range = try a.captureTextRange(in:f,start:0,end:0)
        try b.replaceText(in:f,range:0..<0,with:"peer"); try a.receive(b.changes())
        _ = try a.splitBlock(in:range,newBlockID:"new")
        #expect(a.document.blocks.count == 1 && a.document.blocks[0].fields["items"]?.array?.count == 4)
        #expect(try a.text(in:f).isEmpty && a.text(in:field(a,"list",path:["items","new"])) == "peer")
        try exchange(a,b); #expect(a.document == b.document)
    }
    @Test(arguments: ["a","z"])
    func concurrentFirstAndLastExitsConvergeWithRetainedOrdinals(actor: String) throws {
        var block = list(empty:0).object!, items = block["items"]!.array!, last = items[2].object!; last["content"] = text(""); items[2] = .object(last); block["items"] = .array(items)
        let doc = try document([.object(block)]), a = try session(actor,doc), b = try session("m",doc)
        _ = try a.splitBlock(in:a.captureTextRange(in:field(a,"list",path:["items","i0"]),start:0,end:0),newBlockID:"unused")
        _ = try b.splitBlock(in:b.captureTextRange(in:field(b,"list",path:["items","i2"]),start:0,end:0),newBlockID:"unused")
        try exchange(a,b); #expect(a.document == b.document && a.document.blocks.map(\.id) == ["i0","list","i2"])
        let reopened = try ModernSession.restore(a.save(),actorID:actor); try reopened.undo(); #expect(reopened.document.blocks.map(\.id) == ["list","i2"])
        try reopened.redo(); #expect(reopened.document == a.document)
    }
    @Test func exhaustedConcurrentPartitionsRemainRecoverableUntilAuthorRepair() throws {
        let doc = try document([list(exhaust:true)]), a = try session("a",doc), b = try session("b",doc)
        _ = try a.splitBlock(in:a.captureTextRange(in:field(a,"list",path:["items","i0"]),start:0,end:0),newBlockID:"unused")
        _ = try b.splitBlock(in:b.captureTextRange(in:field(b,"list",path:["items","i1"]),start:0,end:0),newBlockID:"tail")
        let aa = try a.changes(), bb = try b.changes(), before = a.document
        #expect(throws: ModernSessionError.self) { try a.receive(bb) }; #expect(a.document == before && a.mergeRecovery?.reason == .schemaConstraint)
        let reopened = try ModernSession.restore(a.save(),actorID:"a")
        let recovery = try #require(try a.exportRecovery()); #expect(throws: ModernSessionError.self) { try reopened.restoreRecovery(recovery) }
        try reopened.repairUndo([aa.changes.last!.id]); try b.receive(reopened.changes())
        #expect(reopened.mergeRecovery == nil && reopened.document == b.document)
    }
    @Test(arguments: ["duplicate", "late", "wrongNode", "wrongOwner", "wrongRetirement", "emptyExposure", "oldExposure", "selfAnchor", "futureRetirement", "forgedAnchor", "currentAnchor"])
    func forgedParagraphRolesRejectAtomicallyIncludingDisabledEdits(fault: String) throws {
        let (a,_,f,root) = try exposed()
        let prefix = try a.changes()
        _ = try a.convertBlock(in:a.captureTextRange(in:f,start:0,end:0),to:WritingBlockTarget(type:"heading",level:2))
        let authored = try #require(try a.changes().changes.last)
        guard case .edit(let honest) = authored.body, case .retainParagraphRole(let role) = honest.first else { Issue.record("Missing role proof"); return }
        var operations = honest
        let wrongRetirement = prefix.changes.first { if case .edit = $0.body { return true }; return false }!.id
        let changed = WritingParagraphRole(node:fault == "wrongNode" ? root : role.node, owner:fault == "wrongOwner" ? f.node : role.owner,
            retirement:fault == "futureRetirement" ? authored.id : fault == "wrongRetirement" ? wrongRetirement : role.retirement,
            exposure:fault == "emptyExposure" ? [] : fault == "oldExposure" ? [wrongRetirement] : role.exposure,
            after:fault == "currentAnchor" ? .edit(ElementID(change:authored.id,index:0)) : fault == "selfAnchor" ? .role(owner:role.owner,node:role.node) : fault == "forgedAnchor" ? .initial(.baseline(blockID:"absent",path:[])) : role.after)
        operations[0] = .retainParagraphRole(changed)
        if fault == "duplicate" { operations.insert(operations[0],at:0) }
        if fault == "late" { operations = Array(operations.dropFirst()) + [operations[0]] }
        for inactive in [false,true] {
            let receiver = try session("receiver",a.baseline); try receiver.receive(prefix)
            let saved = try receiver.save(), receipt = receiver.syncState
            var edits = [ModernChange(id:authored.id,observed:authored.observed,body:.edit(operations))]
            if inactive { edits.append(ModernChange(id:ChangeID(counter:authored.id.counter+1,actor:authored.id.actor),observed:[authored.id],body:.setActive(targets:[authored.id],active:false))) }
            #expect(throws: EditorError.self) { try receiver.receive(ModernBatch(documentID:a.documentID,epoch:a.epoch,baseline:a.baseline,changes:edits)) }
            #expect(try receiver.save() == saved && receiver.syncState == receipt && receiver.mergeRecovery == nil)
        }
    }
    @Test(arguments: ["extraDelete", "wrongTail", "wrongRange", "nonempty", "wrongPlacement", "wrongScope"])
    func forgedEmptyEnterPlansRejectWithoutAcknowledgment(fault: String) throws {
        let doc = try document([list()]), author = try session("author",doc), source = try field(author,"list",path:["items","i1"])
        let range = try author.captureTextRange(in:source,start:0,end:0)
        _ = try author.splitBlock(in:range,newBlockID:"tail")
        let change = try #require(try author.changes().changes.last)
        guard case .edit(let edits) = change.body, case .enterListItem(let honest) = edits.first else { Issue.record("Missing Enter plan"); return }
        var operations = honest.operations, captured = honest.range
        switch fault {
        case "extraDelete": operations.append(.structure(.deleteNodes(identities:[source.node])))
        case "wrongTail": operations.removeLast()
        case "wrongPlacement":
            guard case .structure(.moveNode(let node, let collection, let element, let after)) = operations.last else { Issue.record("Missing item move"); return }
            operations[operations.count-1] = .structure(.moveNode(identity:node,collection:collection,placement:ElementID(change:element.change,index:element.index+1),after:after))
        case "wrongScope":
            let start = WritingPosition(documentID:"wrong",epoch:range.start.epoch,field:range.start.field,anchor:range.start.anchor,affinity:range.start.affinity)
            captured = ModernTextRange(start:start,end:range.end,observed:range.observed)
        case "nonempty":
            let field = try field(session("capture",doc),"list",path:["items","i0"])
            let capture = try session("capture",doc); captured = try capture.captureTextRange(in:field,start:0,end:0)
        default:
            let capture = try session("capture",doc), field = try field(capture,"list",path:["items","i0"])
            captured = try capture.captureTextRange(in:field,start:0,end:1)
        }
        let forged = ModernListEnter(range:captured,newBlockID:honest.newBlockID,operations:operations)
        for inactive in [false,true] {
            let receiver = try session("receiver",doc), saved = try receiver.save(), receipt = receiver.syncState
            var changes = [ModernChange(id:change.id,observed:change.observed,body:.edit([.enterListItem(forged)]))]
            if inactive { changes.append(ModernChange(id:ChangeID(counter:change.id.counter+1,actor:change.id.actor),observed:[change.id],body:.setActive(targets:[change.id],active:false))) }
            #expect(throws: EditorError.self) { try receiver.receive(ModernBatch(documentID:receiver.documentID,epoch:receiver.epoch,baseline:doc,changes:changes)) }
            #expect(try receiver.save() == saved && receiver.syncState == receipt && receiver.mergeRecovery == nil)
        }
    }

    @Test func emptyExitAfterColumnFlattenRetainsLogicalPlacementPeerTextAndUndo() throws {
        let layout: JSONValue = .object(["id":.string("layout"),"type":.string("columns"),"splitBasisPoints":.number(5000),"columns":.array([
            .object(["id":.string("left"),"children":.array([list()])]), .object(["id":.string("right"),"children":.array([])])])])
        let doc = try document([layout]), a = try session("a",doc), b = try session("b",doc)
        let f = try field(a,"layout",path:["columns","left","children","list","items","i1"])
        _ = try a.removeColumns(ModernColumnTarget(layout:a.node(at:NodeAddress("layout"))))
        let flattened = a.document
        _ = try a.splitBlock(in:a.captureTextRange(in:f,start:0,end:0),newBlockID:"tail")
        #expect(a.document.blocks.map(\.id) == ["list","i1","tail"])
        try b.replaceText(in:f,range:0..<0,with:"peer"); try exchange(a,b); #expect(try a.document == b.document && a.text(in:f) == "peer")
        let reopened = try ModernSession.restore(a.save(),actorID:"a"); try reopened.undo()
        #expect(try reopened.document.blocks.map(\.id) == flattened.blocks.map(\.id) && reopened.text(in:f) == "peer")
        try reopened.undo(); #expect(reopened.document.blocks[0].id == "layout")
        try reopened.redo(); try reopened.redo(); #expect(reopened.document == a.document)
    }

    @Test func activeExitWhosePeerRestoresColumnsRetainsRecoveryAndAuthorCanRepair() throws {
        let layout: JSONValue = .object(["id":.string("layout"),"type":.string("columns"),"splitBasisPoints":.number(5000),"columns":.array([
            .object(["id":.string("left"),"children":.array([list()])]), .object(["id":.string("right"),"children":.array([])])])])
        let doc = try document([layout]), a = try session("a",doc), b = try session("b",doc)
        let f = try field(a,"layout",path:["columns","left","children","list","items","i1"])
        _ = try a.removeColumns(ModernColumnTarget(layout:a.node(at:NodeAddress("layout")))); try b.receive(a.changes())
        _ = try b.splitBlock(in:b.captureTextRange(in:f,start:0,end:0),newBlockID:"tail")
        let exit = try #require(try b.changes().changes.last)
        try a.undo(); let aa = try a.changes(), bb = try b.changes(), acceptedA = a.document, acceptedB = b.document
        #expect(throws: ModernSessionError.self) { try a.receive(bb) }
        #expect(throws: ModernSessionError.self) { try b.receive(aa) }
        #expect(a.document == acceptedA && b.document == acceptedB && a.mergeRecovery?.reason == .schemaConstraint && b.mergeRecovery?.reason == .schemaConstraint)
        try b.repairUndo([exit.id]); try a.receive(b.changes())
        #expect(a.mergeRecovery == nil && b.mergeRecovery == nil && a.document == doc && a.document == b.document)
    }

}
