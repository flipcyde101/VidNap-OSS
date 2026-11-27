import test from 'node:test';
import assert from 'node:assert/strict';
import path from 'node:path';
import {PowerShellRpc} from '../preview/rpc.mjs';

test('Windows PowerShell loads its Windows-supplied security module under AllSigned',{
 skip:process.platform!=='win32'||!process.env.VIDNAP_RPC_PROBE_SCRIPT?'Requires the explicitly signed private D: RPC fixture.':false
},async()=>{
 const script=process.env.VIDNAP_RPC_PROBE_SCRIPT;
 const rpc=new PowerShellRpc({script,configuration:script,dataRoot:path.dirname(script)});
 try {
  const r=await rpc.request('probe',{});
  assert.equal(r.loaded,true,'Get-Acl must load without weakening AllSigned');
  assert.ok(r.moduleBase.toLowerCase().startsWith(path.join(process.env.WINDIR,'System32/WindowsPowerShell/v1.0').toLowerCase()),'Use the Windows-supplied module or snap-in, not the rejected Codex module');
 }finally{rpc.close()}
});
