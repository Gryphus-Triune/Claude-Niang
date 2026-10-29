import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import {spawn} from 'node:child_process';
import {randomUUID} from 'node:crypto';
import {fileURLToPath} from 'node:url';
import {atomicJson} from '../runtime/claude-usage.mjs';
import {requestPipeRefresh} from '../runtime/shared.mjs';
import {pluginVersion} from '../runtime/metadata.mjs';
import * as fx from './fixtures/bundles.mjs';

const here=path.dirname(fileURLToPath(import.meta.url)),appDir=path.resolve(here,'..');
const wait=ms=>new Promise(resolve=>setTimeout(resolve,ms));
async function until(check,timeoutMs=8000){const end=Date.now()+timeoutMs;while(Date.now()<end){const v=check();if(v)return v;await wait(35);}throw new Error('timed out waiting');}
const read=file=>{try{return JSON.parse(fs.readFileSync(file,'utf8'));}catch{return null;}};
function setup(t,{delay=20,legacySettings={},config={}}={}){
  const root=fs.mkdtempSync(path.join(os.tmpdir(),'cn-worker-')),dataDir=path.join(root,'state');fs.mkdirSync(dataDir,{recursive:true});
  const configPath=path.join(root,'installation.json'),bundleFile=path.join(root,'bundle.json'),counter=path.join(root,'count.txt');
  atomicJson(configPath,{version:'1.1.0',appDir,dataDir,webviewDir:path.join(root,'webview'),nodePath:process.execPath,powershellPath:process.execPath,powershellPrefixArgs:[path.join(here,'fixtures','fake-helper.mjs')],...config});
  const personal=fx.bundle(),team=fx.bundle({selected:fx.ORG_TEAM,usage:{five_hour:{utilization:8,resets_at:new Date(Date.now()+3600000).toISOString()}}});
  atomicJson(bundleFile,{...personal,byOrganization:{[fx.ORG_MAX]:personal,[fx.ORG_TEAM]:team}});
  atomicJson(path.join(dataDir,'settings.json'),{preferredOrg:fx.ORG_MAX,...legacySettings});
  const env={...process.env,FAKE_BUNDLE_FILE:bundleFile,FAKE_COUNTER_FILE:counter,FAKE_DELAY_MS:String(delay)};
  const workers=[];
  const presence=()=>atomicJson(path.join(dataDir,'presence.json'),{visible:true,at:Date.now(),pid:process.pid});
  presence();const keep=setInterval(presence,500);
  t.after(async()=>{clearInterval(keep);for(const worker of workers)if(worker.exitCode===null && worker.signalCode===null){worker.kill();await until(()=>worker.exitCode!==null || worker.signalCode!==null,3000).catch(()=>{});}});
  return {root,dataDir,configPath,bundleFile,counter,env,workers,presence,count:()=>Number(fs.existsSync(counter)?fs.readFileSync(counter,'utf8'):0),
    status:()=>read(path.join(dataDir,'status.json')),
    click:()=>atomicJson(path.join(dataDir,'refresh.flag'),{id:randomUUID(),at:Date.now(),reason:'user'}),
    select:id=>atomicJson(path.join(dataDir,'settings.json'),{preferredOrg:id}),
    session:state=>atomicJson(path.join(dataDir,'session-reset.flag'),{id:randomUUID(),at:Date.now(),state})};
}
async function start(s){
  const worker=spawn(process.execPath,[path.join(appDir,'runtime','watch.mjs'),s.configPath,String(process.pid)],{windowsHide:true,env:s.env,stdio:['ignore','ignore','pipe']});
  let error='';worker.stderr.on('data',x=>error+=x);s.workers.push(worker);
  await until(()=>{if(worker.exitCode!==null)throw new Error('Worker exited '+error);return read(path.join(s.dataDir,'worker-status.json'))?.pid===worker.pid;});
  return worker;
}
const ask=s=>requestPipeRefresh(s.dataDir,{timeoutMs:7000,connectTimeoutMs:1000});
async function stop(worker){worker.kill();await until(()=>worker.exitCode!==null || worker.signalCode!==null);}
function mcpCall(env,messages){
  return new Promise((resolve,reject)=>{
    const child=spawn(process.execPath,[path.join(appDir,'runtime','mcp.mjs')],{windowsHide:true,env,stdio:['pipe','pipe','pipe']});
    let out='';const replies=[],expected=messages.filter(m=>m.id!==undefined).length;
    const timer=setTimeout(()=>{child.kill();reject(new Error('MCP timeout'));},10000);
    child.stdout.on('data',d=>{out+=d;let i;while((i=out.indexOf('\n'))>=0){replies.push(JSON.parse(out.slice(0,i)));out=out.slice(i+1);if(replies.length===expected){clearTimeout(timer);child.kill();resolve(replies);}}});
    child.on('error',e=>{clearTimeout(timer);reject(e);});
    for(const message of messages)child.stdin.write(JSON.stringify({jsonrpc:'2.0',...message})+'\n');
  });
}

test('startup and visibility never read, even with migrated automatic settings and old launch flags',async t=>{
  const s=setup(t,{legacySettings:{pollMinutes:2,peakTag:true}});
  fs.writeFileSync(path.join(s.dataDir,'refresh.flag'),'old startup refresh');
  await start(s);await wait(1700);assert.equal(s.count(),0);assert.equal(s.status().refreshMode,'manual');
  assert.match(s.status().error,/手动/);s.presence();await wait(1100);assert.equal(s.count(),0);
  s.click();await until(()=>s.status()?.ok);assert.equal(s.count(),1);assert.equal('pollMinutes' in s.status(),false);
  await wait(1000);assert.equal(s.count(),1);
});
test('worker-status.json stays fresh without being rewritten on every heartbeat, and reads are logged',async t=>{
  const s=setup(t),healthFile=path.join(s.dataDir,'worker-status.json');await start(s);
  const first=read(healthFile).at,firstSeq=read(healthFile).seq;await wait(1200);
  assert.equal(read(healthFile).at,first,'rewritten although nothing changed');
  await until(()=>read(healthFile).at!==first,4000);assert.ok(Date.now()-read(healthFile).at<5000);
  assert.ok(read(healthFile).seq>firstSeq,'heartbeat counter did not advance');
  s.click();await until(()=>s.status()?.ok);
  const log=await until(()=>{try{return fs.readFileSync(path.join(s.dataDir,'logs','claude-niang.log'),'utf8');}catch{return null;}});
  assert.match(log,/\[worker \d+\] 后台进程启动/);
  await until(()=>/\[worker \d+\] 读取完成：Max 20x，\d+ 个额度窗口/.test(fs.readFileSync(path.join(s.dataDir,'logs','claude-niang.log'),'utf8')));
  assert.doesNotMatch(fs.readFileSync(path.join(s.dataDir,'logs','claude-niang.log'),'utf8'),new RegExp(fx.ORG_MAX),'organization id logged');
});
test('signing in again lifts a rate-limit block from the previous sign-in',async t=>{
  const s=setup(t),limited=fx.bundle();limited.requests.usage=fx.request('u',429,{error:'rate'},{retryAfter:'600'});
  atomicJson(s.bundleFile,limited);await start(s);assert.equal((await ask(s)).errorCode,'RATE_LIMITED');assert.equal(s.count(),1);
  assert.equal((await ask(s)).errorCode,'RATE_LIMITED');assert.equal(s.count(),1,'blocked request still read');
  atomicJson(s.bundleFile,fx.bundle());s.session('signed-in');await until(()=>s.status()?.errorCode==='MANUAL');
  assert.equal(fs.existsSync(path.join(s.dataDir,'quota-backoff.json')),false);
  const fresh=await ask(s);assert.equal(fresh.ok,true);assert.equal(s.count(),2);
});
test('a click made before worker startup is consumed once and never replayed on restart',async t=>{
  const s=setup(t);s.click();const first=await start(s);await until(()=>s.status()?.ok);assert.equal(s.count(),1);
  await stop(first);await start(s);await wait(1100);assert.equal(s.count(),1);assert.equal(s.status().restored,true);
});
test('simultaneous manual refreshes share one read; MCP exposes structured cached data',async t=>{
  const s=setup(t);await start(s);
  const replies=await Promise.all([ask(s),ask(s),ask(s)]);assert.ok(replies.every(v=>v?.ok));assert.equal(s.count(),1);
  const mcp=await mcpCall({...process.env,CLAUDE_NIANG_DATA_DIR:s.dataDir},[
    {id:1,method:'initialize',params:{protocolVersion:'2025-06-18'}},
    {method:'notifications/initialized'},
    {id:2,method:'tools/list'},
    {id:3,method:'tools/call',params:{name:'get_claude_usage',arguments:{refresh:true}}}
  ]);
  assert.equal(mcp[0].result.serverInfo.version,pluginVersion);assert.equal(mcp[2].result.structuredContent.refreshMode,'manual');
  assert.equal(mcp[2].result.isError,false);assert.match(mcp[2].result.content[0].text,/Max 20x/);assert.equal(s.count(),1);
});

test('balance failures keep the old amount, back off independently and retry only on a later manual refresh',async t=>{
  const s=setup(t),argsFile=path.join(s.root,'helper-args.json');s.env.FAKE_ARGS_FILE=argsFile;
  atomicJson(s.bundleFile,fx.bundle({credits:{amount:725,currency:'USD'}}));
  let worker=await start(s);const first=await ask(s);
  assert.equal(first.credits.amountMinor,725);assert.equal(first.creditsStatus.state,'fresh');
  await stop(worker);
  // Simulate the balance cache aging without waiting thirty minutes.
  const oldAt=Date.now()-31*60000;
  atomicJson(path.join(s.dataDir,'status.json'),{...first,credits:{...first.credits,observedAt:oldAt}});
  const limited=fx.bundle();limited.requests.credits=fx.request('c',429,{error:'rate'},{retryAfter:'600'});
  atomicJson(s.bundleFile,limited);worker=await start(s);
  const failed=await ask(s);
  assert.equal(failed.ok,true);assert.equal(failed.queryOk,true);assert.equal(failed.credits.amountMinor,725);assert.equal(failed.credits.observedAt,oldAt);
  assert.equal(failed.creditsStatus.state,'error');assert.equal(failed.creditsStatus.errorCode,'RATE_LIMITED');assert.ok(failed.creditsStatus.retryAt>Date.now()+590000);
  assert.equal(fs.existsSync(path.join(s.dataDir,'quota-backoff.json')),false,'balance throttling must not block quota');
  assert.ok(read(argsFile).includes('-IncludeCredits'));
  await ask(s);assert.equal(s.count(),2,'the fifteen-second quota deduplication still applies');
  await wait(1100);assert.equal(s.count(),2,'balance failures must not trigger automatic requests');
  await stop(worker);
  atomicJson(s.bundleFile,fx.bundle());worker=await start(s);
  const duringPause=await ask(s);
  assert.equal(duringPause.queryOk,true);assert.equal(duringPause.credits.observedAt,oldAt);assert.equal(duringPause.creditsStatus.errorCode,'RATE_LIMITED');
  assert.equal(read(argsFile).includes('-IncludeCredits'),false,'balance pause must survive worker restart');
  await stop(worker);
  atomicJson(path.join(s.dataDir,'status.json'),{...duringPause,creditsStatus:{...duringPause.creditsStatus,retryAt:Date.now()-1}});
  atomicJson(s.bundleFile,fx.bundle({credits:{amount:900,currency:'USD'}}));worker=await start(s);
  const recovered=await ask(s);
  assert.ok(read(argsFile).includes('-IncludeCredits'),'a failure must not renew the thirty-minute success cache');
  assert.equal(recovered.credits.amountMinor,900);assert.ok(recovered.credits.observedAt>oldAt);assert.equal(recovered.creditsStatus.state,'fresh');assert.equal(recovered.creditsStatus.error,undefined);
  await stop(worker);
  atomicJson(s.bundleFile,fx.bundle());await start(s);
  const cached=await ask(s);
  assert.equal(read(argsFile).includes('-IncludeCredits'),false);assert.equal(cached.creditsStatus.state,'cached');assert.equal(cached.credits.observedAt,recovered.credits.observedAt);
});

test('balance failures never carry an amount into a different organization or new sign-in',async t=>{
  const s=setup(t),good=fx.bundle({credits:{amount:725,currency:'USD'}}),bad=fx.bundle({selected:fx.ORG_TEAM});
  bad.requests.credits=fx.request('c',500,{error:'server'});
  atomicJson(s.bundleFile,{...good,byOrganization:{[fx.ORG_MAX]:good,[fx.ORG_TEAM]:bad}});
  await start(s);assert.equal((await ask(s)).credits.amountMinor,725);
  s.select(fx.ORG_TEAM);const changed=await ask(s);
  assert.equal(changed.queryOk,true);assert.equal(changed.credits,null);assert.equal(changed.creditsStatus.state,'error');
  s.session('signed-in');await until(()=>s.status()?.errorCode==='MANUAL');
  const signedIn=await ask(s);assert.equal(signedIn.credits,null);assert.equal(signedIn.creditsStatus.state,'error');
});
test('organization selection bypasses same-context debounce and returns B immediately',async t=>{
  const s=setup(t);await start(s);assert.equal((await ask(s)).selectedOrg,fx.ORG_MAX);
  s.select(fx.ORG_TEAM);s.click();const second=await ask(s);
  assert.equal(second.selectedOrg,fx.ORG_TEAM);assert.equal(second.planLabel,'Team');assert.equal(second.windows[0].used,8);assert.equal(s.count(),2);
});
test('an A read finishing after selection of B never commits or returns A as current B quota',async t=>{
  const s=setup(t,{delay:1400});await start(s);const first=ask(s);await until(()=>s.count()===1);
  s.select(fx.ORG_TEAM);s.click();
  const observed=[];const probe=setInterval(()=>observed.push(s.status()),40);t.after(()=>clearInterval(probe));
  const invalidated=await first;assert.notEqual(invalidated?.selectedOrg,fx.ORG_MAX);assert.equal(invalidated?.ok,false);
  const b=await until(()=>s.status()?.ok && s.status()?.selectedOrg===fx.ORG_TEAM?s.status():null);
  assert.equal(b.windows[0].used,8);assert.equal(s.count(),2);assert.ok(observed.every(v=>!v?.ok || v.selectedOrg!==fx.ORG_MAX));
});
test('A to B to A while reading invalidates the original request even if final preference matches',async t=>{
  const s=setup(t,{delay:1600});await start(s);const first=ask(s);await until(()=>s.count()===1);
  s.select(fx.ORG_TEAM);s.click();await until(()=>s.status()?.selectedOrg===fx.ORG_TEAM);
  s.select(fx.ORG_MAX);s.click();await until(()=>s.status()?.selectedOrg===fx.ORG_MAX && !s.status()?.ok);
  assert.equal((await first)?.ok,false);await until(()=>s.status()?.ok);assert.equal(s.count(),2);
});
test('successful sign-out during a read clears quota and never initiates a new network request',async t=>{
  const s=setup(t,{delay:1300});await start(s);const first=ask(s);await until(()=>s.count()===1);
  s.session('signed-out');await until(()=>s.status()?.errorCode==='NOT_LOGGED_IN');
  assert.equal((await first)?.ok,false);await wait(900);assert.equal(s.count(),1);assert.equal(s.status().windows.length,0);
});
test('sign-in completion invalidates old data but waits for an explicit refresh',async t=>{
  const s=setup(t);await start(s);await ask(s);s.session('signed-in');
  await until(()=>s.status()?.errorCode==='MANUAL');await wait(700);assert.equal(s.count(),1);assert.equal(s.status().windows.length,0);
  const refreshed=await ask(s);assert.equal(refreshed.ok,true);assert.equal(s.count(),2);
});
test('network and unknown-schema failures retain last quota only after an explicit request',async t=>{
  const s=setup(t);let worker=await start(s);await ask(s);
  for(const code of ['NETWORK','INVALID']){
    await stop(worker);
    const broken=fx.bundle();if(code==='NETWORK')broken.requests.organizations=fx.request('o',0,'',{error:'ConnectionAborted'});
    else broken.requests.usage=fx.request('u',200,{unexpected:true});
    atomicJson(s.bundleFile,broken);worker=await start(s);await wait(600);const before=s.count();assert.equal(s.status().restored,true);
    const kept=await ask(s);assert.equal(kept.ok,true);assert.equal(kept.queryOk,false);assert.equal(kept.errorCode,code);assert.equal(kept.windows[0].used,37);
    await wait(700);assert.equal(s.count(),before+1);
  }
});
test('rate limit survives restart, does not retry automatically and never exposes A after switching to B',async t=>{
  const s=setup(t),limited=fx.bundle();limited.requests.usage=fx.request('u',429,{error:'rate'},{retryAfter:'60'});
  atomicJson(s.bundleFile,limited);const worker=await start(s);assert.equal((await ask(s)).errorCode,'RATE_LIMITED');assert.equal(s.count(),1);
  s.select(fx.ORG_TEAM);s.click();const b=await ask(s);assert.equal(b.errorCode,'RATE_LIMITED');assert.equal(b.windows.length,0);assert.equal(s.count(),1);
  await stop(worker);await start(s);await ask(s);await wait(700);assert.equal(s.count(),1);
});
function offline(s){const broken=fx.bundle();broken.requests.organizations=fx.request('o',0,'',{error:'ConnectionAborted'});atomicJson(s.bundleFile,broken);}
test('three failed reads in a row pause reading for 30 seconds and nothing is retried afterwards',async t=>{
  const s=setup(t,{config:{failurePauseMs:1500}});offline(s);await start(s);
  for(let i=1;i<=3;i++){assert.equal((await ask(s)).errorCode,'NETWORK');assert.equal(s.count(),i);}
  const paused=await ask(s);assert.equal(paused.errorCode,'NETWORK');assert.equal(s.count(),3);
  assert.match(paused.error,/^连不上 claude\.ai，请检查网络或代理（已连续失败 3 次，请 \d+ 秒后再刷新）$/);
  assert.match((await ask(s)).error,/^连不上 claude\.ai，请检查网络或代理（已连续失败 3 次/,'the note is not repeated');
  await wait(1700);assert.equal(s.count(),3,'no automatic read when the pause ends');
  assert.equal((await ask(s)).error,'连不上 claude.ai，请检查网络或代理');assert.equal(s.count(),4);
});
test('signing in ends a failure pause',async t=>{
  const s=setup(t);offline(s);await start(s);
  for(let i=0;i<3;i++)await ask(s);
  assert.match((await ask(s)).error,/已连续失败 3 次，请 \d+ 秒后再刷新/);assert.equal(s.count(),3);
  s.session('signed-in');await until(()=>s.status()?.errorCode==='MANUAL');
  await ask(s);assert.equal(s.count(),4);
});
test('a settings file caught mid-write is not mistaken for switching organization',async t=>{
  const s=setup(t);await start(s);assert.equal((await ask(s)).selectedOrg,fx.ORG_MAX);
  fs.writeFileSync(path.join(s.dataDir,'settings.json'),'{"preferredOrg":');await wait(1100);
  const kept=s.status();assert.equal(kept.ok,true);assert.equal(kept.selectedOrg,fx.ORG_MAX);assert.equal(kept.errorCode,undefined);
  s.select(fx.ORG_MAX);await wait(700);assert.equal(s.status().ok,true);assert.equal(s.count(),1);
});
