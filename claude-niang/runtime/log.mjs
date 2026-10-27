import fs from 'node:fs';
import path from 'node:path';

// Same file and line format as runtime/log.ps1: <dataDir>\logs\claude-niang.log,
// rolled over to claude-niang.1.log at 1 MB. Only short lifecycle and failure
// notes belong here, never cookies, tokens or organization ids.
export const LOG_LIMIT=1024*1024;
const recent=new Map();
const pad=(value,width=2)=>String(value).padStart(width,'0');

export function logStamp(date) {
  const offset=-date.getTimezoneOffset(),sign=offset<0?'-':'+',minutes=Math.abs(offset);
  return date.getFullYear()+'-'+pad(date.getMonth()+1)+'-'+pad(date.getDate())+' '+pad(date.getHours())+':'+pad(date.getMinutes())+':'+pad(date.getSeconds())+'.'+pad(date.getMilliseconds(),3)+
    ' '+sign+pad(Math.floor(minutes/60))+':'+pad(minutes%60);
}

export function writeLog(dataDir,source,message,{now=Date.now(),limit=LOG_LIMIT}={}) {
  try{
    let text=String(message instanceof Error?message.message:message??'').replace(/\s+/g,' ').trim();
    if(!dataDir || !text)return false;
    if(text.length>1000)text=text.slice(0,1000)+'...';
    // A failure repeated by a timer is written once a minute, not on every tick.
    const key=dataDir+'|'+source+'|'+text,last=recent.get(key);
    if(last!==undefined && now-last>=0 && now-last<60000)return false;
    if(recent.size>=200)recent.clear();
    recent.set(key,now);
    const dir=path.join(dataDir,'logs'),file=path.join(dir,'claude-niang.log');
    fs.mkdirSync(dir,{recursive:true});
    try{
      if(fs.statSync(file).size>=limit){
        const previous=path.join(dir,'claude-niang.1.log');
        fs.rmSync(previous,{force:true});fs.renameSync(file,previous);
      }
    }catch{}
    fs.appendFileSync(file,logStamp(new Date(now))+' ['+source+' '+process.pid+'] '+text+'\r\n');
    return true;
  }catch{return false;}
}
