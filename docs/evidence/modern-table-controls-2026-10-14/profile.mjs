import { chromium } from '/Users/luca/Developer/block-editor/node_modules/playwright/index.mjs';
import { readFileSync, writeFileSync } from 'node:fs';
import { createHash } from 'node:crypto';
const output = process.argv[2];
const browser = await chromium.launch({headless:true});
const page = await browser.newPage({viewport:{width:1280,height:900}});
const fixture = readFileSync('benchmarks/modern-surface-1000.json');
const wasm = readFileSync('dist/block-editor.wasm');
const report = {diagnostic:true,fixtureSHA256:createHash('sha256').update(fixture).digest('hex'),wasmSHA256:createHash('sha256').update(wasm).digest('hex'),events:[]};
page.on('console',event=>{if(event.text().startsWith('modern-read-profile')) report.events.push(event.text());});
try {
  await page.route('**/modern-engine.wasm',route=>route.fulfill({body:wasm,contentType:'application/wasm'}));
  await page.goto('http://127.0.0.1:4397/modern-performance.html');
  await page.evaluate(async encoded=>{window.modernPerformanceDiagnostic=true;await window.mountModernPerformance(JSON.parse(encoded));},fixture.toString());
  await page.getByRole('textbox',{name:'Document title',exact:true}).waitFor({timeout:120000});
  report.mountEnd=report.events.length;
  const input=page.locator('[data-block-type="paragraph"]').filter({hasText:'Note 0001.'}).getByRole('textbox',{name:'Block text',exact:true});
  await input.evaluate(root=>{root.focus();const range=document.createRange();range.selectNodeContents(root);range.collapse(false);const selection=document.getSelection();selection.removeAllRanges();selection.addRange(range);});
  await page.keyboard.press('!');
  await page.waitForFunction(()=>window.modernPerformance.session.getSnapshot().document.blocks.find(b=>b.id==='note-1').content[0].text.endsWith('!'));
  report.inputEnd=report.events.length;
  await page.getByRole('button',{name:'Insert',exact:true}).click();
  await page.getByRole('textbox',{name:'Search blocks'}).waitFor();
  report.menuEnd=report.events.length;
  await page.getByRole('textbox',{name:'Search blocks'}).press('Escape');
  report.errors=await page.evaluate(()=>window.modernPerformance.errors);
} catch(error){report.error=String(error);throw error;}
finally {writeFileSync(output,JSON.stringify(report,null,2)+'\n');await browser.close();}
