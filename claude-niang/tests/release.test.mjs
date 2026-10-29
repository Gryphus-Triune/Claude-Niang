import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import {spawnSync} from 'node:child_process';
import {fileURLToPath} from 'node:url';
import {createHash} from 'node:crypto';
import {releaseFiles,createReleaseTree,validateReleaseMetadata,verifyReleaseAssets,publishRelease} from '../../tools/release.mjs';

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

test('release metadata requires one exact stable version across the tag, manifest, README and changelog',t=>{
  const dir=fs.mkdtempSync(path.join(os.tmpdir(),'cn-release-metadata-'));t.after(()=>fs.rmSync(dir,{recursive:true,force:true}));
  const write=(name,text)=>{const file=path.join(dir,name);fs.mkdirSync(path.dirname(file),{recursive:true});fs.writeFileSync(file,text);};
  const reset=()=>{write('claude-niang/package.json','{"version":"2.3.4"}');write('claude-niang/extension/manifest.json','{"version":"2.3.4"}');write('README.md','**当前程序版本：2.3.4**');write('CHANGELOG.md','## 2.3.4 — today\n\nFixed a bug.\n\n## 2.3.3 — before\nOld notes.\n');};
  reset();assert.deepEqual(validateReleaseMetadata(dir,'v2.3.4'),{version:'2.3.4',tag:'v2.3.4',notes:'Fixed a bug.'});
  for(const tag of ['2.3.4','v2.3.5','v02.3.4','v2.3.4-repack.1','v2.3.4-beta'])assert.throws(()=>validateReleaseMetadata(dir,tag));
  for(const [file,text] of [['claude-niang/extension/manifest.json','{"version":"2.3.3"}'],['README.md','**当前程序版本：2.3.3**'],['CHANGELOG.md','## 2.3.4-repack.1\nWrong section'],['CHANGELOG.md','## 2.3.4\n\n## 2.3.3\nOld'],['CHANGELOG.md','## 2.3.4\nA\n## 2.3.4\nB']]){reset();write(file,text);assert.throws(()=>validateReleaseMetadata(dir,'v2.3.4'),file);}
  for(const stale of ['https://github.com/Gryphus-Triune/Claude-Niang/releases/tag/v2.3.3','https://github.com/Gryphus-Triune/Claude-Niang/releases/download/v2.3.3/claude-niang-usage.mcpb','claude-niang-v2.3.3-windows.zip','https://img.shields.io/badge/Release-v2.3.3-D97757']){
    reset();write('README.md','**当前程序版本：2.3.4**\n'+stale);assert.throws(()=>validateReleaseMetadata(dir,'v2.3.4'),/README/,'updating version text alone must not leave stale download links');
  }
  assert.equal(validateReleaseMetadata(root,'v'+JSON.parse(fs.readFileSync(path.join(root,'claude-niang/package.json'))).version).version,JSON.parse(fs.readFileSync(path.join(root,'claude-niang/package.json'))).version);
});

test('release assets reject extra files, bad ZIP checksums and an MCPB that differs from its ZIP entry',t=>{
  const dir=fs.mkdtempSync(path.join(os.tmpdir(),'cn-release-assets-'));t.after(()=>fs.rmSync(dir,{recursive:true,force:true}));
  const zip='claude-niang-v2.3.4-windows.zip',mcpb='claude-niang-usage.mcpb',hash=value=>createHash('sha256').update(value).digest('hex');
  fs.writeFileSync(path.join(dir,zip),'archive');fs.writeFileSync(path.join(dir,mcpb),'extension');fs.writeFileSync(path.join(dir,zip+'.sha256'),hash('archive')+'  '+zip+'\n');
  assert.equal(verifyReleaseAssets(dir,'2.3.4',hash('extension')).length,3);
  fs.writeFileSync(path.join(dir,'leftover.zip'),'old');assert.throws(()=>verifyReleaseAssets(dir,'2.3.4',hash('extension')),/exactly/);fs.unlinkSync(path.join(dir,'leftover.zip'));
  assert.throws(()=>verifyReleaseAssets(dir,'2.3.4',hash('different extension')),/MCPB checksum/);
  fs.writeFileSync(path.join(dir,zip),'changed');assert.throws(()=>verifyReleaseAssets(dir,'2.3.4',hash('extension')),/ZIP checksum/);
});

function publishingFixture(){
  const sha='a'.repeat(40),api='/repos/example/claude-niang',metadata={version:'2.3.4',tag:'v2.3.4',notes:'Fixed a bug.'};
  const names=['claude-niang-v2.3.4-windows.zip','claude-niang-v2.3.4-windows.zip.sha256','claude-niang-usage.mcpb'];
  const assets=names.map((name,i)=>({name,file:name,size:i+10,sha256:String(i+1).repeat(64)}));
  const state={tag:null,release:null,assets:[],calls:[],latest:{tag_name:'v2.3.3'},uploads:0,failUpload:0,tamper:false,moveMain:false,moveTag:false};
  const request=async(method,route,options={})=>{
    state.beforeRequest?.(method,route);
    state.calls.push({method,route,json:options.json});
    if(route===api+'/git/ref/heads/main')return {object:{type:'commit',sha:state.moveMain && state.uploads?'b'.repeat(40):sha}};
    if(route===api+'/git/ref/tags/v2.3.4')return state.tag?{object:{type:'commit',sha:state.moveTag && state.uploads?'b'.repeat(40):state.tag}}:null;
    if(route.startsWith(api+'/releases?'))return state.release?[state.release]:[];
    if(route===api+'/releases/latest')return state.latest;
    if(route===api+'/git/refs' && method==='POST'){assert.equal(state.tag,null);state.tag=options.json.sha;return {};}
    if(route===api+'/releases' && method==='POST'){assert.equal(state.release,null);state.release={id:7,...options.json,upload_url:'https://uploads.github.com'+api+'/releases/7/assets{?name,label}'};return state.release;}
    if(route===api+'/releases/7/assets?per_page=100')return state.assets;
    if(route===api+'/releases/7' && method==='GET')return {...state.release};
    if(route.startsWith(api+'/releases/assets/') && method==='DELETE'){const id=Number(route.split('/').pop());state.assets=state.assets.filter(a=>a.id!==id);return null;}
    if(route.startsWith('https://uploads.github.com') && method==='POST'){
      state.uploads++;if(state.failUpload===state.uploads)throw new Error('simulated upload failure');
      const name=new URL(route).searchParams.get('name'),asset=assets.find(a=>a.name===name);assert.ok(asset);
      const uploaded={id:state.uploads,name,size:asset.size,state:'uploaded',digest:'sha256:'+(state.tamper?'0'.repeat(64):asset.sha256)};state.assets.push(uploaded);return uploaded;
    }
    if(route===api+'/releases/7' && method==='PATCH'){state.release={...state.release,...options.json,html_url:'https://example.com/release'};return state.release;}
    throw new Error('Unexpected mock request '+method+' '+route);
  };
  return {state,assets,sha,metadata,run:overrides=>publishRelease({metadata,assets,sha,repository:'example/claude-niang',event:'workflow_dispatch',ref:'refs/heads/main',request,...overrides})};
}

test('publishing creates one tag and verified draft, or continues a same-SHA tag without creating it again',async()=>{
  for(const existing of [false,true]){
    const f=publishingFixture();if(existing)f.state.tag=f.sha;await f.run();
    assert.equal(f.state.release.draft,false);assert.equal(f.state.release.make_latest,'true');assert.equal(f.state.assets.length,3);
    assert.equal(f.state.calls.filter(c=>c.method==='POST' && c.route.endsWith('/git/refs')).length,existing?0:1);
    assert.equal(f.state.calls.filter(c=>c.method==='POST' && c.route.endsWith('/releases')).length,1);
    assert.equal(f.state.calls.at(-1).method,'PATCH');
  }
});
test('publishing refuses wrong commits, published releases and unrelated drafts without writing',async()=>{
  for(const kind of ['branch','tag','published','draft']){
    const f=publishingFixture();f.state.tag=kind==='tag'?'b'.repeat(40):f.sha;
    if(kind==='published' || kind==='draft')f.state.release={tag_name:'v2.3.4',draft:kind==='draft',body:'User notes'};
    await assert.rejects(f.run(kind==='branch'?{ref:'refs/heads/other'}:{}));
    assert.ok(f.state.calls.every(c=>c.method==='GET'),kind);
  }
});
test('failed uploads stay private and only the exact owned draft can resume and replace known attachments',async()=>{
  const f=publishingFixture();f.state.failUpload=2;await assert.rejects(f.run(),/upload failure/);assert.equal(f.state.release.draft,true);
  f.state.failUpload=0;f.assets[0].sha256='9'.repeat(64);await f.run();
  assert.equal(f.state.release.draft,false);assert.equal(f.state.calls.filter(c=>c.method==='POST' && c.route.endsWith('/releases')).length,1);
  assert.equal(f.state.calls.filter(c=>c.method==='DELETE').length,1);
});
test('bad remote digests and tag movement prevent publication; unknown draft attachments are never deleted',async()=>{
  for(const option of ['tamper','moveTag']){
    const f=publishingFixture();f.state[option]=true;await assert.rejects(f.run());assert.equal(f.state.release.draft,true);
    assert.ok(f.state.calls.every(c=>c.method!=='PATCH'));
  }
  const f=publishingFixture();f.state.failUpload=1;await assert.rejects(f.run());f.state.failUpload=0;
  f.state.assets.push({id:99,name:'user-notes.txt'});await assert.rejects(f.run(),/unexpected assets/);assert.ok(f.state.calls.every(c=>c.method!=='DELETE'));
});
test('the original tested main snapshot can resume after main advances without moving its tag',async()=>{
  const f=publishingFixture();f.state.failUpload=2;await assert.rejects(f.run(),/upload failure/);
  f.state.moveMain=true;f.state.failUpload=0;await f.run();
  assert.equal(f.state.release.draft,false);assert.equal(f.state.tag,f.sha);assert.equal(f.state.release.target_commitish,f.sha);
  assert.equal(f.state.calls.filter(c=>c.method==='POST' && c.route.endsWith('/git/refs')).length,1);
  assert.ok(f.state.calls.every(c=>!c.route.endsWith('/git/ref/heads/main')),'later main movement is not a reason to alter or abandon the tested snapshot');
});
test('manual draft publication stops the next upload or deletion before existing attachments are changed',async()=>{
  for(const phase of ['upload','delete']){
    const f=publishingFixture();let changed=false;
    if(phase==='delete'){
      f.state.failUpload=2;await assert.rejects(f.run());f.state.failUpload=0;f.assets[0].sha256='9'.repeat(64);
    }
    const before=f.state.calls.length;
    f.state.beforeRequest=(method,route)=>{if(method==='GET' && route.endsWith('/releases/7') && f.state.uploads>=1){f.state.release.draft=false;changed=true;}};
    await assert.rejects(f.run(),/published or its draft was modified/);assert.equal(changed,true);
    const writes=f.state.calls.slice(before).filter(c=>c.method!=='GET');
    if(phase==='delete')assert.deepEqual(writes,[],'manual publication must be detected before deleting an old asset');
    else assert.equal(writes.filter(c=>c.route.startsWith('https://uploads.github.com')).length,1,'no second upload after manual publication');
    assert.ok(writes.every(c=>c.method!=='PATCH' && c.method!=='DELETE'));
  }
});
test('final publication revalidates the complete draft ownership after uploads',async()=>{
  for(const [field,value] of [['draft',false],['prerelease',true],['immutable',true],['target_commitish','b'.repeat(40)],['name','Edited title'],['body','Edited notes'],['tag_name','v9.0.0']]){
    const f=publishingFixture();let changed=false;
    f.state.beforeRequest=(method,route)=>{if(method==='GET' && route.endsWith('/releases/7') && f.state.uploads===3){f.state.release[field]=value;changed=true;}};
    await assert.rejects(f.run(),/published or its draft was modified/);assert.equal(changed,true,field);
    assert.ok(f.state.calls.every(c=>c.method!=='PATCH'),field);
  }
});
test('publishing an old or equal version never takes Latest from a newer or manually named release',async()=>{
  for(const tag of ['v9.0.0','v2.3.4','v2.3.4-repack.1','manual-choice']){const f=publishingFixture();f.state.latest={tag_name:tag};await f.run();assert.equal(f.state.release.make_latest,'false',tag);}
  const f=publishingFixture();f.state.latest=null;await f.run();assert.equal(f.state.release.make_latest,'true');
});
