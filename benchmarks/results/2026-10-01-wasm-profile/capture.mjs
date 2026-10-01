import { readFileSync,writeFileSync,mkdirSync } from 'node:fs';
import { resolve } from 'node:path';
import { pathToFileURL } from 'node:url';
import { execFileSync } from 'node:child_process';
import { createServer } from 'vite';
import { createHash } from 'node:crypto';
const {chromium}=await import(pathToFileURL(resolve('node_modules/playwright/index.mjs')).href);
const output='/tmp/editor-wasm-cpu-profile-20261001';mkdirSync(output,{recursive:true});
const source=readFileSync('benchmarks/workloads.json');const wasm=readFileSync('dist/block-editor.wasm');
const server=await createServer({configFile:resolve('vite.config.ts'),configLoader:'runner',cacheDir:'/tmp/st94-wasm-validation-20261001/profile-vite-cache',server:{host:'127.0.0.1',port:4297,strictPort:true}});await server.listen();
let browser;
try {
 let ready=false;for(let i=0;i<100;i++){try{const r=await fetch('http://127.0.0.1:4297/block-editor/');if(r.ok){ready=true;break;}}catch{}await new Promise(r=>setTimeout(r,100));}if(!ready)throw Error('Owned Vite server not ready');
 browser=await chromium.launch({headless:true});const page=await browser.newPage();
 await page.route('**/engine.wasm',r=>r.fulfill({body:wasm,contentType:'application/wasm'}));await page.goto('http://127.0.0.1:4297/block-editor/');
 await page.evaluate(async({root,config})=>{
  const {SwiftEditorRuntime}=await import(`${root}/src/swift.ts`);const perf=await import(`${root}/scripts/performance.mjs`);
  window.profileRuntime=await SwiftEditorRuntime.initialize(await WebAssembly.compile(await(await fetch('engine.wasm')).arrayBuffer()));
  window.profileConfig=config;window.profileTools=perf;
 },{root:`/block-editor/@fs${process.cwd()}`,config:JSON.parse(source)});
 const client=await page.context().newCDPSession(page);await client.send('Profiler.enable');await client.send('Profiler.setSamplingInterval',{interval:1000});
 for(const name of ['history-v1-512','history-v2-512']){
  await client.send('Profiler.start');
  const samples=await page.evaluate(async name=>{
   const selected=window.profileTools.performanceOptions(window.profileConfig,{profile:'baseline',cases:[name],repetitions:1,warmups:0});const result=[];
   await window.profileTools.runPerformance(window.profileConfig,selected,async request=>({ok:true,value:window.profileRuntime.call(request)}),s=>result.push(s));return result;
  },name);
  const {profile}=await client.send('Profiler.stop');
  const parents=new Map();for(const n of profile.nodes)for(const c of n.children??[])parents.set(c,n.id);
  const byId=new Map(profile.nodes.map(n=>[n.id,n]));const weights=new Map();const inclusive=new Map();
  for(let i=0;i<(profile.samples??[]).length;i++){
   const id=profile.samples[i],us=profile.timeDeltas?.[i]??1000;weights.set(id,(weights.get(id)??0)+us);
   let cursor=id;while(cursor!==undefined){inclusive.set(cursor,(inclusive.get(cursor)??0)+us);cursor=parents.get(cursor);}
  }
  const totalUs=(profile.timeDeltas??[]).reduce((a,b)=>a+b,0);
  const top=m=>[...m].sort((a,b)=>b[1]-a[1]).slice(0,60).map(([id,us])=>({function:byId.get(id).callFrame.functionName,url:byId.get(id).callFrame.url,ms:us/1000,percent:us/totalUs*100}));
  const summary={diagnosticOnly:true,profilingOverheadIncluded:true,sourceCommit:execFileSync('git',['rev-parse','HEAD'],{encoding:'utf8'}).trim(),sourceDirty:execFileSync('git',['status','--porcelain'],{encoding:'utf8'}).trim().length>0,artifactSHA256:createHash('sha256').update(wasm).digest('hex'),workloadSHA256:createHash('sha256').update(source).digest('hex'),browser:browser.version(),case:name,samplingIntervalUs:1000,complete:true,samples,profileSampleCount:profile.samples.length,totalMs:totalUs/1000,topSelf:top(weights),topInclusive:top(inclusive)};
  writeFileSync(`${output}/${name}.cpuprofile`,JSON.stringify(profile));writeFileSync(`${output}/${name}.json`,JSON.stringify(summary,null,2)+'\n');console.log(JSON.stringify({case:name,profileSamples:profile.samples.length,totalMs:summary.totalMs,topSelf:summary.topSelf.slice(0,5)}));
 }
} finally {if(browser)await browser.close();await server.close();}
