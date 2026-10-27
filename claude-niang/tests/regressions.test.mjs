import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import {EventEmitter} from 'node:events';
import {normalizeClaudeBundle,normalizeUsage,readUsage,newOrganizationCache} from '../runtime/claude-usage.mjs';
import {mergeUsageSnapshot,createFailurePause} from '../runtime/refresh-queue.mjs';
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
