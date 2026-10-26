import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import {EventEmitter} from 'node:events';
import {normalizeClaudeBundle,normalizeUsage,classifyRequest,resetSeconds,runBrowserFetch,browserArguments,readUsage,chooseOrganization} from '../runtime/claude-usage.mjs';
import {identifyClaudePlan} from '../runtime/plan.mjs';
import * as fx from './fixtures/bundles.mjs';

const NOW=Date.parse('2026-10-26T06:00:00Z');

test('Max 20x with old usage shape, per-model weekly and extra usage',()=>{
  const s=normalizeClaudeBundle(fx.bundle(),{now:NOW});
  assert.equal(s.ok,true);assert.equal(s.queryOk,true);
  assert.equal(s.planLabel,'Max 20x');assert.equal(s.plan,'max_20x');assert.equal(s.planKnown,true);
  assert.deepEqual(s.windows.map(w=>w.key),['session','weekly','weekly-model:opus','extra']);
  const session=s.windows[0];
  assert.equal(session.label,'5 小时');assert.equal(session.used,37);assert.equal(session.remaining,63);assert.equal(session.minutes,300);
  assert.equal(session.resetsAt,Date.parse('2026-10-26T09:00:00.123Z')/1000|0);
  assert.equal(s.windows[2].label,'每周 · Opus');assert.equal(s.windows[2].resetsAt,null);
  const extra=s.windows[3];
  assert.equal(extra.kind,'extra');assert.equal(extra.used,38.5);assert.equal(extra.remainingMinor,1230);assert.equal(extra.currency,'USD');
  assert.equal(s.org.name,"Personal Organization");assert.equal(s.org.count,2);
  assert.match(s.accountKey,/^[0-9a-f]{64}$/);
  assert.equal(JSON.stringify(s).includes('sessionKey'),false);
});

test('new limits array with a scoped Fable window and spend object',()=>{
  const s=normalizeClaudeBundle(fx.bundle({usage:fx.usageNew}),{now:NOW});
  assert.equal(s.ok,true);
  assert.deepEqual(s.windows.map(w=>[w.label,w.used,w.remaining]),[['5 小时',12,88],['每周',40,60],['每周 · Fable',55,45],['额外用量',25,75]]);
  assert.equal(s.extra.limitMinor,5000);assert.equal(s.extra.usedMinor,1250);
});

test('Free plan answers with empty windows instead of an error',()=>{
  const free=[{uuid:fx.ORG_MAX,name:'Me',capabilities:['chat'],rate_limit_tier:'default_claude_ai'}];
  const s=normalizeClaudeBundle(fx.bundle({orgList:free,usage:fx.usageFree}),{now:NOW});
  assert.equal(s.planLabel,'Free');assert.equal(s.ok,false);assert.equal(s.queryOk,true);
  assert.equal(s.errorCode,'NO_WINDOWS');assert.match(s.error,/Free/);
});

test('not signed in: no session cookie means no network request and NOT_LOGGED_IN',()=>{
  const s=normalizeClaudeBundle(fx.bundle({session:false}),{now:NOW});
  assert.equal(s.errorCode,'NOT_LOGGED_IN');assert.equal(s.loggedIn,false);
});

test('expired session: organizations 401/403 JSON is NOT_LOGGED_IN',()=>{
  const b=fx.bundle();b.requests.organizations=fx.request('https://claude.ai/api/organizations',403,{type:'error',error:{type:'permission_error',message:'Invalid authorization'}});delete b.requests.usage;
  assert.equal(normalizeClaudeBundle(b,{now:NOW}).errorCode,'NOT_LOGGED_IN');
});

test('Cloudflare challenge is reported, not treated as signed out',()=>{
  const b=fx.bundle();b.requests.organizations=fx.request('https://claude.ai/api/organizations',403,fx.challengeHtml,{contentType:'text/html; charset=UTF-8',cf:'challenge'});delete b.requests.usage;
  const s=normalizeClaudeBundle(b,{now:NOW});
  assert.equal(s.errorCode,'CHALLENGE');assert.match(s.error,/验证/);
  assert.equal(classifyRequest(fx.request('x',503,fx.challengeHtml,{contentType:'text/html'})).kind,'challenge');
});

test('rate limit on usage keeps the plan and honours Retry-After',()=>{
  const b=fx.bundle();b.requests.usage=fx.request('u',429,{type:'error'},{retryAfter:'120'});
  const s=normalizeClaudeBundle(b,{now:NOW});
  assert.equal(s.errorCode,'RATE_LIMITED');assert.equal(s.planLabel,'Max 20x');assert.equal(s.retryAfterMs,120000);assert.equal(s.ok,false);
});

test('network failure and helper failures map to friendly codes',()=>{
  const b=fx.bundle();b.requests.organizations=fx.request('o',0,'',{error:'ConnectionAborted'});
  assert.equal(normalizeClaudeBundle(b,{now:NOW}).errorCode,'NETWORK');
  const t=fx.bundle();t.requests.organizations=fx.request('o',0,'',{error:'TIMEOUT'});
  assert.equal(normalizeClaudeBundle(t,{now:NOW}).errorCode,'TIMEOUT');
  assert.equal(normalizeClaudeBundle({v:1,ok:false,errorCode:'NO_WEBVIEW2'}).errorCode,'NO_WEBVIEW2');
  assert.equal(normalizeClaudeBundle({v:1,ok:false,errorCode:'SOMETHING_NEW'}).errorCode,'BROWSER_ERROR');
  assert.equal(normalizeClaudeBundle(null).errorCode,'BROWSER_ERROR');
});

test('body read from the rendered page (json-string encoding) is decoded',()=>{
  const b=fx.bundle();
  b.requests.usage=fx.request(b.requests.usage.url,200,fx.usageNew,{encoding:'json-string'});
  assert.equal(normalizeClaudeBundle(b,{now:NOW}).windows[0].used,12);
});

test('Team and Enterprise plans, Pro, Max 5x and unknown future plans',()=>{
  assert.equal(identifyClaudePlan({capabilities:['chat','raven'],raven_type:'team'}).planLabel,'Team');
  assert.equal(identifyClaudePlan({capabilities:['chat'],raven_type:'enterprise'}).planLabel,'Enterprise');
  assert.equal(identifyClaudePlan({capabilities:['chat','claude_pro'],rate_limit_tier:'default_claude_ai'}).planLabel,'Pro');
  assert.equal(identifyClaudePlan({capabilities:['chat','claude_max'],rate_limit_tier:'default_claude_max_5x'}).planLabel,'Max 5x');
  const future=identifyClaudePlan({capabilities:['claude_ultra']});
  assert.equal(future.plan,'ultra');assert.equal(future.planKnown,false);assert.equal(future.planLabel,'Ultra');
  assert.equal(identifyClaudePlan(null).planLabel,'未知套餐');
});

test('plan falls back to the bootstrap membership when the list lacks capabilities',()=>{
  const bare=[{uuid:fx.ORG_MAX,name:'Me'}];
  const b=fx.bundle({orgList:bare});
  b.requests.bootstrap=fx.request('b',200,{account:{memberships:[{organization:{uuid:fx.ORG_MAX,capabilities:['chat','claude_pro'],rate_limit_tier:'default_claude_ai'}}]}});
  assert.equal(normalizeClaudeBundle(b,{now:NOW}).planLabel,'Pro');
});

test('organization choice: saved preference, then last active, then a chat org',()=>{
  assert.equal(chooseOrganization(fx.orgs,{preferred:fx.ORG_TEAM}).uuid,fx.ORG_TEAM);
  assert.equal(chooseOrganization(fx.orgs,{preferred:'nope',lastActive:fx.ORG_TEAM}).uuid,fx.ORG_TEAM);
  assert.equal(chooseOrganization([{uuid:'a-1',capabilities:[]},{uuid:'b-2',capabilities:['chat']}]).uuid,'b-2');
});

test('reset times: microseconds, numbers and junk',()=>{
  assert.equal(resetSeconds('2026-10-26T09:00:00.999999+00:00'),Date.parse('2026-10-26T09:00:00.999Z')/1000|0);
  assert.equal(resetSeconds(1793000000),1793000000);
  assert.equal(resetSeconds(1793000000000),1793000000);
  assert.equal(resetSeconds('soon'),null);assert.equal(resetSeconds(null),null);
});

test('usage values above 100% are clamped and malformed windows flag the read',()=>{
  const r=normalizeUsage({five_hour:{utilization:131,resets_at:null},seven_day:{utilization:'x'}});
  assert.equal(r.windows[0].used,100);assert.equal(r.windows[0].remaining,0);assert.equal(r.invalid,true);
});

test('runBrowserFetch passes the expected helper arguments and reads its file',async()=>{
  const dir=fs.mkdtempSync(path.join(os.tmpdir(),'cn-fetch-'));
  const config={appDir:'C:\\App',dataDir:dir,configPath:'C:\\App\\installation.json'};
  let seen;
  const spawnProcess=(file,args)=>{
    seen={file,args};
    const child=new EventEmitter();child.stderr=new EventEmitter();
    const out=args[args.indexOf('-OutFile')+1];
    setTimeout(()=>{fs.writeFileSync(out,JSON.stringify(fx.bundle()));child.emit('close',0);},5);
    return child;
  };
  const snapshot=await readUsage(config,{spawnProcess,preferredOrg:fx.ORG_MAX,includeCredits:true,now:()=>NOW});
  assert.equal(snapshot.ok,true);assert.equal(snapshot.planLabel,'Max 20x');
  assert.ok(seen.args.includes('-STA'));assert.deepEqual(seen.args.slice(seen.args.indexOf('-Mode'),seen.args.indexOf('-Mode')+2),['-Mode','fetch']);
  assert.ok(seen.args.includes('-IncludeCredits'));assert.ok(!seen.args.includes('-AllowBootstrap'));
  assert.equal(seen.args[seen.args.indexOf('-PreferredOrg')+1],fx.ORG_MAX);
  assert.equal(fs.readdirSync(path.join(dir,'fetch')).length,0,'temporary result removed');
  assert.deepEqual(browserArguments(config,{preferredOrg:'bad id; rm'}).includes('-PreferredOrg'),false);
});

test('runBrowserFetch reports a helper that exits without output, and timeouts',async()=>{
  const dir=fs.mkdtempSync(path.join(os.tmpdir(),'cn-fetch-'));
  const config={appDir:'C:\\App',dataDir:dir};
  const silent=()=>{const c=new EventEmitter();c.stderr=new EventEmitter();setTimeout(()=>{c.stderr.emit('data',Buffer.from('boom'));c.emit('close',1);},5);return c;};
  const r=await runBrowserFetch(config,{spawnProcess:silent});
  assert.equal(r.errorCode,'BROWSER_ERROR');assert.match(r.error,/boom/);
  const hang=()=>{const c=new EventEmitter();c.stderr=new EventEmitter();c.kill=()=>{c.killed=true;};return c;};
  const t=await runBrowserFetch(config,{spawnProcess:hang,timeoutMs:30});
  assert.equal(t.errorCode,'TIMEOUT');
});

test('organization list is cached: later reads ask claude.ai only for the usage',async()=>{
  const {newOrganizationCache,ORG_CACHE_MS}=await import('../runtime/claude-usage.mjs');
  const dir=fs.mkdtempSync(path.join(os.tmpdir(),'cn-cache-'));
  const config={appDir:'C:\\App',dataDir:dir};
  const calls=[];let usageStatus=200;
  const spawnProcess=(file,args)=>{
    calls.push(args);
    const child=new EventEmitter();child.stderr=new EventEmitter();
    const out=args[args.indexOf('-OutFile')+1];
    const b=fx.bundle();
    if(args.includes('-SkipOrganizations')){
      delete b.requests.organizations;
      b.selectedOrg=args[args.indexOf('-OrgId')+1];
      if(usageStatus!==200)b.requests.usage=fx.request('u',usageStatus,{type:'error',error:{type:'permission_error'}});
    }
    setTimeout(()=>{fs.writeFileSync(out,JSON.stringify(b));child.emit('close',0);},5);
    return child;
  };
  let clock=NOW;const now=()=>clock;
  const cache=newOrganizationCache();
  const first=await readUsage(config,{spawnProcess,now,orgCache:cache});
  assert.equal(first.ok,true);assert.ok(!calls[0].includes('-SkipOrganizations'));
  assert.equal(cache.selectedOrg,fx.ORG_MAX);
  clock+=5*60000;
  const second=await readUsage(config,{spawnProcess,now,orgCache:cache});
  assert.ok(calls[1].includes('-SkipOrganizations'));assert.equal(calls[1][calls[1].indexOf('-OrgId')+1],fx.ORG_MAX);
  assert.equal(second.ok,true);assert.equal(second.planLabel,'Max 20x');assert.equal(second.org.count,2);assert.equal(second.windows[0].used,37);
  // Picking another organization reads the list again.
  await readUsage(config,{spawnProcess,now,orgCache:cache,preferredOrg:fx.ORG_TEAM});
  assert.ok(!calls[2].includes('-SkipOrganizations'));
  // A refused usage read for the remembered organization falls back to a full read at once.
  Object.assign(cache,{request:fx.bundle().requests.organizations,selectedOrg:fx.ORG_MAX,at:clock});
  usageStatus=403;
  const recovered=await readUsage(config,{spawnProcess,now,orgCache:cache});
  assert.equal(calls.length,5);assert.ok(calls[3].includes('-SkipOrganizations'));assert.ok(!calls[4].includes('-SkipOrganizations'));
  assert.equal(recovered.ok,true);
  // The cache expires after 30 minutes.
  usageStatus=200;clock+=ORG_CACHE_MS+1000;
  await readUsage(config,{spawnProcess,now,orgCache:cache});
  assert.ok(!calls[5].includes('-SkipOrganizations'));
});
