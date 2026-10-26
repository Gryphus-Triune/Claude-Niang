import fs from 'node:fs';
import path from 'node:path';
import {spawnSync} from 'node:child_process';
import {randomUUID} from 'node:crypto';
import {fileURLToPath} from 'node:url';
import {atomicJson,browserArguments,windowsPowerShell} from './claude-usage.mjs';
import {requestRefresh} from './refresh-client.mjs';

// 调试/脚本用的小命令：status | query | show | quote | menu | characters | stop | login | logout
const root=path.resolve(path.dirname(fileURLToPath(import.meta.url)),'..');
const configPath=path.join(root,'installation.json');
const config={...JSON.parse(fs.readFileSync(configPath,'utf8').replace(/^﻿/,'')),configPath};
const command=process.argv[2]??'status';
const display=['show','quote','menu','characters','close-menu','music-on','music-off'];
if(command==='query'){
  const result=await requestRefresh(config,configPath);
  console.log(JSON.stringify(result));process.exitCode=result.queryOk && result.ok?0:1;
}else if(display.includes(command)){
  atomicJson(path.join(config.dataDir,'display-request.json'),{mode:command==='show'?'quota':command,at:Date.now(),nonce:randomUUID()});
  console.log('已发送：'+command);
}else if(command==='stop'){
  fs.writeFileSync(path.join(config.dataDir,'stop.flag'),'stop');console.log('已请求退出 Claude 娘');
}else if(command==='login' || command==='logout'){
  const result=spawnSync(windowsPowerShell(),browserArguments(config,{mode:command}),{stdio:['ignore','pipe','inherit'],windowsHide:command!=='login'});
  const text=String(result.stdout??'');
  let answer=null;try{answer=JSON.parse(text.replace(/^\uFEFF/,''));}catch{}
  if(answer?.ok===true && (command==='logout'?answer.signedOut===true:answer.signedIn===true)){
    atomicJson(path.join(config.dataDir,'session-reset.flag'),{id:randomUUID(),at:Date.now(),state:command==='logout'?'signed-out':'signed-in'});
  }else process.exitCode=1;
  console.log(text||('helper exit '+result.status));
}else if(command==='status'){
  const read=name=>{try{return JSON.parse(fs.readFileSync(path.join(config.dataDir,name),'utf8').replace(/^﻿/,''));}catch{return null;}};
  console.log(JSON.stringify({runtime:read('runtime.json'),quota:read('status.json'),presence:read('presence.json'),worker:read('worker-status.json')}));
}else throw new Error('Unknown command');
