import assert from 'node:assert/strict';
import { webkit } from '/Users/luca/Developer/block-editor/node_modules/playwright/index.mjs';
import {readFileSync,writeFileSync} from 'node:fs';
import {execFileSync} from 'node:child_process';
import {createHash} from 'node:crypto';
const browser=await webkit.launch({headless:true}),page=await browser.newPage({viewport:{width:1280,height:900}});
const fixture=readFileSync('benchmarks/modern-surface-1000.json'),wasm=readFileSync('dist/block-editor.wasm');
const report={diagnostic:true,qualification:"Instrumented five edits after three warmups; excludes a frozen acceptance claim. Complete independently expected document checked after all edits.",sourceCommit:execFileSync('git',['rev-parse','HEAD'],{encoding:'utf8'}).trim(),fixtureSHA256:createHash('sha256').update(fixture).digest('hex'),wasmSHA256:createHash('sha256').update(wasm).digest('hex'),edits:[]};
try {
 await page.route('**/modern-engine.wasm',r=>r.fulfill({body:wasm,contentType:'application/wasm'}));await page.goto('http://127.0.0.1:4398/modern-performance.html');
 await page.evaluate(async encoded=>{await window.mountModernPerformance(JSON.parse(encoded));},fixture.toString());await page.getByRole('textbox',{name:'Document title',exact:true}).waitFor({timeout:120000});
 const input=page.locator('[data-block-type="paragraph"]').filter({hasText:'Note 0001.'}).getByRole('textbox',{name:'Block text',exact:true});
 await input.evaluate(root=>{root.focus();const r=document.createRange();r.selectNodeContents(root);r.collapse(false);const s=document.getSelection();s.removeAllRanges();s.addRange(r);});
 await page.evaluate(()=>new Promise(r=>requestAnimationFrame(()=>requestAnimationFrame(r))));
 for(let i=0;i<3;i++){await page.keyboard.press('!');await page.evaluate(()=>new Promise(r=>requestAnimationFrame(()=>requestAnimationFrame(r))));}
 await page.evaluate(()=>{const s=window.modernPerformance.session;window.pathTimes=[];for(const name of ['execute','captureTextRange','resolvePosition','localSelection','setLocalSelection','availability','nodeBindings','text','capabilities','asyncRequests','markState','semanticState','logicalFields','node','field']){const f=s[name].bind(s);s[name]=(...args)=>{const t=performance.now();try{return f(...args);}finally{window.pathTimes.push({name,command:name==='execute'?args[0].command:undefined,ms:performance.now()-t});}}}});
 for(let i=0;i<5;i++){
  await page.evaluate(()=>{window.pathTimes=[];const e=document.querySelector('[data-measurement-input]')??document.activeElement;e.addEventListener('keydown',()=>{window.editStart=performance.now()},{once:true,capture:true});});
  await page.keyboard.press('!');await page.evaluate(()=>new Promise(r=>requestAnimationFrame(()=>requestAnimationFrame(r))));
  report.edits.push(await page.evaluate(()=>({calls:window.pathTimes,elapsedMS:performance.now()-window.editStart})));
 }
 const expected=JSON.parse(fixture.toString()); expected.blocks=expected.blocks.map(b=>b.id==='note-1'?{...b,content:[{type:'text',text:'Note 0001.'+'!'.repeat(8)}]}:b); assert.deepEqual(await page.evaluate(()=>window.modernPerformance.session.getSnapshot().document),expected);
 report.errors=await page.evaluate(()=>window.modernPerformance.errors);report.complete=true;
}finally{writeFileSync('.build/finishing/20261014/caret-read-cache/original.json',JSON.stringify(report,null,2)+'\n');await browser.close();}
