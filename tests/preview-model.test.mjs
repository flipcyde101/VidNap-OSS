import test from 'node:test';
import assert from 'node:assert/strict';

let m;
try { m=await import('../preview/web/view-model.mjs'); }
catch(e) { if(e.code==='ERR_MODULE_NOT_FOUND') m={}; else throw e; }

for(const [jobs,want] of [[[],'compact'],[[{id:'a'}],'compact'],[[{id:'a'},{id:'b'}],'queue'],[[{id:'a'},{id:'b',dismissed:true}],'compact']]) {
 test(`adaptive layout uses ${want} for ${JSON.stringify(jobs)}`,()=>assert.equal(m.adaptiveMode?.(jobs),want));
}
test('newline links are normalized and identical inputs deduplicated',()=>{
 assert.deepEqual(m.parseLinks?.(' https://example.com/a\n\nhttps://example.com/b\nhttps://example.com/a '),['https://example.com/a','https://example.com/b']);
});
for(const input of ['file:///D:/secret','https://user:pass@example.com/a','javascript:alert(1)','not a URL']) {
 test(`unsafe input is rejected: ${input.split(':')[0]}`,()=>assert.throws(()=>m.parseLinks?.(input),/URL/));
}
test('too many links fail atomically rather than truncating',()=>assert.throws(()=>m.parseLinks?.(Array.from({length:51},(_,i)=>`https://example.com/${i}`).join('\n')),/50/));
const now=Date.parse('2026-11-04T19:00:00Z');
test('measured transfer ETA is distinct from unavailable overall ETA',()=>{
 const v=m.progressView?.({state:'Running',phase:'Download',bytes:216000000,totalBytes:300000000,rateBytesPerSecond:12000000,elapsedSeconds:18,heartbeatUtc:'2026-11-04T19:00:00Z',currentStep:2,completedSteps:1,remainingSteps:4,totalSteps:5},now);
 assert.equal(v?.percent,72); assert.equal(v?.etaSeconds,7); assert.equal(v?.overallEtaSeconds,null); assert.match(v?.etaLabel||'',/transfer/i);
});
test('unknown total is not rendered as zero percent or an ETA',()=>{
 const v=m.progressView?.({state:'Running',phase:'Download',bytes:1000,totalBytes:null,rateBytesPerSecond:500,heartbeatUtc:'2026-11-04T19:00:00Z'},now);
 assert.equal(v?.percent,null); assert.equal(v?.etaSeconds,null); assert.match(v?.etaReason||'',/total/i);
});
test('an estimated byte total is labeled and does not become an exact percentage',()=>{
 const v=m.progressView?.({state:'Running',phase:'Download',bytes:50,totalBytes:100,totalEstimated:true,rateBytesPerSecond:10,heartbeatUtc:'2026-11-04T19:00:00Z'},now);
 assert.equal(v?.percent,null);assert.match(v?.bytesLabel||'',/estimated/i);
});
test('the progress meter labels combined transfer bytes as the whole download',()=>{
 const v=m.progressView({state:'Running',phase:'Download',byteScope:'Download',bytes:840000,totalBytes:1000000},now);
 assert.equal(v.percent,84);assert.match(v.bytesLabel,/whole download/i);
 assert.match(v.meterValueText,/84 percent of the whole download/i);
});
test('a whole-download ETA is anchored to the latest byte advance, not the UI refresh',()=>{
 const p={state:'Running',phase:'Download',byteScope:'Download',bytes:600,totalBytes:1000,rateBytesPerSecond:100,lastAdvanceUtc:'2026-11-04T19:00:00Z'};
 assert.equal(m.progressView(p,now).etaSeconds,4);
 assert.equal(m.progressView(p,now+2000).etaSeconds,2);
 assert.equal(m.progressView(p,now+5000).etaSeconds,null);
 assert.equal(m.progressView({...p,activityState:'Waiting'},now).etaSeconds,null);
});
test('unpaired progress is explicitly scoped to the current stream',()=>{
 const v=m.progressView({state:'Running',phase:'Download',byteScope:'Stream',bytes:10,totalBytes:100},now);
 assert.match(v.bytesLabel,/current stream/i);assert.match(v.meterValueText,/10 percent of the current stream/i);
 const finished=m.progressView({state:'Running',phase:'Download',byteScope:'Stream',bytes:100,totalBytes:100},now);
 assert.match(finished.etaReason,/next stream/i);
});
test('an identified download with an unknown stream size has no overall percentage',()=>{
 const v=m.progressView({state:'Running',phase:'Download',byteScope:'Download',bytes:400000,totalBytes:null,rateBytesPerSecond:10000},now);
 assert.equal(v.percent,null);assert.match(v.bytesLabel,/whole download.*total unknown/i);
});
test('saved size comes from the final file, never the last stream or transfer total',()=>{
 const v=m.progressView({state:'Completed',phase:'Probe',bytes:200000,totalBytes:1000000,savedBytes:1024},now);
 assert.equal(v.percent,100);assert.equal(v.bytesLabel,'Saved 1.0 KiB');
 assert.equal(v.bytesTitle,`${(1024).toLocaleString()} bytes`);assert.match(v.meterValueText,/saved 1\.0 KiB/i);
 assert.equal(m.progressView({state:'Completed',phase:'Probe',bytes:200000,totalBytes:200000},now).bytesLabel,'Saved file size unavailable');
});
test('a finished operation does not say a previously measured rate never existed',()=>{
 assert.equal(m.progressView?.({state:'Completed',phase:'Probe'},now)?.rateLabel,'No active transfer');
});
test('a stale heartbeat invalidates an otherwise measurable ETA',()=>{
 const v=m.progressView?.({state:'Running',phase:'Download',bytes:100,totalBytes:1000,rateBytesPerSecond:100,heartbeatUtc:'2026-11-04T18:59:40Z'},now);
 assert.equal(v?.activity,'Disconnected'); assert.equal(v?.etaSeconds,null);
});
test('verification never claims transfer completion is overall completion',()=>{
 const v=m.progressView?.({state:'Verifying',phase:'Probe',bytes:100,totalBytes:100,rateBytesPerSecond:100,heartbeatUtc:'2026-11-04T19:00:00Z'},now);
 assert.equal(v?.percent,null); assert.equal(v?.etaSeconds,null); assert.match(v?.stage||'',/verif/i);
});
test('completed transfer counters stay visible while tracks are being merged',()=>{
 const v=m.progressView({state:'Processing',phase:'Download',byteScope:'Download',bytes:100,totalBytes:100},now);
 assert.equal(v.percent,null);assert.match(v.stage,/processing/i);assert.equal(v.bytesLabel,'Whole download: 100 B / 100 B');
});
test('failed and cancelled jobs stop presenting an active ETA',()=>{
 for(const state of ['Failed','Cancelled']) assert.equal(m.progressView?.({state,phase:'Download',bytes:50,totalBytes:100,rateBytesPerSecond:10},now)?.etaSeconds,null);
});
test('generation shows only observed model progress and names its step ETA',()=>{
 const v=m.progressView?.({state:'Running',phase:'Generate',stepPercent:25,ratePercentPerSecond:5,durationSeconds:40,heartbeatUtc:'2026-11-04T19:00:00Z'},now);
 assert.equal(v?.percent,25); assert.equal(v?.etaSeconds,15); assert.match(v?.etaLabel||'',/generation/i);assert.equal(v?.overallEtaSeconds,null);
});
test('generation without callback samples has no invented percentage',()=>{
 const v=m.progressView?.({state:'Running',phase:'Generate',stepPercent:null,heartbeatUtc:'2026-11-04T19:00:00Z'},now);
 assert.equal(v?.percent,null);assert.equal(v?.etaSeconds,null);assert.match(v?.etaReason||'',/model|sample/i);
});
const analysis={formats:[
 {formatId:'v1',videoCodec:'h264',audioCodec:null,height:1080,width:1920,frameRate:30,extension:'mp4'},
 {formatId:'v2',videoCodec:'vp9',audioCodec:null,height:2160,width:3840,frameRate:60,extension:'webm'},
 {formatId:'a1',videoCodec:null,audioCodec:'aac',audioBitrateKbps:128,extension:'m4a'},
 {formatId:'a2',videoCodec:null,audioCodec:'opus',audioBitrateKbps:160,extension:'webm'}]};
test('an exact video-only source is paired with an audio stream',()=>{
 const choices=m.formatChoices?.(analysis,'video','auto');
 assert.deepEqual(choices?.find(c=>c.value==='v1')?.formatIds,['v1','a2']);
});
test('compatible MP4 only offers H264 plus AAC without invented transcoding',()=>{
 const choices=m.formatChoices?.(analysis,'video','mp4');
 assert.ok(choices?.some(c=>c.value==='v1'));
 assert.ok(!choices?.some(c=>c.value==='v2'));
 assert.deepEqual(choices?.find(c=>c.value==='v1')?.formatIds,['v1','a1']);
});
test('original audio choices omit combined video streams',()=>{
 assert.deepEqual(m.formatChoices?.(analysis,'audio','original')?.map(c=>c.value),['','a2','a1']);
});
test('error guidance stays useful without reflecting private engine output',()=>{
 const v=m.explainError?.('VIDNAP_OUTPUT_COLLISION');
 assert.match(v?.message||'',/preserv/i); assert.match(v?.recovery||'',/existing/i);
});
test('TLS failure guidance identifies transport rather than suggesting a format change',()=>{
 const v=m.explainError?.('TLS_HANDSHAKE');assert.match(v?.message||'',/TLS|encrypted|connection/i);assert.match(v?.recovery||'',/certificate|verification/i);
});
test('transcript paging bounds the rendered cues while searching the complete transcript',()=>{
 const cues=Array.from({length:1000},(_,i)=>({startMs:i*1000,text:i===999?'unique final phrase':`Line ${i}`}));
 const page=m.transcriptPage?.(cues,'',200);assert.equal(page?.shown.length,200);assert.equal(page?.total,1000);assert.equal(page?.hasMore,true);
 const found=m.transcriptPage?.(cues,'unique final',200);assert.equal(found?.shown.length,1);assert.equal(found?.shown[0].startMs,999000);
});

test('oversized analysis explains the metadata limit instead of blaming the connection',()=>{
 const result=m.explainError('VIDNAP_ANALYSIS_LIMIT');
 assert.match(result.message,/analysis|metadata/i);
 assert.match(result.recovery,/single video|individual video/i);
});
test('stderr-only overflow does not blame oversized source metadata',()=>{
 const result=m.explainError('VIDNAP_PROCESS_STDERR_LIMIT');
 assert.match(result.message,/diagnostic/i);
 assert.doesNotMatch(result.message,/metadata/i);
 assert.match(result.recovery,/retry/i);
});

for(const operation of ['Analyze links','Download','Retry','Get captions']){
 test(`browser consent is consumed once for ${operation}`,()=>{
  const first=m.consumeBrowserConsent?.(true,'firefox');
  assert.deepEqual(first,{request:{consent:true,browser:'firefox'},nextChecked:false});
  const next=m.consumeBrowserConsent?.(first.nextChecked,'firefox');
  assert.deepEqual(next,{request:{consent:false,browser:'firefox'},nextChecked:false});
 });
}
