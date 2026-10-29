import fs from 'node:fs';
import path from 'node:path';
import {fileURLToPath} from 'node:url';
import {createHash} from 'node:crypto';
import {execFileSync} from 'node:child_process';

const rootFiles=['README.md','LICENSE','CHANGELOG.md','CONTRIBUTING.md','.gitignore','.gitattributes','build-release.ps1',
  '安装Claude娘.cmd','打开Claude娘.cmd','登录Claude账号.cmd','检测套餐.cmd','停用Claude娘.cmd','tools/release.mjs','tools/quote-layouts.ps1',
  'docs/screenshot.png','docs/images/quota-preview.png','docs/customization.md','claude-niang/assets/quotes-LICENSE.txt','.github/workflows/ci.yml'];
function safeRelative(value){
  if(typeof value!=='string' || !value || value.includes('\\') || path.posix.isAbsolute(value) || /^[A-Za-z]:/.test(value) || value.split('/').some(x=>!x || x==='.' || x==='..'))throw new Error('Unsafe release path');
  return value;
}
function walk(dir){
  const files=[];
  for(const item of fs.readdirSync(dir,{withFileTypes:true})){
    const full=path.join(dir,item.name);
    if(item.isSymbolicLink())throw new Error('Release inputs must not be symbolic links');
    if(item.isDirectory())files.push(...walk(full));else if(item.isFile())files.push(full);
  }
  return files;
}
export function releaseFiles(root){
  const app=path.join(root,'claude-niang');
  const required=JSON.parse(fs.readFileSync(path.join(app,'runtime','install-files.json'),'utf8').replace(/^\uFEFF/,''));
  if(!Array.isArray(required) || required.length<10)throw new Error('Invalid install manifest');
  // Only listed files are released, so installation records, logs and account
  // data in a working copy never reach a package. The extension's server files and
  // LICENSE are generated below from runtime/mcp.mjs, runtime/shared.mjs and the
  // root LICENSE.
  const files=[...rootFiles,...required.map(value=>'claude-niang/'+safeRelative(value)),
    'claude-niang/extension/manifest.json','claude-niang/extension/icon.png'];
  for(const file of walk(path.join(app,'tests')))files.push(path.relative(root,file).split(path.sep).join('/'));
  return [...new Set(files.map(safeRelative))].sort();
}
export function createReleaseTree(root,output){
  root=path.resolve(root);output=path.resolve(output);
  if(root===output || root.startsWith(output+path.sep))throw new Error('Output must be a separate directory');
  if(fs.existsSync(output))throw new Error('Release staging directory already exists');
  const files=releaseFiles(root);
  for(const relative of files){
    const source=path.join(root,...relative.split('/'));
    if(!fs.lstatSync(source).isFile())throw new Error('Missing release input: '+relative);
  }
  fs.mkdirSync(output,{recursive:true});
  for(const relative of files){
    const target=path.join(output,...relative.split('/'));fs.mkdirSync(path.dirname(target),{recursive:true});fs.copyFileSync(path.join(root,...relative.split('/')),target);
  }
  const app=path.join(output,'claude-niang'),packageInfo=JSON.parse(fs.readFileSync(path.join(app,'package.json'),'utf8'));
  const manifestPath=path.join(app,'extension','manifest.json'),manifest=JSON.parse(fs.readFileSync(manifestPath,'utf8'));
  manifest.version=packageInfo.version;manifest.compatibility.runtimes.node='>=20.0.0';
  fs.writeFileSync(manifestPath,JSON.stringify(manifest,null,2)+'\n');
  fs.mkdirSync(path.join(app,'extension','server'),{recursive:true});
  fs.copyFileSync(path.join(app,'runtime','mcp.mjs'),path.join(app,'extension','server','index.mjs'));
  fs.copyFileSync(path.join(app,'runtime','shared.mjs'),path.join(app,'extension','server','shared.mjs'));
  fs.copyFileSync(path.join(output,'LICENSE'),path.join(app,'extension','LICENSE'));
  const info={name:packageInfo.name,version:packageInfo.version,refreshMode:'manual',platforms:['win32'],containsUserState:false};
  fs.writeFileSync(path.join(output,'release-info.json'),JSON.stringify(info,null,2)+'\n');
  return {...info,files:files.length+3,output};
}
const stableVersion=/^(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)$/;
const sha256=data=>createHash('sha256').update(data).digest('hex');
const assetNames=version=>['claude-niang-v'+version+'-windows.zip','claude-niang-v'+version+'-windows.zip.sha256','claude-niang-usage.mcpb'];
export function validateReleaseMetadata(root,tag){
  const read=name=>fs.readFileSync(path.join(root,name),'utf8').replace(/^\uFEFF/,'');
  const {version}=JSON.parse(read('claude-niang/package.json'));
  if(!stableVersion.test(version) || tag!=='v'+version)throw new Error('Release tag must be exactly vX.Y.Z and match package.json; suffixes are not allowed');
  if(JSON.parse(read('claude-niang/extension/manifest.json')).version!==version)throw new Error('Extension manifest version does not match package.json');
  const readme=read('README.md'),readmeVersions=[...readme.matchAll(/\*\*当前程序版本：([^*]+)\*\*/g)];
  if(readmeVersions.length!==1 || readmeVersions[0][1]!==version)throw new Error('README current version does not match package.json');
  const links=[...readme.matchAll(/https:\/\/github\.com\/Gryphus-Triune\/Claude-Niang\/releases\/(?:tag|download)\/([^/\s)"#?]+)/g)];
  if(links.some(match=>match[1]!==tag) || readme.includes('https://github.com/Gryphus-Triune/Claude-Niang/releases/latest/download/'))throw new Error('README release links must use the exact current version tag');
  if([...readme.matchAll(/claude-niang-v([^\s/"`]+)-windows\.zip/g)].some(match=>match[1]!==version))throw new Error('README ZIP filenames must match package.json');
  if([...readme.matchAll(/img\.shields\.io\/badge\/Release-v([0-9.]+)-/g)].some(match=>match[1]!==version))throw new Error('README release badge must match package.json');
  const lines=read('CHANGELOG.md').split(/\r?\n/),heading=new RegExp('^## '+version.replace(/\./g,'\\.')+'(?:\\s|$)');
  const starts=lines.flatMap((line,index)=>heading.test(line)?[index]:[]);
  if(starts.length!==1)throw new Error('CHANGELOG must contain exactly one section for '+version);
  const start=starts[0]+1,following=lines.findIndex((line,index)=>index>=start && /^## /.test(line));
  const notes=lines.slice(start,following<0?lines.length:following).join('\n').trim();
  if(!notes)throw new Error('Release notes must not be empty');
  return {version,tag,notes};
}
export function verifyReleaseAssets(dir,version,expectedMcpbSha256){
  const names=assetNames(version),entries=fs.readdirSync(dir,{withFileTypes:true});
  if(entries.length!==3 || entries.some(entry=>!entry.isFile() || !names.includes(entry.name)))throw new Error('Release directory must contain exactly the ZIP, its SHA256 file and the MCPB');
  const assets=names.map(name=>{const file=path.join(dir,name),data=fs.readFileSync(file);return {name,file,size:data.length,sha256:sha256(data)};});
  if(assets.some(asset=>asset.size===0))throw new Error('Release assets must not be empty');
  const checksum=fs.readFileSync(assets[1].file,'utf8').trim().split(/\s+/);
  if(checksum.length!==2 || checksum[0].toLowerCase()!==assets[0].sha256 || checksum[1]!==names[0])throw new Error('ZIP checksum does not match the release archive');
  if(!/^[a-f0-9]{64}$/.test(expectedMcpbSha256??'') || expectedMcpbSha256!==assets[2].sha256)throw new Error('MCPB checksum does not match the entry extracted from the release ZIP');
  return assets;
}
function newerVersion(version,latestTag){
  const previous=/^v(\d+\.\d+\.\d+)(?:-repack\.[1-9]\d*)?$/.exec(latestTag??'');
  if(!previous)return false; // Do not replace an unrecognized manually chosen Latest.
  const a=version.split('.').map(BigInt),b=previous[1].split('.').map(BigInt);
  for(let i=0;i<3;i++){if(a[i]!==b[i])return a[i]>b[i];}
  return false;
}
export async function publishRelease({metadata,assets,sha,repository,event,ref,request}){
  if(event!=='workflow_dispatch' || ref!=='refs/heads/main' || !/^[a-f0-9]{40}$/.test(sha??'') || !/^[\w.-]+\/[\w.-]+$/.test(repository??''))throw new Error('Releases must be dispatched from main at a full commit SHA');
  const {version,tag,notes}=metadata,expected=assetNames(version);
  if(!stableVersion.test(version) || tag!=='v'+version || assets.length!==3 || new Set(assets.map(a=>a.name)).size!==3 || assets.some(a=>!expected.includes(a.name)))throw new Error('Invalid release metadata or asset set');
  const api='/repos/'+repository,title='Claude 娘 '+tag+' · Windows';
  const body=notes+'\n\n<!-- claude-niang-release '+sha+' '+tag+' -->';
  const ownedDraft=value=>value?.draft===true && value.prerelease===false && value.immutable!==true && value.tag_name===tag && value.target_commitish===sha && value.name===title && value.body===body;
  const tagSha=async()=>{
    let object=(await request('GET',api+'/git/ref/tags/'+tag,{allowMissing:true}))?.object;
    for(let depth=0;object?.type==='tag' && depth<5;depth++)object=(await request('GET',api+'/git/tags/'+object.sha))?.object;
    if(object && object.type!=='commit')throw new Error('Release tag does not resolve to a commit');
    return object?.sha??null;
  };
  const existingSha=await tagSha();
  if(existingSha && existingSha!==sha)throw new Error('Existing tag points to a different commit; it will not be moved');
  let release=null;
  for(let page=1;page<=20;page++){
    const rows=await request('GET',api+'/releases?per_page=100&page='+page);
    for(const item of rows.filter(item=>item.tag_name===tag)){if(release)throw new Error('Duplicate releases exist for this tag');release=item;}
    if(rows.length<100)break;
    if(page===20)throw new Error('Release history is too large to verify safely');
  }
  if(release && !ownedDraft(release))throw new Error('An existing published release or unowned/modified draft uses this tag; nothing will be overwritten');
  if(release && !existingSha)throw new Error('Existing draft has lost its tag; restore and verify it manually');
  if(!existingSha)await request('POST',api+'/git/refs',{json:{ref:'refs/tags/'+tag,sha}});
  if(!release)release=await request('POST',api+'/releases',{json:{tag_name:tag,target_commitish:sha,name:title,body,draft:true,prerelease:false,make_latest:'false'}});
  const assertOwnedDraft=async()=>{
    const current=await request('GET',api+'/releases/'+release.id);
    if(current?.id!==release.id || !ownedDraft(current))throw new Error('Release was published or its draft was modified; stop without further changes');
  };
  const uploads=new URL(release.upload_url.split('{')[0]);
  if(uploads.origin!=='https://uploads.github.com' || uploads.pathname!==api+'/releases/'+release.id+'/assets')throw new Error('Unexpected GitHub asset upload URL');
  const existing=await request('GET',api+'/releases/'+release.id+'/assets?per_page=100');
  if(existing.length>3 || new Set(existing.map(a=>a.name)).size!==existing.length || existing.some(a=>!expected.includes(a.name)))throw new Error('Draft has unexpected assets; inspect it manually');
  for(const asset of assets){
    const old=existing.find(item=>item.name===asset.name);
    if(old?.state==='uploaded' && old.size===asset.size && old.digest==='sha256:'+asset.sha256)continue;
    // Only this workflow's exact draft may replace its own known attachments.
    if(old){await assertOwnedDraft();await request('DELETE',api+'/releases/assets/'+old.id);}
    await assertOwnedDraft();
    await request('POST',uploads.href+'?name='+encodeURIComponent(asset.name),{file:asset.file,sha256:asset.sha256});
  }
  const uploaded=await request('GET',api+'/releases/'+release.id+'/assets?per_page=100');
  if(uploaded.length!==3 || new Set(uploaded.map(a=>a.name)).size!==3 || assets.some(asset=>!uploaded.some(item=>item.name===asset.name && item.state==='uploaded' && item.size===asset.size && item.digest==='sha256:'+asset.sha256)))throw new Error('Uploaded assets failed count, name, size or SHA256 verification; release remains a draft');
  if(await tagSha()!==sha)throw new Error('Tag changed during upload; release remains a draft');
  const latest=await request('GET',api+'/releases/latest',{allowMissing:true});
  await assertOwnedDraft();
  const published=await request('PATCH',api+'/releases/'+release.id,{json:{draft:false,make_latest:!latest || newerVersion(version,latest.tag_name)?'true':'false'}});
  if(published.draft || published.tag_name!==tag)throw new Error('GitHub did not confirm publication');
  return {tag,sha,url:published.html_url,assets:uploaded.map(({name,digest})=>({name,digest}))};
}
async function githubRequest(method,resource,{json,file,sha256:expectedHash,allowMissing=false}={}){
  if(!process.env.GITHUB_TOKEN)throw new Error('GITHUB_TOKEN is required for publishing');
  const url=new URL(resource,'https://api.github.com');
  if(!['https://api.github.com','https://uploads.github.com'].includes(url.origin))throw new Error('Unexpected GitHub API host');
  const headers={Accept:'application/vnd.github+json',Authorization:'Bearer '+process.env.GITHUB_TOKEN,'X-GitHub-Api-Version':'2022-11-28','User-Agent':'claude-niang-release'};
  let body;
  if(file){body=fs.readFileSync(file);if(sha256(body)!==expectedHash)throw new Error('Asset changed after verification');headers['Content-Type']='application/octet-stream';}
  else if(json){body=JSON.stringify(json);headers['Content-Type']='application/json';}
  const response=await fetch(url,{method,headers,body,signal:AbortSignal.timeout(120000)});
  if(response.status===404 && allowMissing)return null;
  if(!response.ok)throw new Error('GitHub '+method+' '+url.pathname+' failed: HTTP '+response.status);
  return response.status===204?null:response.json();
}
if(process.argv[1] && path.resolve(process.argv[1])===fileURLToPath(import.meta.url)){
  const args=process.argv.slice(2),value=key=>args[args.indexOf(key)+1];
  if(!args.includes('--source') || !value('--source'))throw new Error('Use --source with a repository directory');
  const root=path.resolve(value('--source'));
  if(args.includes('--check-release') || args.includes('--publish')){
    const metadata=validateReleaseMetadata(root,value('--tag'));
    if(args.includes('--check-release'))console.log(JSON.stringify(metadata));
    else{
      const sha=process.env.GITHUB_SHA;
      if(execFileSync('git',['rev-parse','HEAD'],{cwd:root,encoding:'utf8'}).trim()!==sha)throw new Error('Checkout does not match the tested workflow commit');
      const assets=verifyReleaseAssets(value('--assets'),metadata.version,process.env.MCPB_SHA256);
      console.log(JSON.stringify(await publishRelease({metadata,assets,sha,repository:process.env.GITHUB_REPOSITORY,event:process.env.GITHUB_EVENT_NAME,ref:process.env.GITHUB_REF,request:githubRequest})));
    }
  }else{
    if(!args.includes('--source') || !args.includes('--output'))throw new Error('Use --source and --output');
    console.log(JSON.stringify(createReleaseTree(root,value('--output'))));
  }
}
