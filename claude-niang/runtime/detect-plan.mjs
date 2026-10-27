import fs from 'node:fs';
import path from 'node:path';
import {fileURLToPath} from 'node:url';
import {readUsage} from './claude-usage.mjs';
import {formatMoney} from './shared.mjs';

// 检测套餐：直接读一次 claude.ai（与挂件相同的只读请求），不输出 Cookie、令牌或组织编号。
const root=path.resolve(path.dirname(fileURLToPath(import.meta.url)),'..');
const configPath=path.join(root,'installation.json');
let config;
try{config=JSON.parse(fs.readFileSync(configPath,'utf8').replace(/^﻿/,''));}
catch{console.error('请先运行「安装Claude娘.cmd」。');process.exit(1);}
let preferredOrg=null;
try{preferredOrg=JSON.parse(fs.readFileSync(path.join(config.dataDir,'settings.json'),'utf8').replace(/^﻿/,'')).preferredOrg??null;}catch{}
const result=await readUsage({...config,configPath},{preferredOrg,includeCredits:true,allowBootstrap:true});
const report={plan:result.plan,planLabel:result.planLabel,planKnown:result.planKnown,rateLimitTier:result.rateLimitTier??null,
  organization:result.org?.name??null,organizations:result.org?.count??0,quotaAvailable:result.ok,queryOk:result.queryOk,
  windows:(result.windows??[]).map(({kind,label,used,remaining,resetsAt,usedMinor,limitMinor,currency})=>({kind,label,used,remaining,resetsAt,...(kind==='extra'?{usedMinor,limitMinor,currency}:{})})),
  credits:result.credits??null,errorCode:result.errorCode??null,error:result.error??null};
if(process.argv.includes('--json'))console.log(JSON.stringify(report,null,2));
else{
  console.log('当前套餐：'+report.planLabel+(report.rateLimitTier?'（'+report.rateLimitTier+'）':''));
  if(report.organization)console.log('组织：'+report.organization+(report.organizations>1?'（共 '+report.organizations+' 个）':''));
  for(const w of report.windows){
    if(w.kind==='extra')console.log(w.label+'：已用 '+formatMoney(w.usedMinor,w.currency)+(w.limitMinor?' / '+formatMoney(w.limitMinor,w.currency):''));
    else console.log(w.label+'：剩余 '+w.remaining+'%'+(w.resetsAt?'，'+new Date(w.resetsAt*1000).toLocaleString('zh-CN',{hour12:false})+' 重置':''));
  }
  if(report.credits)console.log('预付余额：'+formatMoney(report.credits.amountMinor,report.credits.currency));
  if(report.error)console.log(report.error);
}
process.exitCode=report.queryOk?0:1;
