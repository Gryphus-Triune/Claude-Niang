import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import {writeLog,logStamp} from '../runtime/log.mjs';

const lines=dir=>fs.readFileSync(path.join(dir,'logs','claude-niang.log'),'utf8').split('\r\n').filter(Boolean);

test('log lines carry local time, source and pid; repeats within a minute are written once',()=>{
  const dir=fs.mkdtempSync(path.join(os.tmpdir(),'cn-log-')),now=Date.now();
  assert.equal(writeLog(dir,'worker','读取失败：NETWORK\n  详情',{now}),true);
  assert.equal(writeLog(dir,'worker','读取失败：NETWORK   详情',{now:now+1000}),false,'repeat written');
  assert.equal(writeLog(dir,'widget','读取失败：NETWORK 详情',{now:now+1000}),true,'other source suppressed');
  assert.equal(writeLog(dir,'worker','读取失败：NETWORK 详情',{now:now+61000}),true,'repeat after a minute dropped');
  const all=lines(dir);assert.equal(all.length,3);
  assert.match(all[0],/^\d{4}-\d\d-\d\d \d\d:\d\d:\d\d\.\d{3} [+-]\d\d:\d\d \[worker \d+\] 读取失败：NETWORK 详情$/);
  assert.equal(writeLog(dir,'worker','   ',{now}),false);assert.equal(writeLog('', 'worker','x',{now}),false);
});
test('the log rolls over to one previous file at the size limit',()=>{
  const dir=fs.mkdtempSync(path.join(os.tmpdir(),'cn-log-roll-')),now=Date.now();
  for(let i=0;i<40;i++)writeLog(dir,'worker','line '+i+' '+'x'.repeat(40),{now:now+i,limit:1000});
  const current=fs.statSync(path.join(dir,'logs','claude-niang.log')).size,previous=fs.statSync(path.join(dir,'logs','claude-niang.1.log')).size;
  assert.ok(current<1100 && previous>=1000 && previous<1100,'sizes '+current+'/'+previous);
  assert.deepEqual(fs.readdirSync(path.join(dir,'logs')).sort(),['claude-niang.1.log','claude-niang.log']);
});
test('timestamps use the local offset',()=>{
  const date=new Date(2026,0,2,3,4,5,6),offset=-date.getTimezoneOffset();
  const sign=offset<0?'-':'+',hours=String(Math.floor(Math.abs(offset)/60)).padStart(2,'0'),minutes=String(Math.abs(offset)%60).padStart(2,'0');
  assert.equal(logStamp(date),'2026-01-02 03:04:05.006 '+sign+hours+':'+minutes);
});
