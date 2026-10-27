import test from 'node:test';
import assert from 'node:assert/strict';
import {advanceLedger,localDay} from '../runtime/daily.mjs';
import {mergeUsageSnapshot} from '../runtime/refresh-queue.mjs';
import {formatMoney} from '../runtime/shared.mjs';

const at=(day,hour)=>new Date(2026,9,day,hour,0,0).getTime();
const snap=(used,resetsAt=1761868800,extra={})=>({ok:true,queryOk:true,accountKey:'acct-a',windows:[{kind:'session',used:10},{kind:'weekly',used,resetsAt}],...extra});

test('daily ledger counts weekly percentage points used since the first read of the day',()=>{
  let ledger=advanceLedger(null,snap(20),at(25,9));
  assert.equal(ledger.day,localDay(at(25,9)));
  assert.equal(ledger.consumed,0);
  ledger=advanceLedger(ledger,snap(23.5),at(25,11));
  ledger=advanceLedger(ledger,snap(23.4),at(25,12)); // server rounding, not a reset
  ledger=advanceLedger(ledger,snap(26),at(25,15));
  assert.equal(ledger.consumed,6);
  assert.equal(ledger.since,at(25,9));
});

test('daily ledger continues across a weekly reset and starts over on a new day or account',()=>{
  let ledger=advanceLedger(null,snap(95,1761868800),at(25,9));
  ledger=advanceLedger(ledger,snap(98,1761868800),at(25,10));
  ledger=advanceLedger(ledger,snap(4,1761868800+7*86400),at(25,16)); // new week
  assert.equal(ledger.consumed,7);
  const nextDay=advanceLedger(ledger,snap(9,1761868800+7*86400),at(26,8));
  assert.equal(nextDay.consumed,0);
  assert.equal(nextDay.day,localDay(at(26,8)));
  const otherAccount=advanceLedger(ledger,snap(50,1761868800,{accountKey:'acct-b'}),at(25,17));
  assert.equal(otherAccount.consumed,0);
  assert.equal(otherAccount.accountKey,'acct-b');
});

test('daily ledger ignores failed reads and snapshots without a weekly window',()=>{
  const ledger=advanceLedger(null,snap(30),at(25,9));
  assert.equal(advanceLedger(ledger,{ok:false,windows:[]},at(25,10)),ledger);
  assert.equal(advanceLedger(ledger,{ok:true,accountKey:'acct-b',windows:[{kind:'session',used:40}]},at(25,10)),null);
  assert.equal(advanceLedger(null,{ok:false},at(25,10)),null);
});

test('merge keeps the last good quota through passing failures of the same account',()=>{
  const good={...snap(40),observedAt:1000,error:null,errorCode:null};
  const network={ok:false,queryOk:false,accountKey:null,errorCode:'NETWORK',error:'连不上',windows:[],clearPrevious:false};
  const kept=mergeUsageSnapshot(good,network,5000);
  assert.equal(kept.ok,true);
  assert.equal(kept.queryOk,false);
  assert.equal(kept.errorCode,'NETWORK');
  assert.deepEqual(kept.windows,good.windows);
  const signedOut=mergeUsageSnapshot(good,{...network,errorCode:'NOT_LOGGED_IN',error:'未登录'},6000);
  assert.equal(signedOut.ok,true);
  assert.equal(signedOut.loggedIn,false);
  const rateSameAccount=mergeUsageSnapshot(good,{...network,accountKey:'acct-a',errorCode:'RATE_LIMITED'},7000);
  assert.deepEqual(rateSameAccount.windows,good.windows);
});

test('merge replaces the quota for another organization, an empty plan answer or a newer read',()=>{
  const good={...snap(40),observedAt:1000};
  const other={...snap(10,undefined,{accountKey:'acct-b'}),observedAt:2000};
  assert.equal(mergeUsageSnapshot(good,other,3000).accountKey,'acct-b');
  const otherFailure={ok:false,queryOk:false,accountKey:'acct-b',errorCode:'NETWORK',windows:[],clearPrevious:false};
  assert.equal(mergeUsageSnapshot(good,otherFailure,3000).ok,false);
  const free={ok:false,queryOk:true,accountKey:'acct-a',errorCode:'NO_WINDOWS',windows:[],clearPrevious:true,observedAt:2000};
  assert.equal(mergeUsageSnapshot(good,free,3000).ok,false);
  const invalid={ok:false,queryOk:false,accountKey:null,errorCode:'INVALID',windows:[],clearPrevious:false};
  const preserved=mergeUsageSnapshot(good,invalid,3000);
  assert.equal(preserved.ok,true,'unrecognized response retains the last successful quota');
  assert.equal(preserved.queryOk,false);
  const stale={...snap(35),observedAt:500};
  assert.equal(mergeUsageSnapshot(good,stale,3000),good);
});


test('money is shown in major units with the currency symbol',()=>{
  assert.equal(formatMoney(12345,'USD'),'$123.45');
  assert.equal(formatMoney(500,'EUR'),'€5.00');
  assert.equal(formatMoney(null,'USD'),'—');
  // Same grouping as the widget's own money text.
  assert.equal(formatMoney(123456789,'USD'),'$1,234,567.89');assert.equal(formatMoney(150000,'JPY'),'¥150,000');
});
