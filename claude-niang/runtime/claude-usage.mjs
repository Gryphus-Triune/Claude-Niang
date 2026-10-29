import fs from 'node:fs';
import path from 'node:path';
import {spawn} from 'node:child_process';
import {createHash,randomUUID} from 'node:crypto';
import {identifyClaudePlan,modelLabel,quotaWindowLabel} from './plan.mjs';

// claude.ai is read through the widget's own signed-in WebView2 profile
// (runtime/claude-browser.ps1). This module only turns that raw bundle into a
// quota snapshot; it never sees or stores session cookies.

export const errorMessages={
  NOT_LOGGED_IN:'未登录 Claude：点气泡，或右键 → Claude 账号 → 登录',
  CHALLENGE:'claude.ai 需要网页验证：点气泡打开登录窗口，在里面完成验证',
  RATE_LIMITED:'查询太频繁，请稍后手动刷新',
  NETWORK:'连不上 claude.ai，请检查网络或代理',
  SERVER:'Claude 服务暂时异常，请稍后手动刷新',
  NO_WEBVIEW2:'缺少 Microsoft Edge WebView2 运行时，请先安装',
  NO_SDK:'挂件文件不完整（缺少 WebView2 组件），请重新解压安装',
  BROWSER_BUSY:'登录窗口还开着，关闭后再刷新',
  BROWSER_ERROR:'内置浏览器启动失败，稍后重试',
  TIMEOUT:'查询超时，稍后重试',
  NO_ORG:'这个账号下没有可用的 Claude 组织',
  ORG_UNAVAILABLE:'所选组织已不可用，请在设置里重新选择组织',
  USAGE_FORBIDDEN:'当前组织没有提供额度信息',
  NO_WINDOWS:'claude.ai 没有返回额度窗口（Free 套餐通常不提供）',
  INVALID:'claude.ai 返回的数据无法识别，可能接口有变化',
  NOT_WINDOWS:'只能在 Windows 上读取额度'
};
const transientCodes=new Set(['RATE_LIMITED','NETWORK','SERVER','BROWSER_BUSY','BROWSER_ERROR','TIMEOUT','CHALLENGE','INVALID']);
export const isTransientError=code=>transientCodes.has(code);

export function failure(errorCode,{plan=null,detail=null,retryAfterMs=null}={}) {
  const info=plan??identifyClaudePlan(null);
  return {ok:false,queryOk:false,source:'claude.ai',windows:[],...info,errorCode,error:errorMessages[errorCode]??errorMessages.INVALID,
    ...(detail?{detail:String(detail).slice(0,300)}:{}),...(retryAfterMs?{retryAfterMs}:{}),clearPrevious:false};
}

// --- raw request helpers ----------------------------------------------------
function requestText(request) {
  if(!request || typeof request.body!=='string')return '';
  if(request.bodyEncoding==='json-string'){
    try{const text=JSON.parse(request.body);return typeof text==='string'?text:'';}catch{return '';}
  }
  return request.body;
}

function requestJson(request) {
  const text=requestText(request).trim();
  if(!text || (text[0]!=='{' && text[0]!=='['))return undefined;
  try{return JSON.parse(text);}catch{return undefined;}
}

function retryAfterMs(request) {
  const value=typeof request?.retryAfter==='string'?request.retryAfter.trim():'';
  // Preserve server waits; only saturate values beyond JS/.NET's shared date range.
  // Leave a day of headroom for the worker to add the delay to its later clock.
  const now=Date.now(),maxWait=253402300799999-now-86400000;
  if(/^\d+$/.test(value))return Math.min(maxWait,Math.max(30000,Number(value)*1000));
  const date=Date.parse(value);
  if(Number.isFinite(date))return Math.min(maxWait,Math.max(30000,date-now));
  return null;
}

// What kind of answer a request got. Challenges are reported, never solved
// automatically: the user opens the visible login window to pass them.
export function classifyRequest(request) {
  if(!request || typeof request!=='object')return {kind:'missing'};
  const status=Number.isSafeInteger(request.status)?request.status:0;
  const type=String(request.contentType??'').toLowerCase();
  const text=requestText(request);
  const challenge=!!request.cfMitigated || (status===403 && type.includes('text/html')) || (status>=400 && /<title>\s*just a moment|cf-chl-|challenge-platform/i.test(text.slice(0,4000)));
  if(challenge)return {kind:'challenge'};
  if(!status && request.error==='TIMEOUT')return {kind:'timeout'};
  if(!status)return {kind:'network',detail:request.error||'no response'};
  if(status===429)return {kind:'rate',retryAfterMs:retryAfterMs(request)};
  const json=requestJson(request);
  if(status===401 || status===403)return {kind:'auth',json};
  if(status===404)return {kind:'missing-endpoint'};
  if(status>=500)return {kind:'server'};
  if(status>=200 && status<300 && json!==undefined)return {kind:'ok',json};
  return {kind:'invalid',detail:'HTTP '+status+' '+type};
}

const codeFor={challenge:'CHALLENGE',network:'NETWORK',timeout:'TIMEOUT',rate:'RATE_LIMITED',server:'SERVER',invalid:'INVALID','missing-endpoint':'INVALID',missing:'INVALID'};

// --- organizations ----------------------------------------------------------
export function summarizeOrganizations(list) {
  if(!Array.isArray(list))return [];
  const rows=[];
  for(const org of list){
    if(!org || typeof org!=='object' || typeof org.uuid!=='string' || !/^[0-9a-f-]{8,64}$/i.test(org.uuid))continue;
    const name=typeof org.name==='string'?org.name.replace(/[\x00-\x1f\x7f]/g,'').trim().slice(0,80):'';
    rows.push({uuid:org.uuid,name:name||'未命名组织',...identifyClaudePlan(org)});
  }
  return rows;
}

// Same order as claude-browser.ps1: saved choice, the web app's last active
// organization, then the first organization that can chat.
export function chooseOrganization(list,{preferred=null,lastActive=null}={}) {
  if(!Array.isArray(list) || list.length===0)return null;
  const byId=id=>typeof id==='string' && id?list.find(org=>org?.uuid===id):null;
  return byId(preferred)??byId(lastActive)??list.find(org=>Array.isArray(org?.capabilities) && org.capabilities.some(c=>/^(chat|claude_)/.test(String(c))))??list[0];
}

// --- usage ------------------------------------------------------------------
function percent(value) {
  const number=typeof value==='string' && value.trim()!==''?Number(value):value;
  if(typeof number!=='number' || !Number.isFinite(number) || number<0)return null;
  return Math.min(100,number);
}

// claude.ai returns ISO strings, sometimes with microseconds; keep seconds.
export function resetSeconds(value) {
  if(typeof value==='number' && Number.isFinite(value) && value>0){
    const seconds=value>1e12?Math.floor(value/1000):Math.floor(value);
    return seconds<=253402271999?seconds:null;
  }
  if(typeof value!=='string' || !value.trim())return null;
  const fixed=value.trim().replace(/(\.\d{3})\d+/,'$1');
  const ms=Date.parse(fixed);
  return Number.isFinite(ms) && ms>0 && ms<=253402271999000?Math.floor(ms/1000):null;
}

function timedWindow(kind,used,resets,model=null) {
  const window={kind,minutes:kind==='session'?300:10080,used:Math.round(used*10)/10,remaining:Math.round((100-used)*10)/10,resetsAt:resets};
  if(model)window.model=model;
  window.label=quotaWindowLabel(window);
  window.key=kind+(model?':'+model.toLowerCase():'');
  return window;
}

function minor(value) {
  if(typeof value==='string' && /^-?\d+(?:\.\d+)?$/.test(value.trim()))value=Number(value);
  return typeof value==='number' && Number.isFinite(value)?value:null;
}

function currencyOf(...values) {
  for(const value of values){if(typeof value==='string' && /^[A-Za-z]{3}$/.test(value.trim()))return value.trim().toUpperCase();}
  return 'USD';
}

export function normalizeUsage(usage) {
  if(!usage || typeof usage!=='object' || Array.isArray(usage))return {windows:[],extra:null,invalid:true};
  const legacyKeys=Object.keys(usage).filter(key=>key==='five_hour' || key==='seven_day' || /^seven_day_(opus|sonnet|haiku|fable|mythos)$/.test(key));
  const recognized=legacyKeys.length>0 || Array.isArray(usage.limits) || Object.hasOwn(usage,'spend') || Object.hasOwn(usage,'extra_usage');
  const windows=[];let invalid=!recognized || (Object.hasOwn(usage,'limits') && !Array.isArray(usage.limits));
  for(const [key,enabled] of [['spend','enabled'],['extra_usage','is_enabled']]){
    const value=usage[key];
    if(value!==undefined && value!==null && (typeof value!=='object' || Array.isArray(value) || typeof value[enabled]!=='boolean'))invalid=true;
  }
  if(Array.isArray(usage.limits) && usage.limits.length>0){
    // Newer shape: [{kind:'session'|'weekly_all'|'weekly_scoped', percent, resets_at, scope:{model:{display_name}}}]
    for(const entry of usage.limits){
      if(!entry || typeof entry!=='object'){invalid=true;continue;}
      const used=percent(entry.percent??entry.utilization);
      if(used===null){invalid=true;continue;}
      const resets=resetSeconds(entry.resets_at);
      if(entry.kind==='session')windows.push(timedWindow('session',used,resets));
      else if(entry.kind==='weekly_all')windows.push(timedWindow('weekly',used,resets));
      else if(entry.kind==='weekly_scoped'){
        const model=modelLabel(entry.scope?.model?.display_name??entry.scope?.model?.name??entry.scope?.model_family);
        if(model)windows.push(timedWindow('weekly-model',used,resets,model));else invalid=true;
      }else invalid=true;
    }
  }else{
    // Older top-level shape: five_hour / seven_day / seven_day_<model> {utilization, resets_at}
    const add=(kind,raw,model=null)=>{
      if(raw===null || raw===undefined)return;
      if(typeof raw!=='object' || Array.isArray(raw)){invalid=true;return;}
      const used=percent(raw.utilization??raw.percent);
      if(used===null){if(raw.utilization!==null && raw.percent!==null)invalid=true;return;}
      windows.push(timedWindow(kind,used,resetSeconds(raw.resets_at),model));
    };
    add('session',usage.five_hour);
    add('weekly',usage.seven_day);
    for(const [key,value] of Object.entries(usage)){
      const match=/^seven_day_(opus|sonnet|haiku|fable|mythos)$/.exec(key);
      if(match)add('weekly-model',value,modelLabel(match[1]));
    }
  }
  const seen=new Set();
  const unique=windows.filter(window=>seen.has(window.key)?false:(seen.add(window.key),true));
  const order={session:0,weekly:1,'weekly-model':2};
  unique.sort((a,b)=>order[a.kind]-order[b.kind] || String(a.model??'').localeCompare(String(b.model??'')));

  // Extra usage: new `spend` object first, then the older `extra_usage`.
  let extra=null;
  const spend=usage.spend;
  if(spend && typeof spend==='object' && spend.enabled){
    const limit=minor(spend.limit?.amount_minor??spend.cap?.money?.amount_minor);
    const used=minor(spend.used?.amount_minor);
    if(used===null || used<0 || (limit!==null && limit<0))invalid=true;
    extra={enabled:true,limitMinor:limit,usedMinor:used,currency:currencyOf(spend.limit?.currency,spend.used?.currency,spend.currency)};
  }else if(usage.extra_usage && typeof usage.extra_usage==='object' && usage.extra_usage.is_enabled){
    const x=usage.extra_usage;
    const used=minor(x.used_credits),limit=minor(x.monthly_limit);
    if(used===null || used<0 || (limit!==null && limit<0))invalid=true;
    extra={enabled:true,limitMinor:limit,usedMinor:used,currency:currencyOf(x.currency)};
  }
  if(extra){
    const share=extra.limitMinor && extra.limitMinor>0?Math.min(100,Math.max(0,100*extra.usedMinor/extra.limitMinor)):null;
    extra.used=share===null?null:Math.round(share*10)/10;
    extra.remaining=share===null?null:Math.round((100-share)*10)/10;
    extra.remainingMinor=extra.limitMinor===null?null:Math.max(0,extra.limitMinor-extra.usedMinor);
  }
  return {windows:unique,extra,invalid};
}

export function accountFingerprint(orgUuid) {
  return typeof orgUuid==='string' && orgUuid?createHash('sha256').update('claude-org:'+orgUuid.toLowerCase()).digest('hex'):null;
}

// --- bundle → snapshot ------------------------------------------------------
export function normalizeClaudeBundle(bundle,{now=Date.now(),creditsRequested=false}={}) {
  if(!bundle || typeof bundle!=='object')return failure('BROWSER_ERROR');
  if(bundle.errorCode){
    const result=failure(errorMessages[bundle.errorCode]?bundle.errorCode:'BROWSER_ERROR',{detail:bundle.error});
    if(bundle.errorCode==='ORG_UNAVAILABLE')return {...result,selectedOrg:bundle.selectedOrg??null,accountKey:accountFingerprint(bundle.selectedOrg),orgs:summarizeOrganizations(requestJson(bundle.requests?.organizations)),clearPrevious:true};
    return result;
  }
  const requests=bundle.requests && typeof bundle.requests==='object'?bundle.requests:{};
  const hasSession=bundle.session?.hasSessionCookie===true;

  const orgsAnswer=classifyRequest(requests.organizations);
  if(orgsAnswer.kind==='auth')return {...failure('NOT_LOGGED_IN'),loggedIn:false};
  if(orgsAnswer.kind!=='ok'){
    if(orgsAnswer.kind==='missing' && !hasSession)return {...failure('NOT_LOGGED_IN'),loggedIn:false};
    return failure(codeFor[orgsAnswer.kind]??'INVALID',{detail:orgsAnswer.detail,retryAfterMs:orgsAnswer.retryAfterMs});
  }
  const list=Array.isArray(orgsAnswer.json)?orgsAnswer.json:[];
  const orgs=summarizeOrganizations(list);
  if(orgs.length===0)return failure('NO_ORG');
  const selected=list.find(org=>org?.uuid===bundle.selectedOrg)??chooseOrganization(list,{lastActive:bundle.session?.lastActiveOrg});
  // Plan signals may be missing from the list; the bootstrap record has them.
  let planOrg=selected;
  if(!Array.isArray(selected?.capabilities)){
    const boot=classifyRequest(requests.bootstrap);
    const member=boot.kind==='ok'?boot.json?.account?.memberships?.find?.(m=>m?.organization?.uuid===selected?.uuid)?.organization:null;
    if(member)planOrg={...member,...selected,capabilities:member.capabilities,rate_limit_tier:member.rate_limit_tier??selected.rate_limit_tier,raven_type:member.raven_type??selected.raven_type};
  }
  const plan=identifyClaudePlan(planOrg);
  const accountKey=accountFingerprint(selected?.uuid);
  const org={name:orgs.find(row=>row.uuid===selected?.uuid)?.name??'Claude',count:orgs.length};
  const base={source:'claude.ai',observedAt:now,...plan,accountKey,org,orgs:orgs.map(({uuid,name,planLabel})=>({uuid,name,planLabel})),selectedOrg:selected?.uuid??null,loggedIn:true};

  const usageAnswer=classifyRequest(requests.usage);
  if(usageAnswer.kind==='auth')return {...failure('USAGE_FORBIDDEN',{plan}),...base,ok:false,queryOk:false,windows:[],errorCode:'USAGE_FORBIDDEN',error:errorMessages.USAGE_FORBIDDEN,clearPrevious:true};
  if(usageAnswer.kind!=='ok'){
    const code=codeFor[usageAnswer.kind]??'INVALID';
    return {...failure(code,{plan,detail:usageAnswer.detail,retryAfterMs:usageAnswer.retryAfterMs}),...base,ok:false,queryOk:false,windows:[],errorCode:code,error:errorMessages[code],clearPrevious:false};
  }
  const {windows,extra,invalid}=normalizeUsage(usageAnswer.json);
  if(invalid)return {...failure('INVALID',{plan}),...base,ok:false,queryOk:false,windows:[],clearPrevious:false};
  let credits=null,creditsStatus=null;
  const creditsAnswer=classifyRequest(requests.credits);
  if(extra?.enabled){
    creditsStatus={state:'unavailable',queryOk:null};
    if(requests.credits || creditsRequested){
      const amount=creditsAnswer.kind==='ok' && creditsAnswer.json && typeof creditsAnswer.json==='object'
        ?minor(creditsAnswer.json.amount??creditsAnswer.json.balance?.amount_minor??creditsAnswer.json.amount_minor):null;
      if(amount!==null){
        credits={amountMinor:amount,currency:currencyOf(creditsAnswer.json.currency,creditsAnswer.json.balance?.currency,extra.currency),observedAt:now};
        creditsStatus={state:'fresh',queryOk:true,checkedAt:now};
      }else{
        const errorCode=creditsAnswer.kind==='auth'?'CREDITS_FORBIDDEN':codeFor[creditsAnswer.kind]??'INVALID';
        const error=errorCode==='CREDITS_FORBIDDEN'?'当前组织没有提供预付余额':errorMessages[errorCode];
        creditsStatus={state:'error',queryOk:false,checkedAt:now,errorCode,error,
          ...(creditsAnswer.retryAfterMs?{retryAfterMs:creditsAnswer.retryAfterMs}:{})};
      }
    }
  }
  const extraWindow=extra?{kind:'extra',key:'extra',label:'额外用量',minutes:null,resetsAt:null,used:extra.used,remaining:extra.remaining,usedMinor:extra.usedMinor,limitMinor:extra.limitMinor,remainingMinor:extra.remainingMinor,currency:extra.currency}:null;
  const all=extraWindow?[...windows,extraWindow]:windows;
  const result={...base,ok:all.length>0,queryOk:!invalid,windows:all,extra,credits,creditsStatus,clearPrevious:false};
  if(invalid){result.errorCode='INVALID';result.error=errorMessages.INVALID;}
  else if(all.length===0){result.errorCode='NO_WINDOWS';result.error=plan.plan==='free'?'Free 套餐暂不提供额度窗口':errorMessages.NO_WINDOWS;result.clearPrevious=true;}
  return result;
}

// --- running the WebView2 helper ---------------------------------------------
export function windowsPowerShell(env=process.env) {
  const root=env.SystemRoot??env.SYSTEMROOT??env.WINDIR??env.windir??'C:\\Windows';
  return path.join(root,'System32','WindowsPowerShell','v1.0','powershell.exe');
}

export function browserArguments(config,{mode='fetch',outFile=null,preferredOrg=null,includeCredits=false,allowBootstrap=false,orgId=null,skipOrganizations=false}={}) {
  const args=['-NoLogo','-NoProfile','-NonInteractive','-STA','-ExecutionPolicy','Bypass','-WindowStyle','Hidden','-File',path.join(config.appDir,'runtime','claude-browser.ps1'),'-Mode',mode];
  if(config.configPath)args.push('-ConfigPath',config.configPath);
  if(outFile)args.push('-OutFile',outFile);
  if(preferredOrg && /^[0-9a-f-]{8,64}$/i.test(preferredOrg))args.push('-PreferredOrg',preferredOrg);
  if(includeCredits)args.push('-IncludeCredits');
  if(allowBootstrap)args.push('-AllowBootstrap');
  if(skipOrganizations && orgId && /^[0-9a-f-]{8,64}$/i.test(orgId))args.push('-OrgId',orgId,'-SkipOrganizations');
  return args;
}

export function runBrowserFetch(config,{spawnProcess=spawn,timeoutMs=90000,preferredOrg=null,includeCredits=false,allowBootstrap=false,orgId=null,skipOrganizations=false,platform=process.platform,powershell=null}={}) {
  return new Promise(resolve=>{
    if(platform!=='win32' && spawnProcess===spawn && !powershell && !config.powershellPath){resolve({v:1,ok:false,errorCode:'NOT_WINDOWS'});return;}
    const dir=path.join(config.dataDir,'fetch');
    try{fs.mkdirSync(dir,{recursive:true});}catch{}
    const outFile=path.join(dir,randomUUID()+'.json');
    let finished=false,child=null,stderr='';
    const finish=value=>{
      if(finished)return;finished=true;clearTimeout(timer);
      try{fs.unlinkSync(outFile);}catch{}
      resolve(value);
    };
    const timer=setTimeout(()=>{try{child?.kill();}catch{};finish({v:1,ok:false,errorCode:'TIMEOUT',error:'helper timed out'});},timeoutMs);
    try{
      // powershellPath / powershellPrefixArgs let the tests stand in a fake helper.
      const prefix=Array.isArray(config.powershellPrefixArgs)?config.powershellPrefixArgs.map(String):[];
      child=spawnProcess(powershell??config.powershellPath??windowsPowerShell(),[...prefix,...browserArguments(config,{mode:'fetch',outFile,preferredOrg,includeCredits,allowBootstrap,orgId,skipOrganizations})],{windowsHide:true,stdio:['ignore','ignore','pipe']});
    }catch(error){finish({v:1,ok:false,errorCode:'BROWSER_ERROR',error:String(error?.message??error)});return;}
    child.stderr?.on('data',chunk=>{if(stderr.length<8192)stderr+=chunk.toString('utf8');});
    child.on('error',error=>finish({v:1,ok:false,errorCode:'BROWSER_ERROR',error:String(error?.message??error)}));
    child.on('close',code=>{
      let bundle=null;
      try{bundle=JSON.parse(fs.readFileSync(outFile,'utf8').replace(/^\uFEFF/,''));}catch{}
      finish(bundle??{v:1,ok:false,errorCode:'BROWSER_ERROR',error:('helper exit '+code+' '+stderr).trim().slice(0,300)});
    });
  });
}

// The organization list rarely changes. With a cache object the reader asks
// for it at most every 30 minutes and otherwise reads only the usage of the
// organization it already knows, halving the requests to claude.ai.
export const ORG_CACHE_MS=30*60000;
export function newOrganizationCache(){return {request:null,bootstrap:null,bootstrapAt:0,selectedOrg:null,at:0};}

export async function readUsage(config,options={}) {
  const now=options.now??Date.now;
  const cache=options.orgCache??null;
  const attempt=async useCache=>{
    const started=now();
    const fresh=!!(useCache && cache?.request && cache.selectedOrg && started-cache.at>=0 && started-cache.at<ORG_CACHE_MS &&
      (!options.preferredOrg || options.preferredOrg===cache.selectedOrg));
    const bundle=await runBrowserFetch(config,{...options,orgId:fresh?cache.selectedOrg:null,skipOrganizations:fresh});
    const skipped=fresh && !!bundle && !bundle.errorCode && bundle.session?.hasSessionCookie===true && !!bundle.requests && !bundle.requests.organizations;
    const bootstrapFetched=!!bundle?.requests?.bootstrap;
    if(skipped)bundle.requests.organizations=cache.request;
    if(bundle?.requests && !bundle.requests.bootstrap && cache?.bootstrap && bundle.selectedOrg===cache.selectedOrg && started-cache.bootstrapAt<12*3600000)bundle.requests.bootstrap=cache.bootstrap;
    return {snapshot:normalizeClaudeBundle(bundle,{now:now(),creditsRequested:options.includeCredits===true}),skipped,bundle,started,bootstrapFetched};
  };
  let result=await attempt(true);
  if(result.skipped && !result.snapshot.ok && !isTransientError(result.snapshot.errorCode)){
    // The remembered organization did not answer (signed out, left a team,
    // plan changed): read the organization list again right away.
    if(cache)Object.assign(cache,newOrganizationCache());
    result=await attempt(false);
  }
  let {snapshot}=result;
  const {skipped,bundle,started,bootstrapFetched}=result;
  if(options.preferredOrg && snapshot.selectedOrg && snapshot.selectedOrg.toLowerCase()!==options.preferredOrg.toLowerCase()){
    snapshot={...failure('ORG_UNAVAILABLE'),selectedOrg:options.preferredOrg,accountKey:accountFingerprint(options.preferredOrg),orgs:snapshot.orgs??[],clearPrevious:true};
  }
  if(cache){
    if(snapshot.queryOk && snapshot.planKnown && !skipped && bundle?.requests?.organizations){
      const sameOrg=cache.selectedOrg===snapshot.selectedOrg;
      cache.bootstrap=bundle.requests.bootstrap??(sameOrg?cache.bootstrap:null);
      cache.bootstrapAt=bootstrapFetched?started:sameOrg?cache.bootstrapAt:0;
      cache.request=bundle.requests.organizations;cache.selectedOrg=snapshot.selectedOrg;cache.at=started;
    }else if(!snapshot.ok && !isTransientError(snapshot.errorCode)){Object.assign(cache,newOrganizationCache());}
  }
  return snapshot;
}

// --- shared file helpers ------------------------------------------------------
const pauseSync=ms=>Atomics.wait(new Int32Array(new SharedArrayBuffer(4)),0,0,ms);
export function atomicJson(file,data) {
  fs.mkdirSync(path.dirname(file),{recursive:true});
  const tmp=file+'.'+process.pid+'.'+randomUUID()+'.tmp';
  try{
    fs.writeFileSync(tmp,JSON.stringify(data,null,2)+'\n');
    // Windows refuses the rename while another process (the widget reading the
    // file, an antivirus scan) has the target open. That lasts milliseconds, so
    // try a few more times before reporting a failure.
    for(let attempt=1;;attempt++){
      try{fs.renameSync(tmp,file);break;}
      catch(error){if(attempt>=5 || !['EPERM','EBUSY','EACCES'].includes(error?.code))throw error;pauseSync(15);}
    }
  }finally{try{fs.unlinkSync(tmp);}catch{}}
}

export function freshness(window,observedAt,now=Date.now(),staleMs=420000) {
  if(!window || !Number.isFinite(observedAt))return 'unavailable';
  if(Number.isFinite(window.resetsAt) && window.resetsAt>0 && window.resetsAt*1000<=now)return 'expired';
  return now-observedAt>staleMs?'stale':'fresh';
}
