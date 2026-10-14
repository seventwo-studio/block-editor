import { SwiftEditorRuntime } from '/Users/luca/Developer/block-editor/dist/swift.js';
import { readFileSync,writeFileSync } from 'node:fs';
import { createHash } from 'node:crypto';
import { execFileSync } from 'node:child_process';
import assert from 'node:assert/strict';
const fixture=readFileSync('benchmarks/modern-surface-1000.json'), wasm=readFileSync('dist/block-editor.wasm'), document=JSON.parse(fixture);
const runtime=await SwiftEditorRuntime.initialize(wasm), call=runtime.call.bind(runtime), reads=[];
runtime.call=request=>{const start=performance.now();const result=call(request);if(request.command==='modernRenderingBindings')reads.push({ms:performance.now()-start,bytes:Buffer.byteLength(JSON.stringify(result)),omitted:result.bindings===null});return result;};
const session=runtime.createModern({documentID:document.documentID,actorID:'token-probe',epoch:'token-probe',document});
const initial=session.nodeBindings(), field=session.field(session.node({blockID:'note-1',path:[]}));
for(let i=0;i<2;i++){const text=session.text(field);assert.equal(session.execute({command:'replaceText',target:session.captureTextRange(field,text.length,text.length),arguments:{text:'!',typingGroup:'probe'}}).status,'applied');assert.equal(session.nodeBindings(),initial);assert.equal(session.text(field),text+'!');}
session.close();assert.equal(initial.length,5242);assert.equal(reads.length,3);assert.equal(reads[0].omitted,false);assert(reads.slice(1).every(x=>x.omitted));
writeFileSync('.build/finishing/20261014/rendering-token/probe.json',JSON.stringify({diagnostic:true,sourceCommit:execFileSync('git',['rev-parse','HEAD'],{encoding:'utf8'}).trim(),sourceClean:!execFileSync('git',['status','--porcelain'],{encoding:'utf8'}).trim(),fixtureSHA256:createHash('sha256').update(fixture).digest('hex'),wasmSHA256:createHash('sha256').update(wasm).digest('hex'),nodeCount:initial.length,reads},null,2)+'\n');
