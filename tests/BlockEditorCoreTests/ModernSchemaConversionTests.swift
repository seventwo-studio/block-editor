@testable import BlockEditorCore
import Foundation
import Testing

@Suite struct ModernSchemaConversionTests {
    private func fixture(_ name: String = "unicode") throws -> ModernDocument {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return try ModernDocument(json: Data(contentsOf: root.appendingPathComponent("docs/acceptance/modern-editor/documents/\(name).json")))
    }
    private func document(_ block: JSONValue) throws -> ModernDocument {
        var fields = try fixture().fields; fields["blocks"] = .array([block]); return try ModernDocument(fields: fields)
    }
    private func session(_ actor: String, document: ModernDocument? = nil) throws -> ModernSession {
        let doc = try document ?? fixture()
        return try ModernSession(documentID: doc.documentID, actorID: actor, epoch: "schemas", document: doc)
    }
    private func field(_ s: ModernSession, _ address: NodeAddress = NodeAddress("A"), name: String = "content") throws -> WritingField {
        try s.field(node: s.node(at: address), name: name)
    }
    private func convert(_ s: ModernSession, _ f: WritingField, _ type: String, offset: Int = 1, style: String? = nil) throws -> ModernStructuralResult {
        try s.convertBlock(in: s.captureTextRange(in: f, start: offset, end: offset), to: WritingBlockTarget(type: type, style: style))
    }
    private func exchange(_ a: ModernSession, _ b: ModernSession) throws {
        let first = try a.changes(), second = try b.changes(); try a.receive(second); try b.receive(first)
    }
    @Test func codeConversionRetainsCapturedCaretPeerTextAndFieldAliasesThroughUndoRedoAndReopen() throws {
        for peerFirst in [false, true] {
            let a = try session("a"), b = try session("b"), original = try field(a)
            let caret = try a.captureTextRange(in: original, start: 2, end: 2)
            try b.replaceText(in: original, range: 3..<3, with: " peer")
            if peerFirst { try a.receive(b.changes()) }
            let result = try a.convertBlock(in: caret, to: WritingBlockTarget(type: "code"))
            try exchange(a,b)
            #expect(a.document.blocks[0].fields == ["id": .string("A"), "type": .string("code"), "code": .string("ABC peer")])
            #expect(a.document == b.document && a.document.title == "Field notes")
            #expect(try a.resolve(caret.start).address.path.last == "code" && a.resolve(caret.start).offset == 2)
            guard case .text(let focus) = result.focus else { Issue.record("Missing conversion focus"); return }
            #expect(try a.resolve(focus).offset == 2)
            #expect(try a.field(node: original.node) == WritingField(node: original.node, name: "code"))
            #expect(try a.text(in: original) == "ABC peer")
            let reopened = try ModernSession.restore(a.save(), actorID: "a")
            try reopened.undo(); #expect(try reopened.text(in: original) == "ABC peer" && reopened.document.blocks[0].type == "paragraph")
            try reopened.redo(); #expect(reopened.document == a.document)
            let saved = try reopened.save(); try reopened.receive(b.changes()); #expect(try reopened.save() == saved)
        }
    }
    @Test func codeBirthTextCanBecomeRichParagraphWithoutLosingOriginalOriginsOrOpaqueLanguage() throws {
        let doc = try document(.object(["id": .string("A"), "type": .string("code"), "code": .string("ABC"), "language": .string("swift"), "consumer": .object(["x": .bool(true)])]))
        let a = try session("a", document: doc), original = try field(a, name: "code")
        let captured = try a.captureTextRange(in: original, start: 1, end: 2)
        _ = try convert(a, original, "paragraph")
        #expect(try a.text(in: original) == "ABC" && a.document.blocks[0].fields["language"] == .string("swift"))
        try a.format(in: captured, markType: "bold", mark: .object(["type": .string("bold")]))
        #expect(a.document.blocks[0].fields["content"]?.array?[1]["marks"] == .array([.object(["type": .string("bold")])]))
        let reopened = try ModernSession.restore(a.save(), actorID: "a")
        try reopened.undo(); try reopened.undo(); #expect(reopened.document == doc)
        try reopened.redo(); try reopened.redo(); #expect(reopened.document == a.document)
    }
    @Test func textAuthoredAtConvertedCodeBirthFollowsConversionUndoAndCapturedReplacementAliases() throws {
        let a = try session("a"), b = try session("b"), old = try field(a)
        let before = try a.captureTextRange(in: old, start: 1, end: 2)
        _ = try convert(a, old, "code")
        try b.receive(a.changes()); let code = try field(b, name: "code")
        _ = try b.replaceText(in: before, with: "X")
        try exchange(a,b); #expect(a.document.blocks[0].fields["code"] == .string("AXC"))
        try a.undo(); #expect(try a.text(in: old) == "AXC" && a.document.blocks[0].type == "paragraph")
        #expect(try a.resolve(b.position(in: code, offset: 2)).address.path.last == "content")
        try a.redo(); #expect(a.document.blocks[0].fields["code"] == .string("AXC"))
        #expect(try ModernSession.restore(a.save(), actorID: "a").document == a.document)
    }
    @Test func listConversionPreservesAtomsCaretPeerReplacementAndChecklistStateThroughUndo() throws {
        let a = try session("a"), b = try session("b"), old = try field(a)
        let caret = try a.position(in: old, offset: 2)
        _ = try convert(a, old, "list", style: "todo")
        let item = try field(a, NodeAddress("A", path: ["items", "A-item"]))
        #expect(try a.text(in: item) == "ABC" && a.resolve(caret).address.identity == item.node && a.resolve(caret).offset == 2)
        #expect(a.document.blocks[0].fields["items"]?.array?[0]["checked"] == .bool(false))
        try b.receive(a.changes()); try b.replaceText(in: item, range: 1..<2, with: "X")
        try exchange(a,b); #expect(try a.text(in: old) == "AXC")
        try a.undo(); #expect(try a.text(in: old) == "AXC" && a.document.blocks[0].type == "paragraph")
        let reopened = try ModernSession.restore(a.save(), actorID: "a")
        try reopened.redo(); #expect(try reopened.text(in: item) == "AXC")
        #expect(try reopened.resolve(caret).address.identity == item.node)
    }
    @Test func soleListItemCollapseRetainsCheckedMetadataChildOriginsPeerTextAndUndo() throws {
        let block = try JSONDecoder().decode(JSONValue.self, from: Data("""
        {"id":"A","type":"list","style":"todo","consumer":"root","items":[
          {"id":"one","content":[{"type":"text","text":"ABC"}],"checked":true,"itemExtra":"retain","children":[
            {"id":"child","content":[{"type":"text","text":"kid"}]}]}]}
        """.utf8))
        let doc = try document(block)
        let a = try session("a", document: doc), b = try session("b", document: doc)
        let source = try field(a, NodeAddress("A", path: ["items", "one"])), child = try field(a, NodeAddress("A", path: ["items", "one", "children", "child"]))
        _ = try convert(a, source, "paragraph")
        #expect(a.document.blocks[0].type == "paragraph" && a.document.blocks[0].fields["checked"] == .bool(true) && a.document.blocks[0].fields["itemExtra"] == .string("retain"))
        #expect(try a.text(in: child) == "kid" && a.text(in: source) == "ABC")
        try b.replaceText(in: source, range: 3..<3, with: " peer")
        try exchange(a,b); #expect(try a.text(in: source) == "ABC peer" && a.document == b.document)
        let reopened = try ModernSession.restore(a.save(), actorID: "a")
        try reopened.undo(); #expect(reopened.document.blocks[0].type == "list"); #expect(try reopened.text(in: source) == "ABC peer" && reopened.text(in: child) == "kid")
        try reopened.redo(); #expect(reopened.document == a.document)
    }
    @Test func undoListConversionExposesPeerSplitAsRetainedParagraphInsteadOfDroppingIt() throws {
        let a = try session("a"), b = try session("b"), old = try field(a)
        _ = try convert(a, old, "list")
        try b.receive(a.changes()); let item = try field(b, NodeAddress("A", path: ["items", "A-item"]))
        _ = try b.splitBlock(in: b.captureTextRange(in: item, start: 1, end: 1), newBlockID: "tail")
        try exchange(a,b); try a.undo()
        #expect(a.document.blocks.prefix(2).map(\.id) == ["A", "tail"] && a.document.blocks[1].type == "paragraph")
        #expect(try a.text(in: old) == "A" && a.text(in: field(a, NodeAddress("tail"))) == "BC")
        let reopened = try ModernSession.restore(a.save(), actorID: "a")
        try reopened.redo(); #expect(reopened.document.blocks[0].fields["items"]?.array?.count == 2)
        try b.receive(reopened.changes()); #expect(b.document == reopened.document)
    }
    @Test func richCodeConversionAndOpaqueFieldCollisionsRejectWithoutChangingSavedHistory() throws {
        for name in ["mixed", "unicode"] {
            var doc = try fixture(name)
            if name == "unicode" {
                var fields = doc.fields, blocks = fields["blocks"]!.array!, first = blocks[0].object!
                first["code"] = .string("consumer-owned"); blocks[0] = .object(first); fields["blocks"] = .array(blocks); doc = try ModernDocument(fields: fields)
            }
            let a = try session("a", document: doc), f = try field(a), saved = try a.save()
            #expect(throws: EditorError.self) { try convert(a, f, "code") }
            #expect(try a.save() == saved && a.mergeRecovery == nil)
        }
        var multiFields = try fixture("nested").fields, multiBlocks = multiFields["blocks"]!.array!, list = multiBlocks[1].object!
        list["items"] = .array(list["items"]!.array! + [.object(["id": .string("two"), "content": .array([])])])
        multiBlocks[1] = .object(list); multiFields["blocks"] = .array(multiBlocks)
        let a = try session("a", document: ModernDocument(fields: multiFields)), f = try field(a, NodeAddress("list", path: ["items", "same"])), saved = try a.save()
        #expect(throws: EditorError.self) { try convert(a, f, "paragraph", offset: 0) }
        #expect(try a.save() == saved)
    }
    @Test func concurrentCodeConversionsConvergeAndEachUndoKeepsPeerHead() throws {
        let a = try session("a"), b = try session("b"), f = try field(a)
        _ = try convert(a,f,"code"); _ = try convert(b,f,"code")
        try exchange(a,b); #expect(a.document == b.document && a.document.blocks[0].fields["code"] == .string("ABC"))
        try a.undo(); try exchange(a,b); #expect(a.document.blocks[0].type == "code")
        try b.undo(); try exchange(a,b); #expect(a.document == (try fixture()) && a.document == b.document)
    }
    @Test func concurrentListConversionsRetainRecoveryUntilOwnUndoKeepsPeerBranch() throws {
        let a = try session("a"), b = try session("b"), f = try field(a)
        _ = try convert(a,f,"list"); _ = try convert(b,f,"list",style:"todo")
        let accepted = a.document
        #expect(throws: ModernSessionError.self) { try a.receive(b.changes()) }
        #expect(a.document == accepted && a.mergeRecovery != nil)
        let exported = try a.exportRecovery(), pending = try #require(exported), own = try #require(a.syncState.received.first)
        let reopened = try ModernSession.restore(a.save(),actorID:"a")
        #expect(throws: ModernSessionError.self) { try reopened.restoreRecovery(pending) }
        try reopened.repairUndo([own]); #expect(reopened.mergeRecovery == nil && reopened.document.blocks[0].fields["style"] == .string("todo"))
        try b.receive(reopened.changes()); #expect(b.document == reopened.document)
    }
    @Test func codeFieldPacketArrivingBeforeBaselineAliasBirthRetainsThenResolvesRecovery() throws {
        let a = try session("a"), receiver = try session("r"), old = try field(a)
        _ = try convert(a,old,"code"); let birth = try a.changes(), receipt = a.syncState
        try a.replaceText(in: old, range: 1..<2, with: "X")
        let delta = try a.changes(since: receipt), accepted = receiver.document
        #expect(throws: ModernSessionError.self) { try receiver.receive(delta) }
        #expect(receiver.document == accepted && receiver.mergeRecovery != nil)
        let exported = try receiver.exportRecovery(), pending = try #require(exported)
        let reopened = try ModernSession.restore(receiver.save(),actorID:"r")
        #expect(throws: ModernSessionError.self) { try reopened.restoreRecovery(pending) }
        try reopened.receive(birth); #expect(reopened.mergeRecovery == nil && reopened.document == a.document)
    }
    @Test func malformedInactiveSchemaConversionRejectsBeforeMissingPredecessorAndKeepsReceipt() throws {
        let a = try session("a"), id = ChangeID(counter: 2,actor:"peer"), absent = ChangeID(counter:1,actor:"peer"), root = try a.node(at:NodeAddress("A"))
        let conversion = WritingSchemaConversion(node:root,type:"list",attributes:["style":.string("invalid")],source:WritingField(node:root,name:"content"),destination:WritingField(node:.inserted(creation:ElementID(change:id,index:0),path:[]),name:"content"),itemID:"A-item",creation:ElementID(change:id,index:0),preservedItemFields:[:])
        let bad = ModernChange(id:id,observed:[absent],body:.edit([.schemaConvert(conversion)]))
        let disabled = ModernChange(id:ChangeID(counter:3,actor:"peer"),observed:[id],body:.setActive(targets:[id],active:false))
        let saved = try a.save(), receipt = a.syncState
        #expect(throws: EditorError.self) { try a.receive(ModernBatch(documentID:a.documentID,epoch:a.epoch,baseline:a.baseline,changes:[bad,disabled])) }
        #expect(try a.save() == saved && a.syncState == receipt && a.mergeRecovery == nil)
    }
    @Test func soleEmptyChecklistEnterPreservesOwnerChildOriginsAndPeerTextThroughUndoReopen() throws {
        let a = try session("a", document: fixture("nested")), b = try session("b", document: fixture("nested"))
        let source = try field(a, NodeAddress("toggle", path: ["children", "todo", "items", "same"]))
        let child = try field(a, NodeAddress("toggle", path: ["children", "todo", "items", "same", "children", "child"]))
        try a.replaceText(in: source, range: 0..<10, with: "")
        try b.receive(a.changes())
        let capture = try a.captureTextRange(in: source, start: 0, end: 0), original = a.document
        let result = try a.splitBlock(in: capture, newBlockID: "unused")
        #expect(a.document.blocks[0].fields["children"]?.array?[1]["type"] == .string("paragraph"))
        #expect(try a.text(in: child) == "Nested task")
        guard case .text(let focus) = result.focus else { Issue.record("Missing Enter focus"); return }
        #expect(try a.resolve(focus).offset == 0 && a.resolve(focus).address.identity == a.node(at: NodeAddress("toggle", path: ["children", "todo"])))
        try b.replaceText(in: source, range: 0..<0, with: "peer")
        try exchange(a,b); #expect(try a.text(in: source) == "peer" && a.document == b.document)
        let reopened = try ModernSession.restore(a.save(),actorID:"a")
        try reopened.undo(); #expect(reopened.document.blocks[0].fields["children"]?.array?[1]["type"] == .string("list"))
        #expect(try reopened.text(in: source) == "peer" && reopened.text(in: child) == "Nested task")
        try reopened.redo(); #expect(reopened.document == a.document && reopened.document != original)
    }
    @Test func codeAndListConversionsInsideColumnsKeepLogicalOwnersAcrossFlattenAndUndo() throws {
        let a = try session("a", document: fixture("columns-3000"))
        let root = try a.node(at:NodeAddress("layout")), f = try field(a,NodeAddress("layout",path:["columns","second-column","children","C"]),name:"code")
        _ = try convert(a,f,"paragraph",offset:0)
        _ = try a.removeColumns(ModernColumnTarget(layout:root))
        #expect(a.document.blocks[2].type == "paragraph")
        _ = try convert(a,f,"list",offset:0,style:"ordered")
        #expect(a.document.blocks[2].type == "list")
        let reopened = try ModernSession.restore(a.save(),actorID:"a")
        try reopened.undo(); try reopened.undo(); try reopened.undo()
        #expect(reopened.document == (try fixture("columns-3000")))
    }
    @Test func codeFormattingAndTitleConversionRejectWithoutHistoryOrReceiptChanges() throws {
        let a = try session("a"), old = try field(a), before = try a.captureTextRange(in: old,start:0,end:1)
        _ = try convert(a,old,"code")
        let saved = try a.save()
        #expect(throws: EditorError.self) { try a.format(in:before,markType:"bold",mark:.object(["type":.string("bold")])) }
        #expect(throws: EditorError.self) { try convert(a,a.titleField,"code",offset:0) }
        #expect(try a.save() == saved)
        let code = try field(a,name:"code")
        _ = try convert(a,code,"code",offset:0); #expect(try a.save() == saved)
    }

    @Test func splitNoncollapsedCapturedRangeStillDeletesOnlyObservedAtomsAfterSchemaRoundTrip() throws {
        let a = try session("a"), b = try session("b"), f = try field(a)
        _ = try convert(a,f,"code"); _ = try convert(a,f,"paragraph")
        try b.receive(a.changes())
        let capture = try a.captureTextRange(in:f,start:1,end:2)
        try b.replaceText(in:f,range:2..<2,with:"peer")
        try a.receive(b.changes())
        _ = try a.splitBlock(in:capture,newBlockID:"tail")
        #expect(try a.text(in:f) == "A")
        #expect(try a.text(in:field(a,NodeAddress("tail"))) == "peerC")
        try a.undo(); #expect(try a.text(in:f) == "ABpeerC")
    }

    @Test func forgedTextUsesOfRetiredContentAliasRejectEvenWhenInactive() throws {
        let a = try session("a"), old = try field(a)
        _ = try convert(a,old,"code")
        let id = ChangeID(counter:2,actor:"peer"), element = ElementID(change:id,index:0)
        let atom = WritingAtomSeed(key:WritingAtomKey(origin:old,element:element),node:.object(["type":.string("text"),"text":.string("X"),"marks":.array([.object(["type":.string("bold")])])]),edge:.start,route:.field(old))
        let edit = ModernChange(id:id,observed:a.modernObserved,body:.edit([.text(.insert(atom))]))
        let off = ModernChange(id:ChangeID(counter:3,actor:"peer"),observed:[id],body:.setActive(targets:[id],active:false))
        let saved = try a.save(), receipt = a.syncState
        #expect(throws: EditorError.self) { try a.receive(ModernBatch(documentID:a.documentID,epoch:a.epoch,baseline:a.baseline,changes:[edit,off])) }
        #expect(try a.save() == saved && a.syncState == receipt && a.mergeRecovery == nil)
    }
    @Test func futureJoinCannotJustifyForgedAnchorInEarlierCapturedField() throws {
        var fields = try fixture().fields
        fields["blocks"] = .array([
            .object(["id":.string("A"),"type":.string("paragraph"),"content":.array([.object(["type":.string("text"),"text":.string("ABC")])])]),
            .object(["id":.string("B"),"type":.string("paragraph"),"content":.array([.object(["type":.string("text"),"text":.string("XYZ")])])])])
        let a = try session("a",document:ModernDocument(fields:fields)), first = try field(a), second = try field(a,NodeAddress("B"))
        let anchor = try a.position(in:first,offset:1).anchor
        let forged = WritingPosition(documentID:a.documentID,epoch:a.epoch,field:second,anchor:anchor,affinity:.before)
        let capture = ModernTextRange(start:forged,end:forged,observed:[])
        _ = try a.mergeBlocks(a.captureNodes([first.node,second.node]))
        let saved = try a.save()
        #expect(throws: EditorError.self) { try a.replaceText(in:capture,with:"X") }
        #expect(try a.save() == saved)
    }

    @Test func opaqueContentOnCodeBlocksCannotBeDiscardedByLocalOrInactiveRemoteListConversion() throws {
        let doc = try document(.object(["id":.string("A"),"type":.string("code"),"code":.string("ABC"),"content":.object(["consumer":.string("retain")])]))
        let a = try session("a",document:doc), f = try field(a,name:"code"), saved = try a.save()
        #expect(throws: EditorError.self) { try convert(a,f,"list",offset:0) }
        #expect(try a.save() == saved && a.document == doc)
        let id = ChangeID(counter:1,actor:"peer"), creation = ElementID(change:id,index:0)
        let conversion = WritingSchemaConversion(node:f.node,type:"list",attributes:["style":.string("unordered")],source:f,destination:WritingField(node:.inserted(creation:creation,path:[]),name:"content"),itemID:"A-item",creation:creation,preservedItemFields:[:])
        let edit = ModernChange(id:id,observed:[],body:.edit([.schemaConvert(conversion)]))
        for inactive in [false,true] {
            let changes = inactive ? [edit,ModernChange(id:ChangeID(counter:2,actor:"peer"),observed:[id],body:.setActive(targets:[id],active:false))] : [edit]
            #expect(throws: EditorError.self) { try a.receive(ModernBatch(documentID:a.documentID,epoch:a.epoch,baseline:a.baseline,changes:changes)) }
            #expect(try a.save() == saved && a.document == doc && a.mergeRecovery == nil)
        }
    }

    @Test func laterSchemaConversionRetainsTextCreatedInItsBirthsOwnCompoundPacket() throws {
        let a = try session("a"), id = ChangeID(counter:1,actor:"peer"), creation = ElementID(change:id,index:0)
        let node = NodeID.inserted(creation:creation,path:[]), f = WritingField(node:node,name:"content")
        var operations: [ModernOperation] = [.structure(.insertNode(value:.object(["id":.string("born"),"type":.string("paragraph"),"content":.array([])]),identity:node,collection:.root,placement:creation,after:.initial(try a.node(at:NodeAddress("A")))))]
        var edge = WritingEdge.start
        for (offset, scalar) in "ABC".unicodeScalars.enumerated() {
            let key = WritingAtomKey(origin:f,element:ElementID(change:id,index:offset+1))
            operations.append(.text(.insert(WritingAtomSeed(key:key,node:.object(["type":.string("text"),"text":.string(String(scalar))]),edge:edge,route:edge.anchor.map(WritingRoute.follow) ?? .field(f)))))
            edge = .after(key)
        }
        try a.receive(ModernBatch(documentID:a.documentID,epoch:a.epoch,baseline:a.baseline,changes:[ModernChange(id:id,observed:[],body:.edit(operations))]))
        let original = a.document
        #expect(try a.text(in:f) == "ABC")
        _ = try convert(a,f,"code")
        #expect(a.document.blocks[1].fields["code"] == .string("ABC"))
        try a.undo(); #expect(a.document == original)
        let reopened = try ModernSession.restore(a.save(),actorID:"a")
        try reopened.redo(); #expect(reopened.document.blocks[1].fields["code"] == .string("ABC"))
    }

}
