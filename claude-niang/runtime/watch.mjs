import fs from 'node:fs';
import path from 'node:path';
import {readUsage,atomicJson,newOrganizationCache,failure,accountFingerprint} from './claude-usage.mjs';
import {createRefreshQueue,mergeUsageSnapshot,readRefreshRequest,createFailurePause} from './refresh-queue.mjs';
import {acquireWorkerLock,processAlive} from './worker-state.mjs';
import {readJson} from './shared.mjs';
import {readPendingRequests,completeRequests,cleanRefreshResults} from './refresh-client.mjs';
import {createPipeRefreshHandler} from './worker-ipc.mjs';
import {updateDailyLedger} from './daily.mjs';
import {pluginVersion} from './metadata.mjs';
import {writeLog} from './log.mjs';

// The timer manages local IPC/lifecycle only. Network reads require a click,
// organization selection, or an explicit CLI/MCP request, never visibility.
const configPath=process.argv[2],loaded=readJson(configPath);
if(!loaded?.dataDir || !loaded?.appDir)throw new Error('Invalid widget installation configuration');
const config={...loaded,configPath:path.resolve(configPath)},parentPid=Number(process.argv[3]??0);
if(!Number.isSafeInteger(parentPid) || parentPid<0)throw new Error('Invalid parent process id');
const MIN_EXPLICIT_GAP=15000,CREDITS_EVERY=30*60000,BOOTSTRAP_EVERY=12*3600000;
// worker-status.json is the liveness signal (healthyWorker, Ensure-QuotaWorker).
// Rewrite it when its content changes and otherwise every 2 seconds, not on
// every 1 s tick. Its seq grows with every write, so readers can see
// progress without comparing clocks across processes; the interval itself uses
// the monotonic clock, so a system time adjustment cannot stall or rush it.
const HEALTH_KEEPALIVE_MS=2000;
// After three failed reads in a row, requests get the saved snapshot with a note
// for 30 seconds instead of a new read.
const FAILURE_LIMIT=3,failurePause=createFailurePause({limit:FAILURE_LIMIT,pauseMs:Number.isFinite(config.failurePauseMs) && config.failurePauseMs>=0?config.failurePauseMs:30000});
let failureError='';
const file=name=>path.join(config.dataDir,name);
const statusFile=file('status.json'),healthFile=file('worker-status.json'),sessionFile=file('session-reset.flag');
const requestFile=file('refresh.flag'),consumedFile=file('refresh-consumed.json'),backoffFile=file('quota-backoff.json');
// The widget replaces settings.json atomically, but a read can still land in the
// moment between the two renames. Treat an unreadable file as "unchanged" so that
// moment never looks like switching to another organization.
const preferred=(unchanged=null)=>{
  const saved=readJson(file('settings.json'));if(!saved || typeof saved!=='object')return unchanged;
  const id=saved.preferredOrg;return typeof id==='string' && /^[0-9a-f-]{8,64}$/i.test(id)?id.toLowerCase():null;
};
let preference=preferred(),sessionToken=readRefreshRequest(sessionFile),requestToken=readJson(consumedFile)?.token??null;
let status=null,refresh,heartbeat,explicitWanted=false,generation=0,lastActivity=Date.now();
let lastAttempt=0,lastAttemptGeneration=-1,lastCreditsAt=0,lastBootstrapAt=0;
let blockedUntil=Math.max(0,Number(readJson(backoffFile)?.until)||0);
const orgCache=newOrganizationCache(),ipc=createPipeRefreshHandler(()=>{explicitWanted=true;setImmediate(tick);});
const lock=await acquireWorkerLock(config.dataDir,parentPid,{onConnection:ipc.onConnection});
if(!lock)process.exit(0);
const initialStop=readRefreshRequest(file('stop.flag'));
const log=message=>writeLog(config.dataDir,'worker',message);
let lastHealth='',lastHealthAt=-Infinity,healthSeq=0;
log('后台进程启动（'+pluginVersion+'）');

// One log line per read: outcome and duration, never organization ids.
function readSummary(snapshot,ms){
  const seconds=(ms/1000).toFixed(1)+' 秒';
  if(snapshot.queryOk)return '读取完成：'+(snapshot.planLabel??'未知套餐')+'，'+(snapshot.windows?.length??0)+' 个额度窗口，用时 '+seconds;
  return '读取失败：'+(snapshot.errorCode??'UNKNOWN')+(snapshot.detail?'（'+snapshot.detail+'）':'')+'，用时 '+seconds;
}

function save(data){
  const cleaned={...data,refreshMode:'manual',sessionEpoch:sessionToken};
  for(const key of ['pollMinutes','peakTag','peakHours'])delete cleaned[key];
  atomicJson(statusFile,cleaned);status=cleaned;
}
function pending(message='点角色或 ↻ 手动读取 Claude 额度',code='MANUAL'){
  const orgs=Array.isArray(status?.orgs)?status.orgs:[],row=orgs.find(org=>org.uuid===preference);
  return {ok:false,queryOk:false,error:message,errorCode:code,windows:[],checkedAt:Date.now(),selectedOrg:preference,accountKey:accountFingerprint(preference),orgs,
    ...(row?{org:{name:row.name,count:orgs.length},planLabel:row.planLabel}:{})};
}
function syncContext(){
  const nextSession=readRefreshRequest(sessionFile),nextPreference=preferred(preference);
  if(nextSession===sessionToken && nextPreference===preference)return false;
  const changedSession=nextSession!==sessionToken;
  sessionToken=nextSession;preference=nextPreference;generation++;failurePause.reset();
  Object.assign(orgCache,newOrganizationCache());lastCreditsAt=0;lastBootstrapAt=0;
  if(changedSession){
    status=null;try{fs.unlinkSync(file('daily.json'));}catch{}
    // A rate limit belonged to the previous sign-in; a new sign-in or sign-out
    // starts without it. Switching organizations keeps it (same account).
    blockedUntil=0;try{fs.unlinkSync(backoffFile);}catch{}
    const signedOut=readJson(sessionFile)?.state==='signed-out';
    log(signedOut?'已退出登录':'登录状态已更新');
    save({...pending(signedOut?'已退出登录，请先登录 Claude 账号':'登录状态已更新，点角色或 ↻ 手动读取额度',signedOut?'NOT_LOGGED_IN':'MANUAL'),loggedIn:!signedOut});
  }else{log('已切换组织');save(pending('已切换组织，正在等待手动读取结果','SWITCHING_ORG'));}
  return true;
}
function health(){
  const value={...lock.owner,version:pluginVersion,busy:refresh.busy,lastRefresh:refresh.lastRefresh,refreshMode:'manual',blockedUntil};
  const key=JSON.stringify(value),tick=performance.now();
  if(key===lastHealth && tick-lastHealthAt<HEALTH_KEEPALIVE_MS)return;
  atomicJson(healthFile,{...value,at:Date.now(),seq:++healthSeq});lastHealth=key;lastHealthAt=tick;
}
function complete(batch,pipeBatch,value){ipc.complete(pipeBatch,value);completeRequests(config.dataDir,batch,value);}
function consumeFlag(){
  const token=readRefreshRequest(requestFile);
  if(token===null || token===requestToken)return false;
  requestToken=token;atomicJson(consumedFile,{token});
  const request=readJson(requestFile),age=Date.now()-request?.at;
  // Persist consumption so restarting the worker cannot replay an old click.
  return !!(request && typeof request.id==='string' && Number.isFinite(request.at) && age>=0 && age<120000);
}
function exit(){
  clearInterval(heartbeat);
  log('后台进程退出');
  try{if(readJson(healthFile)?.token===lock.owner.token)fs.unlinkSync(healthFile);}catch{}
  try{lock.release();}catch{}
}
process.on('exit',exit);process.on('SIGTERM',()=>process.exit(0));process.on('SIGINT',()=>process.exit(0));
if(parentPid && !processAlive(parentPid))process.exit(0);

refresh=createRefreshQueue(async()=>{
  const batch=readPendingRequests(config.dataDir),pipeBatch=ipc.takeBatch(),startedGeneration=generation,startedPreference=preference;
  const now=Date.now();lastAttempt=now;lastAttemptGeneration=generation;lastActivity=now;
  try{
    const sameOrg=!startedPreference || status?.selectedOrg===startedPreference;
    const includeCredits=!sameOrg || now-lastCreditsAt>=CREDITS_EVERY;
    const allowBootstrap=now-lastBootstrapAt>=BOOTSTRAP_EVERY;
    const next=await readUsage(config,{preferredOrg:startedPreference,includeCredits,allowBootstrap,orgCache});
    log(readSummary(next,Date.now()-now));
    syncContext();
    if(startedGeneration!==generation){Object.assign(orgCache,newOrganizationCache());complete(batch,pipeBatch,status);return;}
    if(includeCredits && next.queryOk)lastCreditsAt=now;
    if(allowBootstrap && next.planKnown)lastBootstrapAt=now;
    if(next.ok && !next.credits && status?.credits && status.accountKey===next.accountKey && !includeCredits)next.credits=status.credits;
    if(next.ok && next.queryOk){const today=updateDailyLedger(config.dataDir,next);if(today)next.today=today;}
    save(mergeUsageSnapshot(status,next));
    if(next.queryOk!==true)failureError=String(status?.error??'');
    failurePause.record(next.queryOk===true);
    if(next.errorCode==='RATE_LIMITED'){
      blockedUntil=Date.now()+(next.retryAfterMs??10*60000);atomicJson(backoffFile,{until:blockedUntil});
      log('claude.ai 限流，'+Math.ceil((blockedUntil-Date.now())/60000)+' 分钟内不再读取');
    }
    // Same-context requests arriving during this read share its result.
    consumeFlag();explicitWanted=false;
    const more=readPendingRequests(config.dataDir).filter(item=>!batch.some(old=>old.id===item.id));
    complete([...batch,...more],[...pipeBatch,...ipc.takeBatch()],status);
  }catch(error){
    const value={...pending('读取或保存额度失败，请手动重试','IO'),detail:typeof error?.code==='string'?error.code:'IO'};
    try{save(value);}catch{}
    failureError=value.error;failurePause.record(false);
    try{complete(batch,pipeBatch,value);}catch{ipc.fail(pipeBatch);}
    log('读取或保存额度失败：'+value.detail+' '+String(error?.message??error));
  }finally{lastActivity=Date.now();}
});
const previous=readJson(statusFile);
if(previous?.ok && previous.sessionEpoch===sessionToken && (!preference || previous.selectedOrg===preference)){
  save({...previous,restored:true,queryOk:false,error:'上次保存的额度，点 ↻ 手动刷新',errorCode:null,checkedAt:Date.now()});
}else{
  const signedOut=readJson(sessionFile)?.state==='signed-out';
  save({...pending(signedOut?'已退出登录，请先登录 Claude 账号':undefined,signedOut?'NOT_LOGGED_IN':'MANUAL'),...(signedOut?{loggedIn:false}:{})});
}
health();
// The widget and the extension ask over the pipe and are answered at once (see
// the handler above); this tick handles everything else: the refresh.flag
// fallback, sign-in and organization changes, the stop flag and liveness.
function tick(){
  if(!refresh)return;
  try{
    const stop=readRefreshRequest(file('stop.flag'));
    if((parentPid && (!processAlive(parentPid) || stop!==null)) || (stop!==null && stop!==initialStop))process.exit(0);
    const now=Date.now();syncContext();
    const presence=readJson(file('presence.json'));
    const active=presence?.visible && now-presence.at>=0 && now-presence.at<5000 && processAlive(presence.pid);
    if(active)lastActivity=now;
    if(consumeFlag())explicitWanted=true;
    const batch=readPendingRequests(config.dataDir,now);if(batch.length)explicitWanted=true;
    if(explicitWanted && !refresh.busy){
      explicitWanted=false;
      if(now<blockedUntil){
        const retryAfterMs=blockedUntil-now;
        const message='查询已限流，请 '+Math.ceil(retryAfterMs/60000)+' 分钟后手动刷新（不会自动重试）';
        save(mergeUsageSnapshot(status,{...pending(message,'RATE_LIMITED'),...failure('RATE_LIMITED',{retryAfterMs}),accountKey:accountFingerprint(preference),selectedOrg:preference,orgs:status?.orgs??[],error:message}));
        complete(batch,ipc.takeBatch(),status);
      }else if(failurePause.remaining()>0){
        const note='（已连续失败 '+FAILURE_LIMIT+' 次，请 '+Math.ceil(failurePause.remaining()/1000)+' 秒后再刷新）';
        if(status)save({...status,error:(failureError||'读取失败')+note});
        complete(batch,ipc.takeBatch(),status);
      }else if(lastAttemptGeneration===generation && now-lastAttempt<MIN_EXPLICIT_GAP && status?.queryOk)complete(batch,ipc.takeBatch(),status);
      else void refresh.request();
    }
    if(!parentPid && !active && !refresh.busy && batch.length===0 && ipc.pendingCount===0 && now-lastActivity>=30000)process.exit(0);
    cleanRefreshResults(config.dataDir,now);health();
  }catch(error){log('本地状态文件读写失败：'+(typeof error?.code==='string'?error.code:'IO')+' '+String(error?.message??error));}
}
heartbeat=setInterval(tick,1000);
