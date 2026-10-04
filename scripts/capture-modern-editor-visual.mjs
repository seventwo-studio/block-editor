import { chromium, webkit } from 'playwright';
import { createServer } from 'node:http';
import { readFile, mkdir, writeFile } from 'node:fs/promises';
import { resolve, relative, extname } from 'node:path';
import { fileURLToPath } from 'node:url';
import { createHash } from 'node:crypto';
import assert from 'node:assert/strict';

// A design reference capture, not a production editor or native acceptance test.
const root = fileURLToPath(new URL('../', import.meta.url));
const output = resolve(root, 'docs/evidence/modern-editor-visual-2026-10-05');
await mkdir(output, { recursive: true });
const mime = { '.html': 'text/html', '.json': 'application/json' };
const server = createServer(async (request, response) => {
  try {
    const path = resolve(root, `.${decodeURIComponent(new URL(request.url, 'http://localhost').pathname)}`);
    if (relative(root, path).startsWith('..')) throw new Error('Outside repository');
    const data = await readFile(path);
    response.writeHead(200, { 'Content-Type': mime[extname(path)] || 'application/octet-stream' });
    response.end(data);
  } catch { response.writeHead(404); response.end(); }
});
await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
const origin = `http://127.0.0.1:${server.address().port}`;
const manifest = { recordedAt: new Date().toISOString(), qualification: 'Headless design-reference HTML; no shared editor, native input, device, assistive technology or production WASM acceptance.', sources: [], contrast: [], captures: [], columnChecks: [] };
const digest = bytes => createHash('sha256').update(bytes).digest('hex');
for (const path of ['docs/design/modern-editor-visual-preview.html', 'docs/design/modern-editor-tokens.json', 'Examples/AppleDemo/Fixtures/rich-blocks.json', 'scripts/capture-modern-editor-visual.mjs']) {
  manifest.sources.push({ path, sha256: digest(await readFile(resolve(root, path))) });
}
const tokens = JSON.parse(await readFile(resolve(root, 'docs/design/modern-editor-tokens.json'), 'utf8'));
function luminance(hex) {
  return hex.slice(1).match(/../g).map(value => parseInt(value, 16) / 255).map(value => value <= .04045 ? value / 12.92 : ((value + .055) / 1.055) ** 2.4).reduce((sum, value, i) => sum + value * [.2126, .7152, .0722][i], 0);
}
for (const theme of ['light', 'dark']) {
  for (const [foreground, background, minimum] of [
    ...['canvas','surface','raised','selection'].flatMap(background => [['text',background,4.5],['muted',background,4.5]]),
    ['accent','canvas',4.5],['accent','accentSurface',4.5],['error','errorSurface',4.5],['warning','warningSurface',4.5],
    ...['text','accent','warning','error','blue','purple'].flatMap(foreground => ['canvas','surface','accentSurface','warningSurface','errorSurface','blueSurface','purpleSurface'].map(background => [foreground,background,4.5])),
    ...['canvas','surface','raised','accentSurface','selection'].flatMap(background => [['focus',background,3],['controlBorder',background,3]])
  ]) {
    const a = luminance(tokens[theme][foreground]), b = luminance(tokens[theme][background]);
    const ratio = (Math.max(a,b)+.05)/(Math.min(a,b)+.05);
    manifest.contrast.push({theme,foreground,background,ratio,minimum,pass:ratio>=minimum});
    assert(ratio >= minimum, `${theme} ${foreground}/${background}: ${ratio} < ${minimum}`);
  }
}
async function capture(browser, engine, scenario, theme, viewport, extras = {}, label = '') {
  const page = await browser.newPage({ viewport });
  const errors = [];
  page.on('pageerror', error => errors.push(error.message));
  const query = new URLSearchParams({case:scenario,theme,width:scenario==='columns'?'960':'680',size:'17',font:'sans',...extras});
  await page.goto(`${origin}/docs/design/modern-editor-visual-preview.html?${query}`);
  await page.waitForFunction(()=>window.visualStudyReady===true);
  await page.evaluate(()=>document.fonts.ready);
  assert.deepEqual(errors, [], 'Preview script errors');
  const metrics = await page.evaluate(() => {
    const article = document.querySelector('article');
    const rect = article.getBoundingClientRect();
    const columns = document.querySelector('.columns');
    const body = document.querySelector('.block p');
    const lines = new Map();
    if(body) {
      const walker = document.createTreeWalker(body,NodeFilter.SHOW_TEXT);
      while(walker.nextNode()) { const node=walker.currentNode; for(let i=0;i<node.length;i++) {const range=document.createRange();range.setStart(node,i);range.setEnd(node,i+1);const r=range.getBoundingClientRect();const line=Math.round(r.top);lines.set(line,(lines.get(line)||0)+1);} }
    }
    return { bodyOverflow:document.documentElement.scrollWidth>innerWidth, articleWidth:rect.width, bodyFont:getComputedStyle(article).fontSize, firstParagraphLineLengths:[...lines.values()], columns:columns ? {stacked:columns.dataset.stacked==='true',minimum:Number(columns.dataset.minimum),widths:[...columns.querySelectorAll(':scope > .column')].map(element=>element.getBoundingClientRect().width),split:document.querySelector('#split').value,order:[...columns.querySelectorAll(':scope > .column')].map(element=>element.getAttribute('aria-label'))} : null };
  });
  assert.equal(metrics.bodyOverflow,false,`${scenario} ${theme}: document overflow`);
  if(metrics.columns) {
    assert.deepEqual(metrics.columns.order,['First column','Second column']);
    if(!metrics.columns.stacked) assert(metrics.columns.widths.every(width=>width>=metrics.columns.minimum-1));
    assert.equal(metrics.columns.split,'50','Presentation rewrote the split value');
  }
  const file = `${engine}-${scenario}-${theme}-${viewport.width}${label ? `-${label}` : ''}.png`;
  await page.screenshot({path:resolve(output,file),fullPage:true});
  manifest.captures.push({file,sha256:digest(await readFile(resolve(output,file))),engine,browserVersion:browser.version(),scenario,theme,viewport,query:Object.fromEntries(query),metrics});
  await page.close();
}
const browsers = [];
try {
  const chrome = await chromium.launch({headless:true}); browsers.push(chrome);
  const desktop = {width:1440,height:1000}, narrow = {width:390,height:844};
  for(const scenario of ['long','blank','nested','media','table','contextual','columns','states']) {
    for(const theme of ['light','dark']) for(const viewport of [desktop,narrow]) await capture(chrome,'chromium',scenario,theme,viewport);
  }
  for(const width of ['680','720','760']) for(const size of ['16','17']) await capture(chrome,'chromium','long','light',desktop,{width,size},`width${width}-text${size}`);
  for(const font of ['serif','mono']) await capture(chrome,'chromium','long','dark',narrow,{font},font);
  for(const theme of ['light','dark']) {
    await capture(chrome,'chromium','columns',theme,desktop,{size:'20'},'large-text');
    await capture(chrome,'chromium','columns',theme,{width:720,height:1000},{size:'20'},'large-text-stack');
  }
  // Measure threshold transitions and extreme splits without claiming a native resize gesture.
  const page = await chrome.newPage();
  for(const size of [17,20]) for(const width of [720,820,960,1100]) {
    await page.setViewportSize({width,height:1000});
    await page.goto(`${origin}/docs/design/modern-editor-visual-preview.html?case=columns&theme=dark&width=960&size=${size}`);
    await page.waitForFunction(()=>window.visualStudyReady===true);
    for(const requested of [30,50,70]) {
      await page.locator('#split').evaluate((element,value)=>{element.value=String(value);element.dispatchEvent(new Event('input'));},requested);
      const check = await page.evaluate(()=>({stacked:document.querySelector('.columns').dataset.stacked==='true',minimum:Number(document.querySelector('.columns').dataset.minimum),widths:[...document.querySelectorAll('.column')].map(el=>el.getBoundingClientRect().width),storedSplit:document.querySelector('#split').value,bodyOverflow:document.documentElement.scrollWidth>innerWidth}));
      assert.equal(check.storedSplit,String(requested));
      assert.equal(check.bodyOverflow,false);
      if(!check.stacked) assert(check.widths.every(width=>width>=check.minimum-1));
      manifest.columnChecks.push({viewportWidth:width,size,requested,...check});
    }
  }
  // A doubled CSS body font models the visual effect of text enlargement only.
  await page.goto(`${origin}/docs/design/modern-editor-visual-preview.html?case=columns&theme=dark&width=960&size=17`);
  await page.waitForFunction(()=>window.visualStudyReady===true);
  await page.locator('#size').evaluate(element=>{element.add(new Option('Enlarged · 34','34'));element.value='34';element.dispatchEvent(new Event('change'));});
  assert.equal(await page.locator('.columns').getAttribute('data-stacked'),'true');
  assert.equal(await page.locator('#split').inputValue(),'50');
  manifest.enlargedTextCheck = await page.evaluate(()=>({viewportWidth:innerWidth,bodySize:34,stacked:document.querySelector('.columns').dataset.stacked==='true',storedSplit:document.querySelector('#split').value,bodyOverflow:document.documentElement.scrollWidth>innerWidth,qualification:'Doubled document font; not browser zoom or native text-scaling acceptance'}));
  assert.equal(manifest.enlargedTextCheck.bodyOverflow,false);
  await page.close();
  const safari = await webkit.launch({headless:true}); browsers.push(safari);
  for(const [scenario,theme,viewport] of [['long','dark',desktop],['contextual','dark',narrow],['table','light',narrow],['columns','dark',desktop]]) await capture(safari,'webkit',scenario,theme,viewport);
  await writeFile(resolve(output,'manifest.json'),JSON.stringify(manifest,null,2)+'\n');
  console.log(JSON.stringify({captures:manifest.captures.length,contrastPairs:manifest.contrast.length,columnChecks:manifest.columnChecks.length,engines:manifest.captures.map(c=>c.engine).filter((v,i,a)=>a.indexOf(v)===i),output}));
} finally {
  for(const browser of browsers) await browser.close();
  await new Promise(resolve=>server.close(resolve));
}
