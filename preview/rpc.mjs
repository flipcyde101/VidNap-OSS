import {spawn} from 'node:child_process';
import path from 'node:path';

export class PowerShellRpc {
 constructor({script,configuration,dataRoot}) {
  this.pending=new Map();this.nextId=0;this.buffer='';this.closed=false;
  this.ready=new Promise((resolve,reject)=>{this.readyResolve=resolve;this.readyReject=reject});
  const temp=path.join(dataRoot,'temp');
  const environment=Object.fromEntries(Object.entries(process.env).filter(([key])=>!['psmodulepath','temp','tmp','xdg_cache_home','deno_dir'].includes(key.toLowerCase())));
  Object.assign(environment,{PSModulePath:path.join(process.env.WINDIR,'System32/WindowsPowerShell/v1.0/Modules'),TEMP:temp,TMP:temp,XDG_CACHE_HOME:path.join(dataRoot,'cache'),DENO_DIR:path.join(dataRoot,'deno-cache')});
  this.child=spawn(path.join(process.env.WINDIR,'System32/WindowsPowerShell/v1.0/powershell.exe'),
   ['-NoLogo','-NoProfile','-NonInteractive','-ExecutionPolicy','AllSigned','-WindowStyle','Hidden','-File',script,'-Configuration',configuration],
   {cwd:path.dirname(script),windowsHide:true,stdio:['pipe','pipe','pipe'],env:environment});
  this.child.stdin.on('error',()=>this.fail('VIDNAP_PREVIEW_CLOSED'));
  this.child.stdout.setEncoding('utf8');
  this.child.stdout.on('data',chunk=>this.receive(chunk));
  this.child.stderr.on('data',()=>{}); // Never persist arbitrary engine or PowerShell output.
  this.child.on('error',()=>this.fail('VIDNAP_PREVIEW_START'));
  this.child.on('exit',()=>this.fail('VIDNAP_PREVIEW_CLOSED'));
  this.readyTimer=setTimeout(()=>{this.fail('VIDNAP_PREVIEW_START_TIMEOUT');this.close()},45000);
 }
 receive(chunk) {
  this.buffer+=chunk;
  if(Buffer.byteLength(this.buffer,'utf8')>12*1024*1024){this.fail('VIDNAP_PREVIEW_RESPONSE_LIMIT');this.close();return}
  let end;
  while((end=this.buffer.indexOf('\n'))>=0) {
   const line=this.buffer.slice(0,end).trim();this.buffer=this.buffer.slice(end+1);
   if(!line) continue;
   let value;try {value=JSON.parse(line);}catch {this.fail('VIDNAP_PREVIEW_PROTOCOL');this.close();return}
   if(value.event==='ready') {clearTimeout(this.readyTimer);this.readyResolve();continue;}
   if(value.event==='fatal'){this.fail('VIDNAP_PREVIEW_START');continue;}
   const wait=this.pending.get(value.id);if(!wait) continue;
   clearTimeout(wait.timer);this.pending.delete(value.id);
   if(value.ok) wait.resolve(value.result);
   else wait.reject(Object.assign(new Error('VidNap operation failed.'),{code:value.error?.code||'VIDNAP_PREVIEW_OPERATION'}));
  }
 }
 async request(method,params={}) {
  await this.ready;
  if(this.closed) throw Object.assign(new Error('Backend closed.'),{code:'VIDNAP_PREVIEW_CLOSED'});
  if(this.pending.size>=64) throw Object.assign(new Error('Backend busy.'),{code:'VIDNAP_PREVIEW_BUSY'});
  const id=++this.nextId;const line=JSON.stringify({id,method,params})+'\n';
  if(Buffer.byteLength(line)>65536) throw Object.assign(new Error('Command too large.'),{code:'VIDNAP_PREVIEW_LIMIT'});
  return new Promise((resolve,reject)=>{
   const timer=setTimeout(()=>{this.pending.delete(id);reject(Object.assign(new Error('Backend response timed out.'),{code:'VIDNAP_PREVIEW_TIMEOUT'}))},30000);
   this.pending.set(id,{resolve,reject,timer});
   this.child.stdin.write(line,'utf8',error=>{if(error){clearTimeout(timer);this.pending.delete(id);reject(Object.assign(new Error('Backend input closed.'),{code:'VIDNAP_PREVIEW_CLOSED'}))}});
  });
 }
 fail(code) {
  this.closed=true;clearTimeout(this.readyTimer);
  const error=Object.assign(new Error('VidNap local backend is unavailable.'),{code});
  this.readyReject(error);
  for(const p of this.pending.values()){clearTimeout(p.timer);p.reject(error)}this.pending.clear();
 }
 close() {
  this.child.stdin.end();
  const timer=setTimeout(()=>{if(this.child.exitCode===null)this.child.kill()},5000);timer.unref();
 }
}
