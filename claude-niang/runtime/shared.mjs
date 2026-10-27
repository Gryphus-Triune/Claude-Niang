import fs from 'node:fs';
import net from 'node:net';
import path from 'node:path';
import {createHash,randomUUID} from 'node:crypto';

// Helpers shared by the quota worker and the Claude Desktop extension. The
// release copies this file next to the extension's server/index.mjs, so it
// must not import other local modules.

export function readJson(file) {
  try{return JSON.parse(fs.readFileSync(file,'utf8').replace(/^﻿/,''));}catch{return null;}
}

// The worker's pipe for one data folder (a socket file outside Windows, where
// only the tests run).
export function workerEndpoint(dataDir){
  const key=createHash('sha256').update(path.resolve(dataDir).toLowerCase()).digest('hex').slice(0,32);
  return process.platform==='win32'?'\\\\.\\pipe\\claude-niang-usage-'+key:path.join(dataDir,'worker.sock');
}

// Asks the running worker for one fresh read over its pipe. The pipe offers
// only this read-only request, never arbitrary commands. Resolves null when no
// worker answers in time.
export function requestPipeRefresh(dataDir,{timeoutMs=45000,connectTimeoutMs=300}={}){
  return new Promise(resolve=>{
    const id=randomUUID(),deadline=Date.now()+timeoutMs;let finished=false,buffer='',timer;
    const socket=net.createConnection(workerEndpoint(dataDir));
    socket.setEncoding('utf8');
    const finish=value=>{if(finished)return;finished=true;clearTimeout(timer);socket.destroy();resolve(value);};
    timer=setTimeout(()=>finish(null),Math.min(connectTimeoutMs,timeoutMs));
    socket.on('error',()=>finish(null));socket.on('close',()=>finish(null));
    socket.on('connect',()=>{
      clearTimeout(timer);timer=setTimeout(()=>finish(null),Math.max(0,deadline-Date.now()));
      socket.write(JSON.stringify({id,method:'refresh'})+'\n');
    });
    socket.on('data',chunk=>{
      buffer+=chunk;if(buffer.length>2*1024*1024)return finish(null);
      const end=buffer.indexOf('\n');if(end<0)return;
      try{const result=JSON.parse(buffer.slice(0,end));finish(result.requestId===id && result.snapshot && typeof result.snapshot==='object'?result.snapshot:null);}catch{finish(null);}
    });
  });
}

export function localDay(ms){
  const d=new Date(ms);
  return d.getFullYear()+'-'+String(d.getMonth()+1).padStart(2,'0')+'-'+String(d.getDate()).padStart(2,'0');
}

const symbols={USD:'$',EUR:'€',GBP:'£',JPY:'¥',CNY:'¥'};
export function formatMoney(minor,currency='USD') {
  if(typeof minor!=='number' || !Number.isFinite(minor))return '—';
  const code=String(currency||'USD').toUpperCase(),digits=code==='JPY'?0:2;
  return (symbols[code]??code+' ')+(minor/(digits?100:1)).toLocaleString('en-US',{minimumFractionDigits:digits,maximumFractionDigits:digits});
}
