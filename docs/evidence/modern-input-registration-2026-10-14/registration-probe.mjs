import { chromium } from '@playwright/test';
import { writeFileSync } from 'node:fs';
import { execFileSync } from 'node:child_process';
const browser = await chromium.launch({ headless:true });
const page = await browser.newPage();
try {
  await page.route('**/modern-engine.wasm', route => route.fulfill({path:'/Users/luca/Developer/block-editor/dist/block-editor.wasm',contentType:'application/wasm'}));
  await page.goto('http://127.0.0.1:4287/block-editor/@fs/Users/luca/Developer/block-editor/tests/helpers/modern-surface.html');
  await page.evaluate(async () => {
    const { mountModernSurface } = await import('/block-editor/@fs/Users/luca/Developer/block-editor/tests/helpers/modern-surface.tsx');
    window.modernAcceptance = await mountModernSurface({format:'seventwo.block-editor.document',formatVersion:1,documentID:'registration-probe',title:'Title',appearance:{fontFamily:'sans',fontSize:'default',pageWidth:'readable'},blocks:[{id:'p',type:'paragraph',content:[{type:'text',text:'First'}]},{id:'q',type:'paragraph',content:[{type:'text',text:'Second'}]}]});
  });
  const input = page.getByRole('textbox',{name:'Block text',exact:true}).first();await input.click();await page.keyboard.press('End');
  await page.evaluate(() => {
    const set = Map.prototype.set, del = Map.prototype.delete;
    const metric = {sets:0,deletes:0};window.registrationMetric=metric;
    Map.prototype.set=function(k,v){if(v instanceof HTMLElement && v.classList.contains('modern-input'))metric.sets++;return set.call(this,k,v)};
    Map.prototype.delete=function(k){const v=this.get(k);if(v instanceof HTMLElement && v.classList.contains('modern-input'))metric.deletes++;return del.call(this,k)};
    window.restoreRegistrationMetric=()=>{Map.prototype.set=set;Map.prototype.delete=del};
  });
  await page.keyboard.type('!');await input.filter({hasText:'First!'}).waitFor();
  const result = await page.evaluate(() => {const r={...window.registrationMetric,inputs:document.querySelectorAll('.modern-input').length,document:window.modernAcceptance.session.getSnapshot().document};window.restoreRegistrationMetric();window.modernAcceptance.dispose();return r});
  writeFileSync('.build/finishing/20261014/input-registration/registration-probe.json',JSON.stringify({diagnostic:true,sourceCommit:execFileSync('git',['rev-parse','HEAD'],{encoding:'utf8'}).trim(),...result,qualification:'Counts actual input-element registration map updates for one trusted native edit. Not a performance target or full preservation campaign.'},null,2)+'\n');
  console.log({sets:result.sets,deletes:result.deletes,inputs:result.inputs});
} finally {await browser.close()}
