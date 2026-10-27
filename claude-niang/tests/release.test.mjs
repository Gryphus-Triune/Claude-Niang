import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import {spawnSync} from 'node:child_process';
import {fileURLToPath} from 'node:url';
import {releaseFiles,createReleaseTree} from '../../tools/release.mjs';

const root=path.resolve(path.dirname(fileURLToPath(import.meta.url)),'../..');
test('release whitelist excludes machine state and includes the default character and audio dependency',()=>{
  const files=releaseFiles(root);
  assert.ok(files.includes('claude-niang/assets/claude-niang.png'));
  assert.ok(files.includes('claude-niang/assets/claude-niang.glasses.json'));
  assert.ok(files.includes('claude-niang/runtime/audio-import.mjs'));
  assert.ok(files.includes('claude-niang/runtime/webview2/LICENSE.txt'));
  assert.ok(files.includes('.github/workflows/ci.yml'));
  assert.ok(!files.some(file=>/installation\.json$|install-log\.txt$|claude-desktop-mcp\.json$|(?:^|\/)(?:webview|state)\//.test(file)));
  for(const file of files)assert.ok(fs.existsSync(path.join(root,...file.split('/'))),'missing '+file);
});
test('README version and linked distribution resources match the release',()=>{
  const packageInfo=JSON.parse(fs.readFileSync(path.join(root,'claude-niang','package.json'),'utf8'));
  const readme=fs.readFileSync(path.join(root,'README.md'),'utf8');
  const version=readme.match(/\*\*当前程序版本：([^*]+)\*\*/);
  assert.ok(version,'README must identify the current program version');
  assert.equal(version[1],packageInfo.version);
  const files=releaseFiles(root);
  for(const resource of ['docs/screenshot.png','docs/customization.md','claude-niang/assets/quotes-LICENSE.txt']){
    assert.ok(readme.includes(resource),'README should link to '+resource);
    assert.ok(files.includes(resource),'release should contain '+resource);
  }
  assert.match(fs.readFileSync(path.join(root,'claude-niang','assets','quotes-LICENSE.txt'),'utf8'),/Copyright \(c\) 2026 MeteorNOX/);
});
test('release tree synchronizes MCP version and code without touching local installation record',()=>{
  const scratch=fs.mkdtempSync(path.join(os.tmpdir(),'cn-release-')),out=path.join(scratch,'fresh');
  const config=path.join(root,'claude-niang','installation.json'),before=fs.existsSync(config)?fs.readFileSync(config):null;
  const info=createReleaseTree(root,out);assert.equal(info.refreshMode,'manual');assert.equal(info.containsUserState,false);
  const app=path.join(out,'claude-niang'),manifest=JSON.parse(fs.readFileSync(path.join(app,'extension','manifest.json'),'utf8'));
  assert.equal(manifest.version,info.version);assert.deepEqual(fs.readFileSync(path.join(app,'runtime','mcp.mjs')),fs.readFileSync(path.join(app,'extension','server','index.mjs')));
  assert.deepEqual(fs.readFileSync(path.join(app,'runtime','shared.mjs')),fs.readFileSync(path.join(app,'extension','server','shared.mjs')));
  assert.ok(fs.existsSync(path.join(app,'extension','LICENSE')));assert.equal(fs.existsSync(path.join(app,'installation.json')),false);
  if(before)assert.deepEqual(fs.readFileSync(config),before);
});
test('packaged extension server runs on its own and reports the manifest version',()=>{
  const scratch=fs.mkdtempSync(path.join(os.tmpdir(),'cn-release-server-')),out=path.join(scratch,'fresh');
  const info=createReleaseTree(root,out),extension=path.join(out,'claude-niang','extension');
  // Only the extension folder is installed into Claude Desktop; the server must not reach outside it.
  const isolated=path.join(scratch,'installed');fs.cpSync(extension,isolated,{recursive:true});
  const request=JSON.stringify({jsonrpc:'2.0',id:1,method:'initialize',params:{protocolVersion:'2025-06-18'}})+'\n';
  const run=spawnSync(process.execPath,[path.join(isolated,'server','index.mjs')],{input:request,encoding:'utf8',timeout:10000,env:{...process.env,CLAUDE_NIANG_DATA_DIR:path.join(scratch,'state')}});
  const reply=JSON.parse(run.stdout.split('\n')[0]);
  assert.equal(reply.result.serverInfo.version,info.version);
});
test('release manifest refuses traversal outside source tree',()=>{
  const scratch=fs.mkdtempSync(path.join(os.tmpdir(),'cn-release-invalid-'));
  fs.mkdirSync(path.join(scratch,'claude-niang','runtime'),{recursive:true});
  fs.writeFileSync(path.join(scratch,'claude-niang','runtime','install-files.json'),JSON.stringify([...Array(10).fill('package.json'),'../installation.json']));
  assert.throws(()=>releaseFiles(scratch),/Unsafe release path/);
});
