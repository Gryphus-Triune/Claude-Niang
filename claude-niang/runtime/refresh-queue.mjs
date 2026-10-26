import fs from 'node:fs';
import {isTransientError} from './claude-usage.mjs';

// Only explicit requests made during a query schedule another query. A failed
// query or write never retries itself; the next request/heartbeat may retry it.
export function createRefreshQueue(run,{now=Date.now,onError=()=>{}}={}) {
  let busy=false,pending=false,lastRefresh=0,inFlight=null;
  async function drain() {
    busy=true;
    try {
      do {
        pending=false;lastRefresh=now();
        try{await run();}
        catch(error){try{onError(error);}catch{}}
      } while(pending);
    } finally {busy=false;}
  }
  return {
    request(){pending=true;if(!busy)inFlight=drain();return inFlight;},
    get busy(){return busy;},
    get pending(){return pending;},
    get lastRefresh(){return lastRefresh;}
  };
}

// Keep the last good quota when a read fails for a passing reason (network,
// rate limit, verification, signed out). A different organization, an empty
// plan answer or an explicit sign-out replaces it.
export function mergeUsageSnapshot(previous,next,now=Date.now()) {
  if(next.queryOk && previous?.ok && next.accountKey && next.accountKey===previous.accountKey && next.observedAt<previous.observedAt)return previous;
  const keep=previous?.ok && !next.ok && !next.clearPrevious && (
    (next.accountKey && next.accountKey===previous.accountKey) ||
    (!next.accountKey && (isTransientError(next.errorCode) || next.errorCode==='NOT_LOGGED_IN'))
  );
  if(keep){
    const merged={...previous,queryOk:false,error:next.error,errorCode:next.errorCode??null,checkedAt:now};
    if(next.errorCode==='NOT_LOGGED_IN')merged.loggedIn=false;
    return merged;
  }
  return {...next,checkedAt:now};
}

// Three failed reads in a row pause reading for a short time (30 seconds in the
// worker). The count starts again after the pause, after a successful read, or
// when reset for a new login or organization. Nothing is retried automatically.
export function createFailurePause({limit=3,pauseMs=30000,now=Date.now}={}) {
  let failures=0,until=0;
  return {
    record(ok){if(ok){failures=0;return false;}if(++failures<limit)return false;failures=0;until=now()+pauseMs;return true;},
    reset(){failures=0;until=0;},
    remaining(){return Math.max(0,until-now());},
    get failures(){return failures;}
  };
}

// The flag's contents are a request token, not just a filesystem timestamp.
// Different requests sharing the same mtime still cause a refresh.
export function readRefreshRequest(file) {
  try {
    const stat=fs.statSync(file,{bigint:true});
    if(stat.size<=0n || stat.size>4096n)return null;
    return stat.mtimeNs.toString()+':'+fs.readFileSync(file,'utf8');
  } catch {return null;}
}
