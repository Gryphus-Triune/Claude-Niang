import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import {Worker} from 'node:worker_threads';
import {atomicJson} from '../runtime/claude-usage.mjs';

// A reader on another thread keeps the target open for holdMs; on Windows any
// open handle makes the replacing rename fail until it is closed.
function holdOpen(file,holdMs){
  const flag=new Int32Array(new SharedArrayBuffer(4));
  const worker=new Worker(`
    const {workerData}=require('node:worker_threads');const fs=require('node:fs');
    const fd=fs.openSync(workerData.file,'r');
    Atomics.store(workerData.flag,0,1);Atomics.notify(workerData.flag,0);
    Atomics.wait(workerData.flag,0,1,workerData.holdMs);fs.closeSync(fd);`,{eval:true,workerData:{file,flag,holdMs}});
  Atomics.wait(flag,0,0,5000);
  return new Promise(resolve=>worker.once('exit',resolve));
}

test('a write waits out a reader that blocks the replace for a moment',{skip:process.platform!=='win32'},async()=>{
  const dir=fs.mkdtempSync(path.join(os.tmpdir(),'cn-atomic-')),file=path.join(dir,'state.json');
  atomicJson(file,{n:1});
  const released=holdOpen(file,20);
  atomicJson(file,{n:2});
  assert.deepEqual(JSON.parse(fs.readFileSync(file,'utf8')),{n:2});
  await released;
});
test('a write gives up on a reader that stays, keeps the old file and leaves no temporary file',{skip:process.platform!=='win32'},async()=>{
  const dir=fs.mkdtempSync(path.join(os.tmpdir(),'cn-atomic-busy-')),file=path.join(dir,'state.json');
  atomicJson(file,{n:1});
  const released=holdOpen(file,2000);
  assert.throws(()=>atomicJson(file,{n:2}),error=>['EPERM','EBUSY','EACCES'].includes(error.code));
  await released;
  assert.deepEqual(JSON.parse(fs.readFileSync(file,'utf8')),{n:1});
  assert.deepEqual(fs.readdirSync(dir),['state.json']);
});
