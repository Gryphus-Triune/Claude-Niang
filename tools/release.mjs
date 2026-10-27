import fs from 'node:fs';
import path from 'node:path';
import {fileURLToPath} from 'node:url';

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
if(process.argv[1] && path.resolve(process.argv[1])===fileURLToPath(import.meta.url)){
  const args=process.argv.slice(2),value=key=>args[args.indexOf(key)+1];
  if(!args.includes('--source') || !args.includes('--output'))throw new Error('Use --source and --output');
  console.log(JSON.stringify(createReleaseTree(value('--source'),value('--output'))));
}
