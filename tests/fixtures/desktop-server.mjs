import http from 'node:http';
import fs from 'node:fs/promises';
import path from 'node:path';
import {spawn} from 'node:child_process';
import {fileURLToPath} from 'node:url';

// The launcher passes the expected receipt path for its ownership checks.
// Select it from this fixture's own generated runs; never use the CLI string
// or a configuration field as a filesystem or executable path.
const appRoot=path.resolve(path.dirname(fileURLToPath(import.meta.url)),'..');
const dataRoot=path.join(path.dirname(appRoot),'state'),mediaRoot=path.join(path.dirname(appRoot),'media');
const runtimeRoot=path.join(dataRoot,'Runtime');
const samePath=(a,b)=>typeof a==='string'&&typeof b==='string'&&a.toLowerCase()===b.toLowerCase();
if(process.platform!=='win32'||!/^D:\\/i.test(appRoot)||!samePath(await fs.realpath(runtimeRoot),runtimeRoot))throw new Error('Invalid desktop test runtime.');
const runEntries=await fs.readdir(runtimeRoot,{withFileTypes:true});
const candidates=runEntries.filter(entry=>entry.isDirectory()&&/^run-[a-f0-9]{32}$/.test(entry.name))
 .map(entry=>path.join(runtimeRoot,entry.name,'preview-config.json'));
const configPath=candidates.find(candidate=>samePath(candidate,process.argv[2]));
if(!configPath)throw new Error('VIDNAP_FIXTURE_RUN_PATH: Unknown desktop test run.');
const runDirectory=path.dirname(configPath);
const configStat=await fs.lstat(configPath);
if(!configStat.isFile()||configStat.size>65536||!samePath(await fs.realpath(configPath),configPath))throw new Error('Invalid desktop test configuration.');
const config=JSON.parse(await fs.readFile(configPath,'utf8'));
if(config.schemaVersion!==1||!samePath(config.applicationRoot,appRoot)||!samePath(config.dataRoot,dataRoot)||!samePath(config.mediaRoot,mediaRoot))throw new Error('VIDNAP_FIXTURE_ROOTS: Desktop test roots do not match.');
const workerScript=path.join(appRoot,'VidNap.Preview.ps1');
if(!(await fs.lstat(workerScript)).isFile()||!samePath(await fs.realpath(workerScript),workerScript))throw new Error('Invalid desktop test worker.');
const output=await fs.open(path.join(runDirectory,'fixture-worker.stdout.txt'),'wx'),errors=await fs.open(path.join(runDirectory,'fixture-worker.stderr.txt'),'wx');
const child=spawn(path.join(process.env.WINDIR,'System32/WindowsPowerShell/v1.0/powershell.exe'),['-NoProfile','-NonInteractive','-ExecutionPolicy','AllSigned','-WindowStyle','Hidden','-File',workerScript,'-Configuration',configPath],{windowsHide:true,detached:true,stdio:['ignore',output.fd,errors.fd]});
await output.close();await errors.close();
child.unref();
const server=http.createServer(async(req,res)=>{
 res.setHeader('connection','close');
 if(req.method==='POST'&&req.url==='/fixture-stop'){await fs.writeFile(path.join(runDirectory,'fixture-worker-stop'),'stop');res.end('stopped');server.close();return}
 if(req.method==='POST'&&req.url==='/fixture-orphan'){res.end('orphaned');server.close();return}
 res.setHeader('content-type','application/json');
 if(config.fixtureUnready){res.writeHead(503);res.end('{"error":"waiting"}');return}
 res.end(JSON.stringify({dataRoot,mediaRoot,maxConcurrent:2,activeCount:0}));
});
await new Promise(resolve=>server.listen(0,'127.0.0.1',resolve));
await fs.writeFile(path.join(runDirectory,'preview-address.json'),JSON.stringify({url:`http://127.0.0.1:${server.address().port}/`,pid:process.pid,workerPid:child.pid,configuration:configPath,startedUtc:new Date().toISOString()}),{flag:'wx'});
