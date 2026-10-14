import { SwiftEditorRuntime } from '/Users/luca/Developer/block-editor/dist/swift.js';
import {readFileSync,writeFileSync} from 'node:fs';
import {execFileSync} from 'node:child_process';
import {createHash} from 'node:crypto';
import assert from 'node:assert/strict';
const fixture=readFileSync('benchmarks/modern-surface-1000.json'),wasm=readFileSync('dist/block-editor.wasm'),document=JSON.parse(fixture);
const runtime=await SwiftEditorRuntime.initialize(wasm),call=runtime.call.bind(runtime),responses=[];let handle;
runtime.call=request=>{const value=call(request);if(request.command==='modernCommand'){handle=request.session;responses.push({command:request.request.command,negotiated:request.documentSnapshotVersion===1,hasDocument:Object.hasOwn(value,'document'),changes:value.documentSnapshot?.changes?.length,bytes:Buffer.byteLength(JSON.stringify(value))});}return value;};
const session=runtime.createModern({documentID:document.documentID,actorID:'transport-diagnostic',epoch:'transport-diagnostic',document});
session.endTypingGroup();const field=session.field(session.node({blockID:'note-1',path:[]}));
const expected=structuredClone(document);
for(let i=0;i<2;i++){const text=session.text(field);assert.equal(session.execute({command:'replaceText',target:session.captureTextRange(field,text.length,text.length),arguments:{text:'!',typingGroup:'diagnostic'}}).status,'applied');expected.blocks.find(b=>b.id==='note-1').content[0].text+='!';assert.deepEqual(session.getSnapshot().document,expected);assert.deepEqual(call({command:'modernDocument',session:handle}),expected);}
const full=call({command:'modernSnapshot',session:handle});assert.deepEqual(full.document,expected);assert(!Object.hasOwn(full,'documentSnapshot'));
assert.equal(session.execute({command:'undo',arguments:{}}).status,'applied');assert.deepEqual(session.getSnapshot().document,document);
assert.equal(session.execute({command:'redo',arguments:{}}).status,'applied');assert.deepEqual(session.getSnapshot().document,expected);
assert(responses.every(r=>r.negotiated&&!r.hasDocument));session.close();
writeFileSync('.build/finishing/20261014/snapshot-delta/transport-probe.json',JSON.stringify({diagnostic:true,complete:true,sourceCommit:execFileSync('git',['rev-parse','HEAD'],{encoding:'utf8'}).trim(),sourceClean:!execFileSync('git',['status','--porcelain'],{encoding:'utf8'}).trim(),fixtureSHA256:createHash('sha256').update(fixture).digest('hex'),wasmSHA256:createHash('sha256').update(wasm).digest('hex'),fullResponseBytes:Buffer.byteLength(JSON.stringify(full)),responses,qualification:'Actual admitted response bytes and exact complete-document oracle/direct shared reads, plus grouped author Undo/Redo. Not percentile/resource or full interaction acceptance.'},null,2)+'\n');
