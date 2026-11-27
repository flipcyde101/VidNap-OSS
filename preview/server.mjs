import http from 'node:http';
import fs from 'node:fs/promises';
import {createReadStream} from 'node:fs';
import path from 'node:path';
import {fileURLToPath} from 'node:url';
import {PowerShellRpc} from './rpc.mjs';
import {parseLinks} from './web/view-model.mjs';

const files=new Map([['/','index.html'],['/index.html','index.html'],['/app.mjs','app.mjs'],['/view-model.mjs','view-model.mjs'],['/styles.css','styles.css'],['/manifest.webmanifest','manifest.webmanifest'],['/sw.js','sw.js'],['/offline-policy.mjs','offline-policy.mjs'],['/icons/icon-192.png','icons/icon-192.png'],['/icons/icon-512.png','icons/icon-512.png'],['/icons/apple-touch-icon.png','icons/apple-touch-icon.png'],['/icons/icon.svg','icons/icon.svg']]);
const types={'.html':'text/html; charset=utf-8','.mjs':'text/javascript; charset=utf-8','.js':'text/javascript; charset=utf-8','.css':'text/css; charset=utf-8','.webmanifest':'application/manifest+json','.png':'image/png','.svg':'image/svg+xml','.mp4':'video/mp4','.webm':'video/webm','.m4a':'audio/mp4','.mp3':'audio/mpeg','.wav':'audio/wav','.ogg':'audio/ogg','.opus':'audio/ogg','.flac':'audio/flac'};
const fail=(code,status=400)=>Object.assign(new Error('VidNap request rejected.'),{code,status});
const id=value=>{if(typeof value!=='string'||!/^[A-Za-z0-9-]{1,80}$/.test(value))throw fail('VIDNAP_PREVIEW_JOB');return value};
const index=value=>{if(!Number.isInteger(value)||value<0||value>49)throw fail('VIDNAP_PREVIEW_JOB');return value};
function selection(s) {
 if(!s||typeof s!=='object'||!['video','audio'].includes(s.media))throw fail('VIDNAP_JOB_SELECTION');
 const formats=s.media==='video'?['best','mp4','mkv','webm']:['original','mp3','m4a','flac','wav','opus'];
 if(!formats.includes(s.format)||!Array.isArray(s.formatIds)||s.formatIds.length>2||s.formatIds.some(v=>typeof v!=='string'||!/^[A-Za-z0-9_.:-]{1,128}$/.test(v)))throw fail('VIDNAP_JOB_SELECTION');
 return {Media:s.media,Format:s.format,FormatIds:s.formatIds};
}
function command(body) {
 if(!body||typeof body!=='object'||typeof body.method!=='string'||!body.params||typeof body.params!=='object'||Array.isArray(body.params))throw fail('VIDNAP_PREVIEW_COMMAND');
 const p=body.params;let params;
 const consent=()=>{
  if(p.consent!==undefined&&typeof p.consent!=='boolean')throw fail('VIDNAP_PREVIEW_CONSENT');
  const browser=p.browser||'edge';if(!['edge','chrome','firefox'].includes(browser))throw fail('VIDNAP_BACKEND_BROWSER');
  return {consent:p.consent===true,browser};
 };
 switch(body.method) {
  case 'add':
   if(!Array.isArray(p.links)||!p.links.length||p.links.length>50||p.links.some(x=>typeof x!=='string'))throw fail('VIDNAP_JOB_SOURCE');
   try{params={links:parseLinks(p.links.join('\n')),selection:selection(p.selection),...consent()}}catch(e){throw fail(e.code||'VIDNAP_JOB_SOURCE')};break;
  case 'selection':params={id:id(p.id),selection:selection(p.selection)};break;
  case 'start':params={id:p.id?id(p.id):'',...consent()};break;
  case 'cancel':case 'dismiss':case 'transcript':params={id:id(p.id)};break;
  case 'retry':params={id:id(p.id),...consent()};break;
  case 'captions':
   if(typeof p.language!=='string'||!/^[A-Za-z0-9_-]{1,40}$/.test(p.language)||typeof p.allowAutomatic!=='boolean')throw fail('VIDNAP_CAPTION_LANGUAGE');
   params={id:id(p.id),language:p.language,allowAutomatic:p.allowAutomatic,...consent()};break;
  case 'generate':params={id:id(p.id),index:index(p.index??0)};break;
  case 'export':
   if(!['txt','srt','vtt'].includes(p.format))throw fail('VIDNAP_CAPTION_FORMAT');
   params={id:id(p.id),format:p.format};break;
  case 'reveal':
   if(p.kind==='transcript') {if(!['txt','srt','vtt'].includes(p.format))throw fail('VIDNAP_CAPTION_FORMAT');params={kind:'transcript',id:id(p.id),format:p.format}}
   else params={kind:'media',id:id(p.id),index:index(p.index??0)};break;
  default:throw fail('VIDNAP_PREVIEW_METHOD');
 }
 return {method:body.method,params};
}
async function readBody(req) {
 if(!/^application\/json(?:;|$)/i.test(req.headers['content-type']||''))throw fail('VIDNAP_PREVIEW_CONTENT_TYPE',415);
 let bytes=0;const chunks=[];
 for await(const chunk of req){bytes+=chunk.length;if(bytes>65536)throw fail('VIDNAP_PREVIEW_LIMIT',413);chunks.push(chunk)}
 try{return JSON.parse(Buffer.concat(chunks).toString('utf8'))}catch{throw fail('VIDNAP_PREVIEW_JSON')}
}
function securityHeaders(res) {
 res.setHeader('Content-Security-Policy',"default-src 'self'; script-src 'self'; style-src 'self'; img-src 'self' data:; media-src 'self' blob:; connect-src 'self'; worker-src 'self'; object-src 'none'; base-uri 'none'; frame-ancestors 'none'; form-action 'self'");
 res.setHeader('X-Content-Type-Options','nosniff');res.setHeader('Referrer-Policy','no-referrer');res.setHeader('X-Frame-Options','DENY');
 res.setHeader('Permissions-Policy','camera=(), microphone=(), geolocation=()');
}
function json(res,status,value) {
 const body=JSON.stringify(value);res.writeHead(status,{'content-type':'application/json; charset=utf-8','cache-control':'no-store','content-length':Buffer.byteLength(body)});res.end(body);
}
export function createPreviewServer({webRoot,mediaRoot,worker}) {
 const peers=new WeakMap();
 return http.createServer({maxHeaderSize:16384,requestTimeout:30000,headersTimeout:15000},async(req,res)=>{
  securityHeaders(res);
  try {
   const host=`127.0.0.1:${req.socket.localPort}`;
   if(req.headers.host!==host||req.socket.remoteAddress!=='127.0.0.1')throw fail('VIDNAP_PREVIEW_ORIGIN',403);
   const url=new URL(req.url,`http://${host}`),isApi=url.pathname.startsWith('/api/');
   if(isApi) {
    const origin=req.headers.origin,site=req.headers['sec-fetch-site'];
    if((origin&&origin!==`http://${host}`)||(site&&!['same-origin','none'].includes(site)))throw fail('VIDNAP_PREVIEW_ORIGIN',403);
    if(!peers.has(req.socket))peers.set(req.socket,worker.request('authorizePeer',{clientPort:req.socket.remotePort,serverPort:req.socket.localPort}));
    if(await peers.get(req.socket)!==true)throw fail('VIDNAP_PREVIEW_PEER',403);
    if(!url.pathname.startsWith('/api/media/')&&req.headers['x-vidnap-request']!=='1')throw fail('VIDNAP_PREVIEW_ORIGIN',403);
    if(url.pathname==='/api/state'&&req.method==='GET') {
     const selected=url.searchParams.get('selected')||'';if(selected)id(selected);
     return json(res,200,await worker.request('state',{selectedId:selected}));
    }
    if(url.pathname==='/api/command'&&req.method==='POST') {
     const c=command(await readBody(req));return json(res,200,await worker.request(c.method,c.params));
    }
    const media=url.pathname.match(/^\/api\/media\/([A-Za-z0-9-]{1,80})\/(\d{1,2})$/);
    if(media&&['GET','HEAD'].includes(req.method)) {
     const result=await worker.request('media',{id:media[1],index:index(Number(media[2]))});
     const root=await fs.realpath(mediaRoot),file=await fs.realpath(result.path);
     if(!file.toLowerCase().startsWith(root.toLowerCase()+path.sep))throw fail('VIDNAP_PREVIEW_MEDIA',403);
     const stat=await fs.stat(file);if(!stat.isFile())throw fail('VIDNAP_PREVIEW_MEDIA',403);
     let start=0,end=stat.size-1,status=200;
     if(req.headers.range) {
      const range=/^bytes=(\d+)-(\d*)$/.exec(req.headers.range);
      if(!range)throw fail('VIDNAP_PREVIEW_RANGE',416);
      start=Number(range[1]);end=range[2]?Number(range[2]):end;
      if(!Number.isSafeInteger(start)||!Number.isSafeInteger(end)||start>end||start>=stat.size)throw fail('VIDNAP_PREVIEW_RANGE',416);
      end=Math.min(end,stat.size-1);status=206;res.setHeader('content-range',`bytes ${start}-${end}/${stat.size}`);
     }
     res.writeHead(status,{'content-type':types[path.extname(file).toLowerCase()]||'application/octet-stream','content-length':Math.max(0,end-start+1),'accept-ranges':'bytes','cache-control':'no-store'});
     if(req.method==='HEAD'||stat.size===0)return res.end();
     const stream=createReadStream(file,{start,end});stream.on('error',()=>res.destroy());res.on('close',()=>stream.destroy());return stream.pipe(res);
    }
    throw fail('VIDNAP_PREVIEW_ROUTE',404);
   }
   if(!['GET','HEAD'].includes(req.method))throw fail('VIDNAP_PREVIEW_METHOD',405);
   const relative=files.get(url.pathname);if(!relative)throw fail('VIDNAP_PREVIEW_ROUTE',404);
   let data;try{data=await fs.readFile(path.join(webRoot,relative))}catch{throw fail('VIDNAP_PREVIEW_ROUTE',404)}
   res.writeHead(200,{'content-type':types[path.extname(relative)]||'application/octet-stream','content-length':data.length,'cache-control':'no-cache'});res.end(req.method==='HEAD'?undefined:data);
  } catch(e) {
   if(res.headersSent)return res.destroy();
   const code=typeof e.code==='string'&&/^[A-Z][A-Z0-9_]{0,63}$/.test(e.code)?e.code:'VIDNAP_PREVIEW_OPERATION';
   json(res,e.status||(['VIDNAP_DUPLICATE','VIDNAP_PREVIEW_BUSY'].includes(code)?409:500),{error:{code}});
  }
 });
}

async function main() {
 const configuration=process.argv[2];
 if(process.platform!=='win32'||!configuration||!/^D:\\/i.test(configuration))throw fail('VIDNAP_PREVIEW_CONFIG');
 const info=await fs.stat(configuration);if(info.size>65536)throw fail('VIDNAP_PREVIEW_CONFIG');
 const config=JSON.parse(await fs.readFile(configuration,'utf8'));
 if(config.schemaVersion!==1||[config.applicationRoot,config.dataRoot,config.mediaRoot].some(p=>typeof p!=='string'||!/^D:\\/i.test(p)))throw fail('VIDNAP_PREVIEW_CONFIG');
 const worker=new PowerShellRpc({script:path.join(config.applicationRoot,'VidNap.Preview.ps1'),configuration,dataRoot:config.dataRoot});
 worker.ready.catch(()=>{});
 const server=createPreviewServer({webRoot:path.join(config.applicationRoot,'preview/web'),mediaRoot:config.mediaRoot,worker});
 await new Promise((resolve,reject)=>{server.once('error',reject);server.listen(0,'127.0.0.1',resolve)});
 const url=`http://127.0.0.1:${server.address().port}/`;
 await fs.writeFile(path.join(path.dirname(configuration),'preview-address.json'),JSON.stringify({url,pid:process.pid,workerPid:worker.child.pid,configuration,startedUtc:new Date().toISOString()},null,2),{flag:'wx'});
 process.stdout.write(`VIDNAP_PREVIEW_LISTENING ${url}\n`);
 const close=()=>{server.close();worker.close()};process.on('SIGINT',close);process.on('SIGTERM',close);
}
if(process.argv[1]&&path.resolve(process.argv[1])===fileURLToPath(import.meta.url))main().catch(()=>{process.stderr.write('VIDNAP_PREVIEW_START_FAILED\n');process.exitCode=1});
