import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
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
test('release tree synchronizes MCP version and code without touching local installation record',()=>{
  const scratch=fs.mkdtempSync(path.join(os.tmpdir(),'cn-release-')),out=path.join(scratch,'fresh');
  const config=path.join(root,'claude-niang','installation.json'),before=fs.existsSync(config)?fs.readFileSync(config):null;
  const info=createReleaseTree(root,out);assert.equal(info.refreshMode,'manual');assert.equal(info.containsUserState,false);
  const app=path.join(out,'claude-niang'),manifest=JSON.parse(fs.readFileSync(path.join(app,'extension','manifest.json'),'utf8'));
  assert.equal(manifest.version,info.version);assert.deepEqual(fs.readFileSync(path.join(app,'runtime','mcp.mjs')),fs.readFileSync(path.join(app,'extension','server','index.mjs')));
  assert.ok(fs.existsSync(path.join(app,'extension','LICENSE')));assert.equal(fs.existsSync(path.join(app,'installation.json')),false);
  if(before)assert.deepEqual(fs.readFileSync(config),before);
});
test('release manifest refuses traversal outside source tree',()=>{
  const scratch=fs.mkdtempSync(path.join(os.tmpdir(),'cn-release-invalid-'));
  fs.mkdirSync(path.join(scratch,'claude-niang','runtime'),{recursive:true});
  fs.writeFileSync(path.join(scratch,'claude-niang','runtime','install-files.json'),JSON.stringify([...Array(10).fill('package.json'),'../installation.json']));
  assert.throws(()=>releaseFiles(scratch),/Unsafe release path/);
});
