#!/usr/bin/env node
// Stands in for runtime/claude-browser.ps1 in tests: same arguments, same output file.
import fs from 'node:fs';
const args=process.argv.slice(2);
const value=name=>{const i=args.indexOf(name);return i>=0?args[i+1]:null;};
const out=value('-OutFile');
const counter=process.env.FAKE_COUNTER_FILE;
if(counter){let n=0;try{n=Number(fs.readFileSync(counter,'utf8'))||0;}catch{};fs.writeFileSync(counter,String(n+1));}
if(process.env.FAKE_ARGS_FILE)fs.writeFileSync(process.env.FAKE_ARGS_FILE,JSON.stringify(args));
const input=JSON.parse(fs.readFileSync(process.env.FAKE_BUNDLE_FILE,'utf8'));
const selected=value('-PreferredOrg')??value('-OrgId')??input.selectedOrg;
const bundle=JSON.stringify(input.byOrganization?.[selected]??input);
setTimeout(()=>{if(out)fs.writeFileSync(out,bundle);process.exit(0);},Number(process.env.FAKE_DELAY_MS||20));
