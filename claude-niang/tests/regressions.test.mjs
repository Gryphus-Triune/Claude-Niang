import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import {EventEmitter} from 'node:events';
import {spawnSync} from 'node:child_process';
import {fileURLToPath} from 'node:url';
import {normalizeClaudeBundle,normalizeUsage,readUsage,newOrganizationCache,classifyRequest} from '../runtime/claude-usage.mjs';
import {mergeUsageSnapshot,createFailurePause,readRefreshRequest} from '../runtime/refresh-queue.mjs';
import {advanceLedger,updateDailyLedger,localDay} from '../runtime/daily.mjs';
import {describe,negotiateVersion} from '../runtime/mcp.mjs';
import * as fx from './fixtures/bundles.mjs';

test('unknown and broken HTTP-200 shapes retain previous data as an explicitly failed read',()=>{
  const good=normalizeClaudeBundle(fx.bundle());
  for(const usage of [{},{unexpected_field:{value:42}},{limits:{}},{five_hour:{}},{spend:'oops'},{extra_usage:{is_enabled:'yes'}},{limits:[{kind:'future',percent:20}]}]){
    const next=normalizeClaudeBundle(fx.bundle({usage}));
    assert.equal(next.queryOk,false,JSON.stringify(usage));assert.equal(next.errorCode,'INVALID');assert.equal(next.clearPrevious,false);
    const kept=mergeUsageSnapshot(good,next);assert.equal(kept.ok,true);assert.equal(kept.queryOk,false);assert.deepEqual(kept.windows,good.windows);
  }
});
test('explicit empty supported shapes stay distinct from schema failure',()=>{
  for(const usage of [{limits:[]},{five_hour:null,seven_day:null},{extra_usage:{is_enabled:false}}]){
    const s=normalizeClaudeBundle(fx.bundle({usage}));assert.equal(s.queryOk,true);assert.equal(s.errorCode,'NO_WINDOWS');assert.equal(s.clearPrevious,true);
  }
  assert.equal(normalizeUsage({spend:{enabled:true,used:{}}}).invalid,true,'unknown spend is not presented as zero cost');
});
test('partial malformed windows do not replace the complete last good snapshot',()=>{
  const next=normalizeClaudeBundle(fx.bundle({usage:{five_hour:{utilization:10},seven_day:{utilization:'broken'}}}));
  assert.equal(next.ok,false);assert.equal(next.windows.length,0);assert.equal(next.queryOk,false);
});
test('bootstrap plan survives organization caching without leaking to another organization',async()=>{
  const dir=fs.mkdtempSync(path.join(os.tmpdir(),'cn-plan-'));let now=Date.now(),calls=0;
  const spawnProcess=(_file,args)=>{
    const child=new EventEmitter();child.stderr=new EventEmitter();calls++;
    const selected=args.includes('-PreferredOrg')?args[args.indexOf('-PreferredOrg')+1]:fx.ORG_MAX;
    const b=fx.bundle({selected,orgList:[{uuid:fx.ORG_MAX,name:'Personal'},{uuid:fx.ORG_TEAM,name:'Team'}]});
    if(args.includes('-SkipOrganizations'))delete b.requests.organizations;
    else if(calls===1)b.requests.bootstrap=fx.request('b',200,{account:{memberships:[{organization:fx.orgs[0]}]}});
    setTimeout(()=>{fs.writeFileSync(args[args.indexOf('-OutFile')+1],JSON.stringify(b));child.emit('close',0);},1);return child;
  };
  const config={appDir:'unused',dataDir:dir},cache=newOrganizationCache(),options={spawnProcess,orgCache:cache,now:()=>now};
  const first=await readUsage(config,options);assert.equal(first.plan,'max_20x');
  now+=1000;const second=await readUsage(config,options);assert.equal(second.plan,'max_20x');assert.equal(second.planKnown,true);
  now+=1000;const other=await readUsage(config,{...options,preferredOrg:fx.ORG_TEAM});assert.equal(other.planKnown,false);assert.notEqual(other.accountKey,first.accountKey);
});
test('daily ledgers are separate per organization, and absent weekly quota has no daily value',()=>{
  const dir=fs.mkdtempSync(path.join(os.tmpdir(),'cn-daily-')),now=Date.now();
  const snap=(accountKey,used)=>({ok:true,accountKey,windows:[{kind:'weekly',used,resetsAt:2000000000}]});
  updateDailyLedger(dir,snap('a',20),now);const a=updateDailyLedger(dir,snap('a',33),now+1000);assert.equal(a.weeklyUsed,13);
  assert.equal(updateDailyLedger(dir,{ok:true,accountKey:'b',windows:[{kind:'session',used:4}]},now+2000),null);
  updateDailyLedger(dir,snap('b',10),now+3000);const again=updateDailyLedger(dir,snap('a',35),now+4000);assert.equal(again.weeklyUsed,15);
});
test('weekly reset counts the new window even when its first sample is higher',()=>{
  const now=Date.now(),snap=(used,resetsAt)=>({ok:true,accountKey:'a',windows:[{kind:'weekly',used,resetsAt}]});
  const previous=advanceLedger(null,snap(2,2000000000),now);
  assert.equal(advanceLedger(previous,snap(4,2000604800),now+1000).consumed,4);
});
test('MCP distinguishes expired and restored values and rejects previous-day statistics',()=>{
  const now=Date.now();
  const snapshot={ok:true,queryOk:false,restored:true,accountKey:'a',observedAt:now-86400000,
    windows:[{kind:'session',label:'Session',used:10,remaining:90,resetsAt:Math.floor(now/1000)-1}],
    today:{accountKey:'a',day:localDay(now-86400000),weeklyUsed:50,since:now-86400000}};
  const {data,text}=describe(snapshot,now);
  assert.equal(data.freshness,'cached');assert.equal(data.queryOk,false);assert.equal(data.windows[0].freshness,'expired');
  assert.equal(data.windows[0].remaining,null);assert.equal(data.windows[0].lastRemaining,90);assert.equal(data.todayWeeklyUsed,null);
  assert.doesNotMatch(text,/今日观测/);assert.equal(data.refreshMode,'manual');assert.equal('peakHours' in data,false);
});
test('an unavailable explicit organization never silently returns another organization',async()=>{
  const dir=fs.mkdtempSync(path.join(os.tmpdir(),'cn-missing-org-'));
  const spawnProcess=(_file,args)=>{
    const child=new EventEmitter();child.stderr=new EventEmitter();
    setTimeout(()=>{fs.writeFileSync(args[args.indexOf('-OutFile')+1],JSON.stringify(fx.bundle()));child.emit('close',0);},1);return child;
  };
  const requested='ffffffff-0000-4000-8000-000000000099';
  const result=await readUsage({appDir:'unused',dataDir:dir},{preferredOrg:requested,spawnProcess});
  assert.equal(result.errorCode,'ORG_UNAVAILABLE');assert.equal(result.selectedOrg,requested);assert.equal(result.windows.length,0);assert.equal(result.clearPrevious,true);
});
test('the third failed read in a row starts a 30-second pause; a success, the pause or a reset starts the count again',()=>{
  let now=0;const pause=createFailurePause({now:()=>now});
  assert.equal(pause.record(false),false);assert.equal(pause.record(false),false);assert.equal(pause.record(true),false);assert.equal(pause.failures,0);
  pause.record(false);pause.record(false);assert.equal(pause.remaining(),0);
  assert.equal(pause.record(false),true);assert.equal(pause.remaining(),30000);
  now=29999;assert.equal(pause.remaining(),1);now=30000;assert.equal(pause.remaining(),0);
  pause.record(false);pause.record(false);assert.equal(pause.remaining(),0,'two new failures after a pause are not enough');
  assert.equal(pause.record(false),true);pause.reset();assert.equal(pause.remaining(),0);assert.equal(pause.failures,0);
});
test('MCP answers a supported protocol version and falls back to its newest one',()=>{
  assert.equal(negotiateVersion('2025-03-26'),'2025-03-26');
  assert.equal(negotiateVersion('2099-01-01'),'2025-11-25');
  assert.equal(negotiateVersion(undefined),'2025-11-25');
});

function isolatedMcp(t){
  const dir=fs.mkdtempSync(path.join(os.tmpdir(),'cn-mcp-session-'));
  t.after(()=>fs.rmSync(dir,{recursive:true,force:true}));
  const marker=path.join(dir,'session-reset.flag'),status=path.join(dir,'status.json');
  let sequence=0;
  const snapshot={ok:true,queryOk:true,observedAt:Date.now(),planLabel:'Previous account',org:{name:'Old organization'},credits:{amountMinor:500,currency:'USD'},
    windows:[{kind:'session',label:'5 小时',used:37,remaining:63,resetsAt:Math.floor(Date.now()/1000)+3600}]};
  return {marker,snapshot,
    save:value=>fs.writeFileSync(status,JSON.stringify(value)),
    session:state=>fs.writeFileSync(marker,JSON.stringify({id:state+'-'+(++sequence),at:Date.now(),state})),
    call(refresh){
      const request={jsonrpc:'2.0',id:1,method:'tools/call',params:{name:'get_claude_usage',arguments:{refresh}}};
      const run=spawnSync(process.execPath,[fileURLToPath(new URL('../runtime/mcp.mjs',import.meta.url))],{
        input:JSON.stringify(request)+'\n',encoding:'utf8',timeout:5000,windowsHide:true,
        env:{...process.env,CLAUDE_NIANG_DATA_DIR:dir}});
      assert.ifError(run.error);assert.equal(run.status,0,run.stderr);
      return JSON.parse(run.stdout.trim()).result;
    }
  };
}
test('MCP rejects the previous session with the worker stopped, with or without a refresh request',t=>{
  const s=isolatedMcp(t);
  s.session('signed-in');s.save({...s.snapshot,sessionEpoch:readRefreshRequest(s.marker)});
  for(const state of ['signed-in','signed-out']){
    s.session(state);
    for(const refresh of [false,true]){
      const reply=s.call(refresh),data=reply.structuredContent;
      assert.equal(reply.isError,true);assert.equal(data.ok,false);assert.equal(data.queryOk,false);assert.equal(data.freshness,'unavailable');
      assert.deepEqual(data.windows,[]);assert.equal(data.credits,null);assert.equal(data.organization,null);
      assert.equal(data.errorCode,state==='signed-out'?'NOT_LOGGED_IN':'SESSION_CHANGED');
      assert.doesNotMatch(reply.content[0].text,/Previous account|Old organization|63%/);
    }
  }
});
test('MCP permits matching and legacy unmarked snapshots but rejects missing or unreadable session evidence',t=>{
  const s=isolatedMcp(t);
  s.save(s.snapshot);assert.equal(s.call(false).structuredContent.ok,true,'legacy snapshot without a session marker');
  s.session('signed-in');assert.equal(s.call(false).structuredContent.ok,false,'legacy snapshot after a session change');
  s.save({...s.snapshot,sessionEpoch:readRefreshRequest(s.marker)});
  assert.equal(s.call(false).structuredContent.windows[0].remaining,63,'matching current session');
  fs.unlinkSync(s.marker);assert.equal(s.call(false).structuredContent.ok,false,'recorded session marker was removed');
  s.save(s.snapshot);fs.writeFileSync(s.marker,'');
  assert.equal(s.call(false).structuredContent.ok,false,'empty in-progress session marker');
  fs.writeFileSync(s.marker,'{"state":');s.save({...s.snapshot,sessionEpoch:readRefreshRequest(s.marker)});
  assert.equal(s.call(false).structuredContent.ok,false,'matching token cannot validate a malformed marker');
});
test('Retry-After preserves long seconds and HTTP dates and bounds pathological waits',()=>{
  const delay=value=>classifyRequest({status:429,retryAfter:value}).retryAfterMs;
  assert.equal(delay('10800'),3*3600000);
  assert.equal(delay('172800'),2*86400000);
  assert.equal(delay(String(45*86400)),45*86400000);
  const now=Date.now(),date=new Date(now+3*3600000).toUTCString(),wait=delay(date);
  assert.ok(wait>=3*3600000-2000 && wait<=3*3600000,'HTTP-date three hours ahead');
  const overflow=delay('9'.repeat(400));
  assert.ok(Number.isSafeInteger(overflow) && overflow>45*86400000);
  assert.ok(Number.isFinite(new Date(Date.now()+overflow).getTime()),'overflow delay remains a representable deadline');
  assert.ok(Date.now()+overflow<253402300799999,'deadline also fits PowerShell/.NET dates');
  assert.equal(delay('0'),30000);
  assert.equal(delay('not a date'),null);assert.equal(delay(''),null);
});
