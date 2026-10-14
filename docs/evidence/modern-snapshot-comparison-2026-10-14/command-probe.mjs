import { SwiftEditorRuntime } from '/Users/luca/Developer/block-editor/dist/swift.js';
import {readFileSync, writeFileSync} from 'node:fs';
import {Session} from 'node:inspector';
const wasm=readFileSync('dist/block-editor.wasm'), doc=JSON.parse(readFileSync('benchmarks/modern-surface-1000.json'));
const runtime=await SwiftEditorRuntime.initialize(wasm), session=runtime.createModern({documentID:doc.documentID,actorID:'profile',epoch:'profile',document:doc});
const field=session.field(session.node({blockID:'note-1',path:[]}));
const cpu=new Session();cpu.connect();const post=name=>new Promise((resolve,reject)=>cpu.post(name,(e,r)=>e?reject(e):resolve(r)));
const samples=[];
for(let i=0;i<12;i++){
 const offset=session.text(field).length,target=session.captureTextRange(field,offset,offset);
 if(i===2){await post('Profiler.enable');await post('Profiler.start');}
 let t=performance.now();const result=session.execute({command:'replaceText',target,arguments:{text:'!',typingGroup:'same-group'}});const replaceMS=performance.now()-t;
 const caret=session.resolvePosition(result.focus).offset,range=session.captureTextRange(field,caret,caret);
 t=performance.now();const shortcut=session.execute({command:'typingShortcut',target:range,arguments:{}});const shortcutMS=performance.now()-t;
 samples.push({replaceMS,shortcutMS,status:shortcut.status});
}
const {profile}=await post('Profiler.stop');cpu.disconnect();
writeFileSync('.build/finishing/20261014/typing-command-profile/cpu.json',JSON.stringify(profile));
writeFileSync('.build/finishing/20261014/typing-command-profile/samples.json',JSON.stringify({diagnostic:true,samples},null,2)+'\n');session.close();
