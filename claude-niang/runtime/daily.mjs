import path from 'node:path';
import {atomicJson} from './claude-usage.mjs';
import {readJson} from './worker-state.mjs';

export function localDay(ms){
  const d=new Date(ms);
  return d.getFullYear()+'-'+String(d.getMonth()+1).padStart(2,'0')+'-'+String(d.getDate()).padStart(2,'0');
}
// Observed percentage-point changes, not exact message or token consumption.
export function advanceLedger(previous,snapshot,now=Date.now()){
  if(!snapshot?.ok)return previous??null;
  const weekly=snapshot.windows?.find?.(w=>w?.kind==='weekly');
  if(!snapshot.accountKey || !weekly || !Number.isFinite(weekly.used))return null;
  const day=localDay(now);
  const fresh=()=>({version:1,day,accountKey:snapshot.accountKey,since:now,consumed:0,last:weekly.used,resetsAt:weekly.resetsAt??null,updatedAt:now});
  if(!previous || previous.version!==1 || previous.day!==day || previous.accountKey!==snapshot.accountKey || !Number.isFinite(previous.consumed) || !Number.isFinite(previous.last))return fresh();
  const ledger={...previous};
  const resetMoved=Number.isFinite(ledger.resetsAt) && Number.isFinite(weekly.resetsAt) && Math.abs(weekly.resetsAt-ledger.resetsAt)>3600;
  if(resetMoved){ledger.consumed+=weekly.used;ledger.last=weekly.used;}
  else if(weekly.used>=ledger.last){ledger.consumed+=weekly.used-ledger.last;ledger.last=weekly.used;}
  else if(ledger.last-weekly.used>2)ledger.last=weekly.used;
  ledger.consumed=Math.round(Math.min(1000,Math.max(0,ledger.consumed))*10)/10;
  ledger.resetsAt=weekly.resetsAt??ledger.resetsAt;ledger.updatedAt=now;
  return ledger;
}
export function updateDailyLedger(dataDir,snapshot,now=Date.now()){
  const file=path.join(dataDir,'daily.json'),saved=readJson(file);
  const accounts=saved?.version===2 && saved.accounts && typeof saved.accounts==='object'?{...saved.accounts}:{};
  if(saved?.version===1 && saved.accountKey)accounts[saved.accountKey]=saved;
  const key=snapshot?.accountKey;if(!key)return null;
  const next=advanceLedger(accounts[key],snapshot,now);
  if(!next){delete accounts[key];try{atomicJson(file,{version:2,accounts});}catch{};return null;}
  accounts[key]=next;
  const recent=Object.fromEntries(Object.entries(accounts).sort((a,b)=>(b[1]?.updatedAt??0)-(a[1]?.updatedAt??0)).slice(0,50));
  try{atomicJson(file,{version:2,accounts:recent});}catch{}
  return {day:next.day,accountKey:key,weeklyUsed:next.consumed,since:next.since,estimated:true};
}
