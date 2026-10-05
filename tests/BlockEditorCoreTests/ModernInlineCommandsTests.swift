import Foundation
import Testing
@testable import BlockEditorCore

@Suite struct ModernInlineCommandsTests {
    private func document() throws -> ModernDocument {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        var fields = try ModernDocument(json: Data(contentsOf: root.appendingPathComponent("docs/acceptance/modern-editor/documents/unicode.json"))).fields
        fields["blocks"] = .array([
            .object(["id":.string("A"),"type":.string("paragraph"),"consumer":.object(["color":.string("custom")]),"content":.array([.object(["type":.string("text"),"text":.string("ABC"),"marks":.array([.object(["type":.string("bold")])])])])]),
            .object(["id":.string("B"),"type":.string("paragraph"),"content":.array([])]),
            .object(["id":.string("code"),"type":.string("code"),"code":.string("literal"),"language":.string("swift")]),
            .object(["id":.string("future"),"type":.string("consumer-widget"),"payload":.object(["color":.string("custom")])])])
        return try ModernDocument(fields:fields)
    }
    private func session(_ actor: String) throws -> ModernSession { let d=try document();return try ModernSession(documentID:d.documentID,actorID:actor,epoch:"inline",document:d) }
    private func node(_ s:ModernSession,_ id:String="A")throws->NodeID{try s.node(at:NodeAddress(id))}
    private func field(_ s:ModernSession,_ id:String="A",name:String="content")throws->WritingField{try s.field(node:node(s,id),name:name)}
    private func range(_ s:ModernSession,_ start:Int=0,_ end:Int=3)throws->ModernTextRange{try s.captureTextRange(in:field(s),start:start,end:end)}
    private func blocks(_ s:ModernSession,_ ids:[String]=["A","B"],caret:WritingPosition?=nil)throws->ModernSemanticTarget{
        ModernSemanticTarget(nodes:try s.captureNodes(ids.map{try node(s,$0)}),caret:caret)
    }
    private func exchange(_ a:ModernSession,_ b:ModernSession)throws{let aa=try a.changes(),bb=try b.changes();try a.receive(bb);try b.receive(aa);try a.receive(bb);try b.receive(aa)}
    private func reject(_ s:ModernSession,_ operation:()throws->Void)throws{
        let save=try s.save(),state=s.syncState
        do{try operation();Issue.record("Expected unchanged rejection")}catch{}
        #expect(try s.save()==save && s.syncState==state && s.mergeRecovery==nil)
    }
    private func marks(_ s:ModernSession)throws->[JSONValue]{try s.document.blocks[0].fields["content"]!.array!}

    @Test func multiBlockDefaultsPreservePeerTextOpaqueDataCaretAndOneUndoReopen() throws {
        let a=try session("a"),b=try session("b"),caret=try range(a,1,1).start,target=try blocks(a,caret:caret)
        try b.replaceText(in:field(b),range:1..<1,with:"peer")
        _=try b.setSemanticColor(blocks(b,["A"]),kind:.fill,role:"amber")
        _=try a.setSemanticColor(target,kind:.ink,role:"blue");try exchange(a,b)
        #expect(try a.document==b.document && a.text(in:field(a))=="ApeerBC")
        #expect(a.document.blocks[0].fields["semanticBackground"] == .string("amber"))
        #expect(a.document.blocks[0].fields["semanticColor"] == .string("blue") && a.document.blocks[1].fields["semanticColor"] == .string("blue"))
        #expect(a.document.blocks[0].fields["consumer"] == .object(["color":.string("custom")]))
        #expect(try a.resolve(caret).offset==5) // The original caret stays before B, after the peer prefix.
        let reopened=try ModernSession.restore(a.save(),actorID:"a");try reopened.undo()
        #expect(reopened.document.blocks[0].fields["semanticColor"]==nil && reopened.document.blocks[1].fields["semanticColor"]==nil)
        #expect(try reopened.document.blocks[0].fields["semanticBackground"] == .string("amber") && reopened.text(in:field(reopened))=="ApeerBC")
        try reopened.redo();#expect(reopened.document==a.document)
    }
    @Test func resetsRemoveOnlyOverridesAndMixedStateIncludesInheritedDefaults() throws {
        let a=try session("a")
        _=try a.setSemanticColor(blocks(a,["A"]),kind:.ink,role:"red")
        #expect(try a.semanticState(blocks(a),kind:.ink) == .mixed)
        _=try a.setSemanticColor(blocks(a),kind:.ink,role:nil)
        #expect(try a.semanticState(blocks(a),kind:.ink) == .inherited)
        let save=try a.save();_=try a.setSemanticColor(blocks(a),kind:.ink,role:nil);#expect(try a.save()==save)
        try a.undo();#expect(a.document.blocks[0].fields["semanticColor"] == .string("red"))
        _=try a.setSemanticColor(ModernSemanticTarget(range:range(a)),kind:.ink,role:"green")
        #expect(try a.semanticState(ModernSemanticTarget(range:range(a)),kind:.ink) == .role("green"))
        _=try a.setSemanticColor(ModernSemanticTarget(range:range(a)),kind:.ink,role:nil)
        #expect(try a.semanticState(ModernSemanticTarget(range:range(a)),kind:.ink) == .role("red"))
    }
    @Test func sameDefaultRegisterConvergesAndAuthorUndoRevealsPeerRole() throws {
        let a=try session("a"),z=try session("z")
        _=try a.setSemanticColor(blocks(a,["A"]),kind:.fill,role:"green")
        _=try z.setSemanticColor(blocks(z,["A"]),kind:.fill,role:"purple");try exchange(a,z)
        #expect(a.document==z.document && a.document.blocks[0].fields["semanticBackground"] == .string("purple"))
        try z.undo();try exchange(a,z);#expect(a.document.blocks[0].fields["semanticBackground"] == .string("green"))
        try a.undo();try exchange(a,z);#expect(a.document==(try document()) && a.document==z.document)
    }
    @Test func capturedBackwardTextInkAndPeerFillKeepPeerInsertionsOutsideFormatting() throws {
        let a=try session("a"),b=try session("b"),captured=try range(a,3,0)
        _=try b.setSemanticColor(ModernSemanticTarget(range:range(b)),kind:.fill,role:"amber")
        try b.replaceText(in:field(b),range:1..<1,with:"peer");try a.receive(b.changes())
        let result=try a.setSemanticColor(ModernSemanticTarget(range:captured),kind:.ink,role:"blue")
        #expect(result.selection == .text(WritingTextRange(start:captured.start,end:captured.end)) && result.focus == .text(captured.end))
        let runs=try marks(a),peer=runs.filter{($0["text"]?.string ?? "").contains("peer")}
        #expect(peer.count==1 && peer[0]["marks"]?.array?.contains(where:{$0["type"] == .string("semantic-color")})==false)
        #expect(try a.semanticState(ModernSemanticTarget(range:range(a,0,7)),kind:.ink) == .mixed)
        try exchange(a,b);#expect(a.document==b.document)
        let reopened=try ModernSession.restore(a.save(),actorID:"a");try reopened.undo()
        #expect(try reopened.text(in:field(reopened))=="ApeerBC")
        #expect(try reopened.semanticState(ModernSemanticTarget(range:range(reopened,0,7)),kind:.fill) == .role("amber"))
        try reopened.redo();#expect(reopened.document==a.document)
    }
    @Test func semanticCaretAndAlreadyMatchingMarksDoNotCreateHistory() throws {
        let a=try session("a"),save=try a.save(),caret=try range(a,1,1)
        _=try a.setSemanticColor(ModernSemanticTarget(range:caret),kind:.ink,role:"blue");#expect(try a.save()==save)
        _=try a.setSemanticColor(ModernSemanticTarget(range:range(a)),kind:.ink,role:"blue")
        let next=try a.save();_=try a.setSemanticColor(ModernSemanticTarget(range:range(a)),kind:.ink,role:"blue");#expect(try a.save()==next)
        _=try a.setSemanticColor(ModernSemanticTarget(range:range(a)),kind:.fill,role:"green")
        _=try a.setSemanticColor(ModernSemanticTarget(range:range(a)),kind:.ink,role:nil)
        let runs=try marks(a);#expect(runs.allSatisfy{$0["marks"]?.array?.contains(.object(["type":.string("semantic-background"),"value":.string("green")]))==true})
    }
    @Test func blockDefaultsFollowScopedMovementAndSchemaConversionWithoutCopyingText() throws {
        let a=try session("a"),b=try session("b"),target=try blocks(a,["A"]),origin=try node(a)
        _=try b.convertBlock(in:range(b,1,1),to:WritingBlockTarget(type:"heading",level:2));try a.receive(b.changes())
        _=try a.setSemanticColor(target,kind:.ink,role:"red");try exchange(a,b)
        #expect(a.document.blocks[0].type=="heading" && a.document.blocks[0].fields["level"] == .number(2))
        #expect(try a.node(at:NodeAddress("A"))==origin)
        let columns: JSONValue = .object([
            "id": .string("layout"), "type": .string("columns"), "splitBasisPoints": .number(5000),
            "columns": .array([
                .object(["id": .string("left"), "children": .array([])]),
                .object(["id": .string("right"), "children": .array([])])
            ])
        ])
        _=try a.createColumns(ModernCreateColumnsTarget(selection:a.captureNodes([origin])),layout:columns)
        #expect(try a.semanticState(target,kind:.ink) == .role("red"))
        _=try a.setSemanticColor(target,kind:.fill,role:"amber")
        let child=a.document.blocks[0].fields["columns"]!.array![0]["children"]!.array![0]
        #expect(child["semanticColor"] == .string("red") && child["semanticBackground"] == .string("amber"))
        try a.undo();#expect(try a.semanticState(target,kind:.fill) == .inherited)
    }
    @Test func defaultOnExposedPeerParagraphSurvivesOriginalListCreationRedoAndOwnUndo() throws {
        let a=try session("a"),b=try session("b")
        _=try a.convertBlock(in:range(a,1,1),to:WritingBlockTarget(type:"list",style:"todo"));try b.receive(a.changes())
        let item=try b.node(at:NodeAddress("A",path:["items","A-item"]))
        _=try b.splitBlock(in:b.captureTextRange(in:b.field(node:item),start:1,end:1),newBlockID:"tail");try a.receive(b.changes())
        try a.undo();try b.receive(a.changes())
        let tail=try b.node(at:NodeAddress("tail")),target=ModernSemanticTarget(nodes:try b.captureNodes([tail]))
        _=try b.setSemanticColor(target,kind:.ink,role:"blue");try a.receive(b.changes());try a.redo();try b.receive(a.changes())
        #expect(a.document==b.document && a.document.blocks.contains{$0.id=="tail" && $0.fields["semanticColor"] == .string("blue")})
        let reopened=try ModernSession.restore(b.save(),actorID:"b");try reopened.undo()
        #expect(!reopened.document.blocks.contains{$0.fields["semanticColor"] == .string("blue")})
    }
    @Test(arguments:["none","both","wrongCaret","unknown","item","deleted","scope","role","codeRange","titleRange"])
    func invalidSemanticTargetsAndRolesRejectAtomically(fault:String) throws {
        let a=try session("a")
        var target=try blocks(a,["A"]),role:String?="blue"
        switch fault {
        case "none":target=ModernSemanticTarget()
        case "both":target=ModernSemanticTarget(range:try range(a),nodes:target.nodes)
        case "wrongCaret":target=try blocks(a,["B"],caret:range(a,1,1).start)
        case "unknown":target=try blocks(a,["future"])
        case "item":target=ModernSemanticTarget(nodes:ModernNodeSelection(documentID:a.documentID,epoch:a.epoch,nodes:[.baseline(blockID:"A",path:["items","fake"])],observed:[]))
        case "deleted":_=try a.delete(ModernDeleteTarget(nodes:target.nodes))
        case "scope":target=ModernSemanticTarget(nodes:ModernNodeSelection(documentID:"other",epoch:a.epoch,nodes:target.nodes!.nodes,observed:[]))
        case "role":role="custom-hex"
        case "codeRange":target=ModernSemanticTarget(range:try a.captureTextRange(in:field(a,"code",name:"code"),start:0,end:1))
        default:target=ModernSemanticTarget(range:try a.captureTextRange(in:a.titleField,start:0,end:0))
        }
        try reject(a){_=try a.setSemanticColor(target,kind:.ink,role:role)}
    }
    @Test(arguments:["role","document","unknown","item","duplicate","future"])
    func malformedSemanticPacketsRejectEvenInactiveWithoutReceiptOrRecovery(fault:String) throws {
        let a=try session("receiver"),id=ChangeID(counter:1,actor:"peer")
        var node=try node(a),role:String?="blue"
        if fault=="role"{role="unknown"};if fault=="document"{node = .document(documentID:a.documentID)}
        if fault=="unknown"{node=try self.node(a,"future")};if fault=="item"{node = .baseline(blockID:"A",path:["items","fake"])}
        if fault=="future"{node = .inserted(creation:ElementID(change:ChangeID(counter:2,actor:"peer"),index:0),path:[])}
        var operations:[ModernOperation]=[.setSemanticDefault(node:node,kind:.ink,role:role)]
        if fault=="duplicate"{operations+=operations}
        let edit=ModernChange(id:id,observed:[],body:.edit(operations)),undo=ModernChange(id:ChangeID(counter:2,actor:"peer"),observed:[id],body:.setActive(targets:[id],active:false))
        for changes in [[edit],[edit,undo]]{try reject(a){try a.receive(ModernBatch(documentID:a.documentID,epoch:a.epoch,baseline:a.baseline,changes:changes))}}
    }
    @Test func insertedDefaultIncrementalPacketRecoversAfterItsValidBirthArrives() throws {
        let a=try session("author"),b=try session("receiver")
        _=try a.insertBlock(Block.paragraph(id:"new",text:"peer"),at:a.captureBoundary())
        let born=try a.changes();_=try a.setSemanticColor(blocks(a,["new"]),kind:.ink,role:"green")
        let delta=try a.changes(since:b.syncState),only=ModernBatch(documentID:a.documentID,epoch:a.epoch,baseline:a.baseline,changes:[delta.changes.last!])
        do{try b.receive(only);Issue.record("Expected retained recovery")}catch ModernSessionError.recoveryRequired{}
        #expect(b.document==b.baseline && b.mergeRecovery != nil)
        try b.receive(born);#expect(b.document==a.document && b.mergeRecovery==nil)
        let reopened=try ModernSession.restore(b.save(),actorID:"receiver");#expect(reopened.document==a.document)
    }
    @Test func localCompositionAndCommandPoliciesPreserveRemoteDefaultsAndLinkHistory() throws {
        let a=try session("a"),b=try session("b"),target=try blocks(a)
        a.allowedCommands=["setLink","setSemanticColor","undo","redo"]
        _=try a.setLink(in:range(a),href:"https://example.com")
        _=try a.setSemanticColor(target,kind:.ink,role:"blue")
        a.isComposing=true;try reject(a){_=try a.setSemanticColor(target,kind:.fill,role:"red")};a.isComposing=false
        a.allowedCommands=["replaceText"];try reject(a){_=try a.setLink(in:range(a),href:nil)}
        _=try b.setSemanticColor(blocks(b),kind:.fill,role:"green");try a.receive(b.changes())
        #expect(a.document.blocks[0].fields["semanticBackground"] == .string("green"))
    }
    @Test func rangeLinksPreserveCapturedAtomsPeerTextBackwardSelectionAndUndoReopen() throws {
        let a=try session("a"),b=try session("b"),captured=try range(a,3,0)
        try b.replaceText(in:field(b),range:1..<1,with:"peer");try a.receive(b.changes())
        let peerDocument=a.document
        let result=try a.setLink(in:captured,href:"https://example.com/path?q=1")
        #expect(result.focus == .text(captured.end) && result.selection == .text(WritingTextRange(start:captured.start,end:captured.end)))
        let peer=try marks(a).first{($0["text"]?.string ?? "").contains("peer")}
        #expect(peer?["marks"]?.array?.contains(where:{$0["type"] == .string("link")})==false)
        let saved=try a.save();_=try a.setLink(in:captured,href:"https://example.com/path?q=1");#expect(try a.save()==saved)
        try exchange(a,b);let reopened=try ModernSession.restore(a.save(),actorID:"a");try reopened.undo()
        #expect(try reopened.text(in:field(reopened))=="ApeerBC" && reopened.document==peerDocument)
        try reopened.redo();#expect(reopened.document==a.document)
        _=try reopened.setLink(in:captured,href:nil);#expect(try reopened.text(in:field(reopened))=="ApeerBC")
    }
    @Test func explicitLabelInsertionUsesCapturedCaretInheritedMarksAndOneAuthorStep() throws {
        let a=try session("a"),b=try session("b")
        _=try a.setSemanticColor(ModernSemanticTarget(range:range(a)),kind:.ink,role:"blue")
        _=try a.setLink(in:range(a),href:"https://old.example.com")
        let caret=try range(a,1,1)
        try b.replaceText(in:field(b),range:1..<1,with:"peer");try a.receive(b.changes())
        let before=a.document,count=a.syncState.received.count
        let result=try a.setLink(in:caret,href:"mailto:hello@example.com",label:"😀 link")
        #expect(a.syncState.received.count==count+1)
        #expect(try a.text(in:field(a))=="A😀 linkpeerBC")
        guard case .text(let end)=result.focus else{Issue.record("Expected text caret");return}
        #expect(try a.resolve(end).offset==8)
        let runs=try marks(a),label=runs.first{$0["text"] == .string("😀 link")}
        #expect(label?["marks"]?.array?.contains(.object(["type":.string("bold")]))==true)
        #expect(label?["marks"] == .array([
            .object(["type":.string("bold")]),
            .object(["type":.string("link"),"href":.string("mailto:hello@example.com")]),
            .object(["type":.string("semantic-color"),"value":.string("blue")])
        ]))
        let reopened=try ModernSession.restore(a.save(),actorID:"a");try reopened.undo();#expect(reopened.document==before)
        try reopened.redo();#expect(reopened.document==a.document)
    }
    @Test(arguments:["javascript:alert(1)","data:text/html,test","file:///tmp/file","https://","relative","https://example.com/space here","https://example.com/\n","mailto:"])
    func invalidLinksNeverMutateStateOrStripExistingMarks(href:String) throws {
        let a=try session("a");try reject(a){_=try a.setLink(in:range(a),href:href)}
    }
    @Test func invalidLabelsLiteralFieldsAndStaleLinkCapturesRejectUnchanged() throws {
        let a=try session("a")
        try reject(a){_=try a.setLink(in:range(a),href:"https://example.com",label:"replacement")}
        try reject(a){_=try a.setLink(in:range(a,1,1),href:nil,label:"label")}
        try reject(a){_=try a.setLink(in:range(a,1,1),href:"https://example.com",label:"")}
        try reject(a){_=try a.setLink(in:a.captureTextRange(in:field(a,"code",name:"code"),start:0,end:1),href:"https://example.com")}
        let stale=try range(a);_=try a.delete(ModernDeleteTarget(nodes:a.captureNodes([node(a)])))
        try reject(a){_=try a.setLink(in:stale,href:"https://example.com")}
    }
    @Test func concurrentDeletionKeepsDefaultsForRestorationWithoutResurrectingContent() throws {
        let a=try session("a"),b=try session("b")
        _=try a.setSemanticColor(blocks(a,["A"]),kind:.ink,role:"blue")
        _=try b.delete(ModernDeleteTarget(nodes:b.captureNodes([node(b)])));try exchange(a,b)
        #expect(a.document==b.document && !a.document.blocks.contains{$0.id=="A"})
        try b.undo();try exchange(a,b)
        #expect(a.document.blocks[0].fields["semanticColor"] == .string("blue"))
        try a.undo();try exchange(a,b);#expect(a.document==(try document()) && a.document==b.document)
    }
    @Test func inlineRolesAndLinksKeepWholeAtomicReferencesAndInheritedListDefaults() throws {
        let a=try session("a")
        _=try a.convertBlock(in:range(a,1,1),to:WritingBlockTarget(type:"list",style:"todo"))
        _=try a.setSemanticColor(blocks(a,["A"]),kind:.fill,role:"amber")
        let item=try a.node(at:NodeAddress("A",path:["items","A-item"])),f=try a.field(node:item)
        let all=try a.captureTextRange(in:f,start:0,end:3)
        #expect(try a.semanticState(ModernSemanticTarget(range:all),kind:.fill) == .role("amber"))
        _=try a.setLink(in:all,href:"https://example.com")
        _=try a.setSemanticColor(ModernSemanticTarget(range:all),kind:.ink,role:"blue")
        #expect(try a.text(in:f)=="ABC")
        try a.undo();#expect(try a.semanticState(ModernSemanticTarget(range:all),kind:.fill) == .role("amber"))
        let root=URL(fileURLWithPath:#filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        var sourceFields=try ModernDocument(json:Data(contentsOf:root.appendingPathComponent("docs/acceptance/modern-editor/documents/mixed.json"))).fields
        var sourceBlocks=sourceFields["blocks"]!.array!,sourceBlock=sourceBlocks[0].object!,sourceContent=sourceBlock["content"]!.array!,reference=sourceContent[2].object!
        reference["marks"] = .array([.object(["type":.string("semantic-color"),"value":.string("consumer-custom")])])
        sourceContent[2] = .object(reference);sourceBlock["content"] = .array(sourceContent);sourceBlocks[0] = .object(sourceBlock);sourceFields["blocks"] = .array(sourceBlocks)
        let doc=try ModernDocument(fields:sourceFields)
        let refs=try ModernSession(documentID:doc.documentID,actorID:"r",epoch:"refs",document:doc)
        let original=doc.blocks[0].fields["content"]!.array!,ref=try #require(original.first{$0["type"] == .string("entity-ref")})
        let rf=try refs.field(node:refs.node(at:NodeAddress("A"))),length=try refs.text(in:rf).utf16.count
        let rr=try refs.captureTextRange(in:rf,start:0,end:length)
        _=try refs.setSemanticColor(ModernSemanticTarget(range:rr),kind:.ink,role:"green")
        _=try refs.setLink(in:rr,href:"https://example.com")
        let result=refs.document.blocks[0].fields["content"]!.array!
        #expect(result.contains(ref))
        let atom=try refs.captureTextRange(in:rf,start:11,end:15),save=try refs.save()
        _=try refs.setSemanticColor(ModernSemanticTarget(range:atom),kind:.ink,role:"red")
        _=try refs.setLink(in:atom,href:"https://example.com")
        #expect(try refs.save()==save)
        #expect(try refs.semanticState(ModernSemanticTarget(range:atom),kind:.ink) == .inherited)
        try reject(refs){_=try refs.setLink(in:refs.captureTextRange(in:rf,start:13,end:13),href:"https://example.com",label:"label")}

        try refs.undo();try refs.undo();#expect(refs.document==doc)
    }
    @Test func checkedBridgeReportsSemanticStateLinkResultsPolicyAndUnchangedInvalidArguments() throws {
        let bridge=EditorBridge(),doc=try document()
        func value<T:Encodable>(_ x:T)throws->JSONValue{try JSONDecoder().decode(JSONValue.self,from:JSONEncoder().encode(x))}
        func call(_ name:String,_ args:[String:JSONValue]=[:])throws->JSONValue{
            var f=args;f["command"] = .string(name);f["session"] = .string("inline")
            return try JSONDecoder().decode(JSONValue.self,from:bridge.call(JSONEncoder().encode(f)))
        }
        func success(_ r:JSONValue)throws->JSONValue{#expect(r["ok"] == .bool(true));return try #require(r["value"])}
        _=try success(call("createModern",["actorID":.string("a"),"documentID":.string(doc.documentID),"epoch":.string("inline"),"collaborationVersion":.number(7),"document":.object(doc.fields),"allowedCommands":.array([.string("setSemanticColor"),.string("setLink"),.string("undo"),.string("redo")])]))
        let origin=NodeID.baseline(blockID:"A",path:[])
        let selection=try success(call("modernCaptureNodes",["nodes":.array([value(origin)])]))
        let target:JSONValue = .object(["nodes":selection])
        func command(_ name:String,_ target:JSONValue,_ args:[String:JSONValue])throws->JSONValue{
            try success(call("modernCommand",["request":.object(["documentID":.string(doc.documentID),"epoch":.string("inline"),"command":.string(name),"target":target,"arguments":.object(args)])]))
        }
        let changed=try command("setSemanticColor",target,["kind":.string("ink"),"role":.string("blue")])
        #expect(changed["status"] == .string("applied") && changed["focusIntent"]?["nodes"] != nil)
        let state=try success(call("modernSemanticState",["target":target,"kind":.string("ink")]))
        #expect(state == .object(["role":.object(["_0":.string("blue")])]))
        let reset=try command("setSemanticColor",target,["kind":.string("ink"),"role":.null]);#expect(reset["status"] == .string("applied"))
        let noop=try command("setSemanticColor",target,["kind":.string("ink"),"role":.null]);#expect(noop["status"] == .string("noop"))
        let f=WritingField(node:origin,name:"content"),captured=try success(call("modernCaptureTextRange",["field":value(f),"start":.number(3),"end":.number(0)]))
        let link=try command("setLink",captured,["href":.string("https://example.com")]);#expect(link["status"] == .string("applied") && link["focusIntent"]?["text"] != nil)
        let before=try success(call("modernSave"))
        let invalid=try command("setLink",captured,["href":.string("javascript:alert(1)")]);#expect(invalid["status"] == .string("unavailable"))
        let invalidRole=try command("setSemanticColor",target,["kind":.string("fill"),"role":.bool(true)]);#expect(invalidRole["status"] == .string("unavailable"))
        #expect(try success(call("modernSave"))==before)
        let caps=try success(call("modernCapabilities"));#expect(caps["commands"]?.array==[.string("setSemanticColor"),.string("setLink"),.string("undo"),.string("redo")])
    }

    @Test func capturedMarksAndStateFollowAllActualFieldsAfterPeerSplitAndReopen() throws {
        let a=try session("a"),b=try session("b"),captured=try range(a,3,0)
        _=try b.splitBlock(in:range(b,1,1),newBlockID:"tail")
        _=try b.setSemanticColor(blocks(b,["tail"]),kind:.ink,role:"blue")
        try a.receive(b.changes())
        let target=ModernSemanticTarget(range:captured)
        #expect(try a.semanticState(target,kind:.ink) == .mixed)
        let peerDocument=a.document
        _=try a.setSemanticColor(target,kind:.ink,role:"green")
        _=try a.setLink(in:captured,href:"https://example.com")
        let expected:[JSONValue]=[.object(["type":.string("bold")]),.object(["type":.string("link"),"href":.string("https://example.com")]),.object(["type":.string("semantic-color"),"value":.string("green")])]
        #expect(a.document.blocks[0].fields["content"] == .array([.object(["type":.string("text"),"text":.string("A"),"marks":.array(expected)])]))
        #expect(a.document.blocks[1].fields["content"] == .array([.object(["type":.string("text"),"text":.string("BC"),"marks":.array(expected)])]))
        #expect(a.document.blocks[1].fields["semanticColor"] == .string("blue"))
        #expect(try a.semanticState(target,kind:.ink) == .role("green"))
        let reopened=try ModernSession.restore(a.save(),actorID:"a");try reopened.undo();try reopened.undo()
        #expect(try reopened.document==peerDocument && reopened.semanticState(target,kind:.ink) == .mixed)
        try reopened.redo();try reopened.redo();#expect(reopened.document==a.document)
        try exchange(a,b);#expect(a.document==b.document)
    }

}
