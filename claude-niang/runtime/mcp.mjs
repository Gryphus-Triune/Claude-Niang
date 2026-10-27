#!/usr/bin/env node
// Claude娘额度 · MCP server for Claude Desktop.
// The same file runs from the widget folder and from the packaged Claude
// Desktop extension (.mcpb), where the release puts shared.mjs next to it. It
// only reads the quota snapshot that the Claude娘 widget keeps on this
// computer, and can ask the running widget for a fresh read. It never creates
// chats or calls a model, and it never sees cookies or tokens.
import os from 'node:os';
import path from 'node:path';
import readline from 'node:readline';
import {fileURLToPath} from 'node:url';
import {readJson,requestPipeRefresh,localDay,formatMoney} from './shared.mjs';

// The extension keeps manifest.json one folder above server/index.mjs; in the
// widget folder the version comes from package.json next to runtime/.
function ownVersion() {
  for(const name of ['../manifest.json','../package.json']){
    const version=readJson(fileURLToPath(new URL(name,import.meta.url)))?.version;
    if(typeof version==='string')return version;
  }
  return '0.0.0';
}
const VERSION=ownVersion();
const localData=process.env.LOCALAPPDATA || path.join(os.homedir(),'AppData','Local');
const DATA_DIR=process.env.CLAUDE_NIANG_DATA_DIR && process.env.CLAUDE_NIANG_DATA_DIR.trim() && !process.env.CLAUDE_NIANG_DATA_DIR.includes('${')
  ? path.resolve(process.env.CLAUDE_NIANG_DATA_DIR.trim())
  : path.join(localData,'ClaudeNiang','state');

function todayValid(snapshot,now){
  return snapshot.today?.day===localDay(now) && snapshot.today.accountKey===snapshot.accountKey;
}
function localTime(seconds,now) {
  const d=new Date(seconds*1000),today=new Date(now);
  const sameDay=(a,b)=>a.getFullYear()===b.getFullYear() && a.getMonth()===b.getMonth() && a.getDate()===b.getDate();
  const tomorrow=new Date(now);tomorrow.setDate(tomorrow.getDate()+1);
  const hm=d.toLocaleTimeString('zh-CN',{hour:'2-digit',minute:'2-digit',hour12:false});
  if(sameDay(d,today))return '今天 '+hm;
  if(sameDay(d,tomorrow))return '明天 '+hm;
  return (d.getMonth()+1)+'月'+d.getDate()+'日 '+['周日','周一','周二','周三','周四','周五','周六'][d.getDay()]+' '+hm;
}
function until(seconds,now) {
  let minutes=Math.ceil((seconds*1000-now)/60000);
  if(minutes<=0)return '已到重置时间';
  const d=Math.floor(minutes/1440);minutes-=d*1440;const h=Math.floor(minutes/60),m=minutes%60;
  return '约 '+(d?d+' 天 ':'')+(h?h+' 小时 ':'')+(d?'':m+' 分')+'后';
}

export function describe(snapshot,now=Date.now()) {
  if(!snapshot || typeof snapshot!=='object')return {text:'还没有额度数据：请确认已安装并打开 Claude 娘挂件，并在挂件里登录 Claude 账号。',data:{ok:false}};
  const lines=[];
  const windows=Array.isArray(snapshot.windows)?snapshot.windows:[];
  lines.push('Claude 套餐：'+(snapshot.planLabel??'未知')+(snapshot.org?.name?'（组织：'+snapshot.org.name+(snapshot.org.count>1?'，共 '+snapshot.org.count+' 个':'')+'）':''));
  for(const w of windows){
    if(w.kind==='extra'){
      lines.push('· 额外用量：已用 '+formatMoney(w.usedMinor,w.currency)+(w.limitMinor?' / 每月上限 '+formatMoney(w.limitMinor,w.currency)+(typeof w.remaining==='number'?'（剩余 '+w.remaining+'%）':''):''));
      continue;
    }
    const expired=w.resetsAt && w.resetsAt*1000<=now;
    lines.push('· '+(w.label??'额度')+'：'+(expired?'上次已用 '+w.used+'%，已到重置时间，等待刷新':'剩余 '+w.remaining+'%（已用 '+w.used+'%）')+
      (w.resetsAt && !expired?'，'+localTime(w.resetsAt,now)+' 重置（'+until(w.resetsAt,now)+'）':w.resetsAt?'':'，未提供重置时间'));
  }
  if(snapshot.credits)lines.push('· 预付余额：'+formatMoney(snapshot.credits.amountMinor,snapshot.credits.currency));
  if(todayValid(snapshot,now) && typeof snapshot.today.weeklyUsed==='number')lines.push('· 今日观测到的周额度增量约：+'+snapshot.today.weeklyUsed+' 个百分点（从 '+new Date(snapshot.today.since).toLocaleTimeString('zh-CN',{hour:'2-digit',minute:'2-digit',hour12:false})+' 起统计）');
  if(!windows.length)lines.push(snapshot.error??'没有额度窗口数据。');
  else if(snapshot.error)lines.push('提示：'+snapshot.error);
  if(snapshot.observedAt){
    const age=Math.max(0,Math.round((now-snapshot.observedAt)/60000));
    lines.push('数据时间：'+new Date(snapshot.observedAt).toLocaleString('zh-CN',{hour12:false})+(age?'（'+age+' 分钟前）':'（刚刚）')+'，来源：Claude 娘读取的 claude.ai 用量数据。');
  }
  const ageMs=Number.isFinite(snapshot.observedAt)?Math.max(0,now-snapshot.observedAt):null;
  const data={ok:!!snapshot.ok,queryOk:snapshot.queryOk===true,restored:snapshot.restored===true,refreshMode:'manual',ageMs,
    freshness:!snapshot.ok?'unavailable':snapshot.restored || snapshot.queryOk!==true || ageMs===null || ageMs>600000?'cached':'fresh',
    plan:snapshot.plan??null,planLabel:snapshot.planLabel??null,organization:snapshot.org?.name??null,
    windows:windows.map(w=>({kind:w.kind,label:w.label,used:w.used,
      remaining:w.resetsAt && w.resetsAt*1000<=now?null:w.remaining,lastRemaining:w.remaining,
      freshness:w.resetsAt && w.resetsAt*1000<=now?'expired':snapshot.queryOk!==true || ageMs===null || ageMs>600000?'cached':'fresh',
      resetsAt:w.resetsAt?new Date(w.resetsAt*1000).toISOString():null,resetsAtLocal:w.resetsAt?localTime(w.resetsAt,now):null,
      ...(w.kind==='extra'?{usedAmount:formatMoney(w.usedMinor,w.currency),limitAmount:w.limitMinor?formatMoney(w.limitMinor,w.currency):null}:{})})),
    credits:snapshot.credits?formatMoney(snapshot.credits.amountMinor,snapshot.credits.currency):null,
    todayWeeklyUsed:todayValid(snapshot,now)?snapshot.today.weeklyUsed:null,
    observedAt:snapshot.observedAt?new Date(snapshot.observedAt).toISOString():null,error:snapshot.error??null,errorCode:snapshot.errorCode??null};
  return {text:lines.join('\n'),data};
}

const tool={
  name:'get_claude_usage',
  title:'查看 Claude 额度',
  description:'读取 Claude 娘挂件在本机获取的 Claude 订阅套餐与额度：5 小时额度、每周额度、按模型的每周额度、额外用量和重置时间（本机时间）。只读，不会创建聊天或调用模型。refresh=true 时让挂件立即重新读取一次（挂件需在运行）。',
  inputSchema:{type:'object',properties:{refresh:{type:'boolean',description:'是否先让挂件重新读取一次（默认否）'}},additionalProperties:false},
  outputSchema:{type:'object',properties:{ok:{type:'boolean'},queryOk:{type:'boolean'},refreshMode:{const:'manual'},freshness:{enum:['fresh','cached','unavailable']},windows:{type:'array',items:{type:'object'}}},required:['ok']},
  annotations:{readOnlyHint:true,destructiveHint:false,idempotentHint:true,openWorldHint:false}
};

async function callTool(args) {
  let snapshot=null,note='';
  if(args?.refresh===true){
    snapshot=await requestPipeRefresh(DATA_DIR,{timeoutMs:95000,connectTimeoutMs:400});
    if(!snapshot)note='（挂件没有响应刷新请求，下面是上次保存的数据）\n';
  }
  if(!snapshot)snapshot=readJson(path.join(DATA_DIR,'status.json'));
  const preferred=readJson(path.join(DATA_DIR,'settings.json'))?.preferredOrg;
  if(typeof preferred==='string' && snapshot?.selectedOrg && preferred.toLowerCase()!==snapshot.selectedOrg.toLowerCase()){
    const row=snapshot.orgs?.find?.(org=>org.uuid?.toLowerCase()===preferred.toLowerCase());
    snapshot={ok:false,queryOk:false,windows:[],selectedOrg:preferred,planLabel:row?.planLabel??null,org:{name:row?.name??'所选组织'},errorCode:'SWITCHING_ORG',error:'组织已切换，请手动刷新所选组织的额度'};
  }
  const {text,data}=describe(snapshot);
  return {content:[{type:'text',text:note+text},{type:'text',text:'JSON: '+JSON.stringify(data)}],structuredContent:data,isError:!snapshot || (!snapshot.ok && !snapshot.queryOk)};
}

// Answer with the client's protocol version when this server supports it, and
// otherwise with the newest one it does, as the protocol asks.
const PROTOCOL_VERSIONS=['2025-11-25','2025-06-18','2025-03-26','2024-11-05'];
export function negotiateVersion(requested){return PROTOCOL_VERSIONS.includes(requested)?requested:PROTOCOL_VERSIONS[0];}

function send(message){process.stdout.write(JSON.stringify(message)+'\n');}
async function handle(message) {
  if(!message || typeof message!=='object' || Array.isArray(message) || typeof message.method!=='string'){
    if(message && message.id!==undefined)send({jsonrpc:'2.0',id:message.id,error:{code:-32600,message:'Invalid Request'}});
    return;
  }
  if(message.id===undefined || message.id===null)return; // notifications
  try{
    let result;
    switch(message.method){
      case 'initialize':result={protocolVersion:negotiateVersion(message.params?.protocolVersion),capabilities:{tools:{}},serverInfo:{name:'claude-niang-usage',title:'Claude娘额度',version:VERSION},instructions:'当用户询问 Claude 额度、用量、剩余次数或重置时间时，调用 get_claude_usage。'};break;
      case 'ping':result={};break;
      case 'tools/list':result={tools:[tool]};break;
      case 'tools/call':
        if(message.params?.name!==tool.name){send({jsonrpc:'2.0',id:message.id,error:{code:-32602,message:'Unknown tool'}});return;}
        {const args=message.params?.arguments??{};if(typeof args!=='object' || Array.isArray(args) || Object.keys(args).some(key=>key!=='refresh') || ('refresh' in args && typeof args.refresh!=='boolean')){send({jsonrpc:'2.0',id:message.id,error:{code:-32602,message:'Invalid tool arguments'}});return;}}
        result=await callTool(message.params?.arguments??{});break;
      case 'resources/list':result={resources:[]};break;
      case 'prompts/list':result={prompts:[]};break;
      default:send({jsonrpc:'2.0',id:message.id,error:{code:-32601,message:'Method not found'}});return;
    }
    send({jsonrpc:'2.0',id:message.id,result});
  }catch{send({jsonrpc:'2.0',id:message.id,error:{code:-32603,message:'Claude 娘额度服务暂不可用'}});}
}

const same=(a,b)=>process.platform==='win32'?a.toLowerCase()===b.toLowerCase():a===b;
const isMain=!!process.argv[1] && same(path.resolve(process.argv[1]),fileURLToPath(import.meta.url));
if(isMain || process.env.CLAUDE_NIANG_MCP_MAIN==='1'){
  readline.createInterface({input:process.stdin}).on('line',line=>{
    if(line.length>1024*1024)return;
    let message;try{message=JSON.parse(line);}catch{send({jsonrpc:'2.0',id:null,error:{code:-32700,message:'Parse error'}});return;}
    void handle(message);
  });
}
