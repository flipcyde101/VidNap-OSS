import test from 'node:test';
import assert from 'node:assert/strict';
import http from 'node:http';
import fs from 'node:fs/promises';
import path from 'node:path';
import {fileURLToPath} from 'node:url';
import {randomUUID} from 'node:crypto';
let createPreviewServer;
try {({createPreviewServer}=await import('../preview/server.mjs'));}
catch(e){if(e.code!=='ERR_MODULE_NOT_FOUND') throw e;}
const root=path.resolve(path.dirname(fileURLToPath(import.meta.url)),'../local-verification');
const h={'x-vidnap-request':'1'};
async function withServer(fn,options={}) {
 assert.equal(typeof createPreviewServer,'function','loopback server must be implemented');
 const fixture=path.join(root,'ui-server-'+randomUUID());await fs.mkdir(fixture,{recursive:true});
 await fs.writeFile(path.join(fixture,'index.html'),'<!doctype html><title>VidNap test fixture</title>');
 await fs.writeFile(path.join(fixture,'saved.mp4'),'0123456789');
 const worker={request:async(method,params)=>{
  if(method==='authorizePeer') return options.authorized!==false;
  if(method==='state') return {jobs:[],activeCount:0,maxConcurrent:2};
  if(method==='media') return {path:path.join(fixture,'saved.mp4'),name:'saved.mp4',bytes:10};
  return {accepted:method==='add',count:params?.links?.length||0};
 }};
 const server=createPreviewServer({webRoot:fixture,mediaRoot:fixture,worker});
 await new Promise((resolve,reject)=>{server.once('error',reject);server.listen(0,'127.0.0.1',resolve)});
 const port=server.address().port;
 const req=(target,method='GET',headers={},body='')=>new Promise((resolve,reject)=>{
  const r=http.request({host:'127.0.0.1',port,path:target,method,headers},res=>{let text='';res.on('data',c=>text+=c);res.on('end',()=>resolve({status:res.statusCode,headers:res.headers,text}))});
  r.on('error',reject);r.end(body);
 });
 try {await fn(req,port);} finally {await new Promise(resolve=>server.close(resolve));await fs.rm(fixture,{recursive:true,force:true});}
}
test('static shell is local and sends framing and privacy protections',()=>withServer(async req=>{
 const r=await req('/');assert.equal(r.status,200);assert.match(r.text,/VidNap test fixture/);assert.match(r.headers['content-security-policy'],/frame-ancestors 'none'/);assert.equal(r.headers['referrer-policy'],'no-referrer');
}));
test('API refuses a client owned by a different Windows user',()=>withServer(async req=>assert.equal((await req('/api/state','GET',h)).status,403),{authorized:false}));
test('API refuses a rebinding Host header',()=>withServer(async req=>assert.equal((await req('/api/state','GET',{...h,host:'evil.invalid'})).status,403)));
test('API refuses an unrelated Origin',()=>withServer(async req=>assert.equal((await req('/api/state','GET',{...h,origin:'https://evil.invalid'})).status,403)));
test('API requires the explicit same-origin application header',()=>withServer(async req=>assert.equal((await req('/api/state')).status,403)));
test('same-user application can read a real state response',()=>withServer(async req=>{
 const r=await req('/api/state','GET',h);assert.equal(r.status,200);assert.equal(JSON.parse(r.text).maxConcurrent,2);assert.equal(r.headers['cache-control'],'no-store');
}));
test('cross-site Fetch metadata cannot access private media',()=>withServer(async req=>assert.equal((await req('/api/media/a/0','GET',{'sec-fetch-site':'cross-site'})).status,403)));
test('unknown RPC methods never reach a worker action',()=>withServer(async req=>{
 const r=await req('/api/command','POST',{...h,'content-type':'application/json'},JSON.stringify({method:'execute',params:{command:'unsafe'}}));assert.equal(r.status,400);
}));
test('oversized command bodies are rejected rather than buffered without bound',()=>withServer(async req=>{
 const r=await req('/api/command','POST',{...h,'content-type':'application/json'},'x'.repeat(65537));assert.equal(r.status,413);
}));
test('an invalid batch fails without partially forwarding it',()=>withServer(async req=>{
 const r=await req('/api/command','POST',{...h,'content-type':'application/json'},JSON.stringify({method:'add',params:{links:['https://example.com/a','file:///D:/secret'],selection:{media:'video',format:'best',formatIds:[]}}}));assert.equal(r.status,400);
}));
test('valid batch is passed to the manager with explicit consent false',()=>withServer(async req=>{
 const r=await req('/api/command','POST',{...h,'content-type':'application/json'},JSON.stringify({method:'add',params:{links:['https://example.com/a'],selection:{media:'video',format:'best',formatIds:[]},consent:false,browser:'firefox'}}));assert.equal(r.status,200);assert.equal(JSON.parse(r.text).count,1);
}));
test('encoded traversal never serves non-allowlisted source files',()=>withServer(async req=>assert.equal((await req('/%2e%2e/VidNap.Preview.ps1')).status,404)));
test('media range requests stream only the requested verified bytes',()=>withServer(async req=>{
 const r=await req('/api/media/a/0','GET',{range:'bytes=2-5','sec-fetch-site':'same-origin'});assert.equal(r.status,206);assert.equal(r.text,'2345');assert.equal(r.headers['content-range'],'bytes 2-5/10');assert.equal(r.headers['cache-control'],'no-store');
}));
test('unsatisfiable media ranges fail without reading the whole file',()=>withServer(async req=>assert.equal((await req('/api/media/a/0','GET',{range:'bytes=30-40','sec-fetch-site':'same-origin'})).status,416)));
