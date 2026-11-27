export const terminalStates=new Set(['Completed','Failed','Cancelled','NeedsReview']);

export function adaptiveMode(jobs=[]) {
 return jobs.filter(j=>!j.dismissed).length>1?'queue':'compact';
}

export function consumeBrowserConsent(checked,browser) {
 return {request:{consent:checked===true,browser},nextChecked:false};
}

export function parseLinks(text) {
 const lines=String(text).split(/\r?\n/).map(s=>s.trim()).filter(Boolean);
 if(lines.length>50) throw new Error('Add at most 50 URLs at a time.');
 if(!lines.length) throw new Error('Paste a media URL first.');
 return [...new Set(lines.map(value=>{
  let url;
  try {url=new URL(value);} catch {throw new Error('Every line must be an HTTP or HTTPS URL.');}
  if(value.length>8192 || /[\x00-\x20]/.test(value) || !['http:','https:'].includes(url.protocol) || url.username || url.password)
   throw new Error('Use an HTTP or HTTPS URL without embedded credentials.');
  return url.href;
 }))];
}

const finite=n=>typeof n==='number'&&Number.isFinite(n);
export function formatBytes(n,largePrecision=0) {
 if(!finite(n)||n<0) return 'Unknown';
 const units=['B','KiB','MiB','GiB','TiB']; let i=0;
 while(n>=1024&&i<units.length-1) {n/=1024;i++;}
 return `${n.toFixed(i?(n<10?1:largePrecision):0)} ${units[i]}`;
}
export function formatTime(n) {
 if(!finite(n)||n<0) return 'Unknown';
 n=Math.floor(n); const h=Math.floor(n/3600),m=Math.floor(n%3600/60),s=n%60;
 return h?`${h}:${String(m).padStart(2,'0')}:${String(s).padStart(2,'0')}`:`${m}:${String(s).padStart(2,'0')}`;
}
export function shortDuration(n) {
 if(!finite(n)||n<0) return 'Unknown';
 n=Math.ceil(n);
 return n<60?`${n}s`:n<3600?`${Math.floor(n/60)}m ${n%60}s`:`${Math.floor(n/3600)}h ${Math.ceil(n%3600/60)}m`;
}

export function progressView(p={},now=Date.now()) {
 const active=!terminalStates.has(p.state)&&p.state!=='Idle';
 const heartbeat=Date.parse(p.heartbeatUtc||'');
 const stale=active&&finite(heartbeat)&&now-heartbeat>10000;
 const waiting=['Draft','Ready','Queued','Interrupted','NeedsSourceUrl','NeedsAuthentication'].includes(p.state)||p.activityState==='Waiting';
 const transferring=p.phase==='Download'&&p.state==='Running';
 const known=finite(p.totalBytes)&&p.totalBytes>0;
 const bytes=finite(p.bytes)&&p.bytes>=0?p.bytes:0;
 const rate=finite(p.rateBytesPerSecond)&&p.rateBytesPerSecond>0?p.rateBytesPerSecond:null;
 const scope=p.byteScope==='Download'?'whole download':'current stream';
 const stalled=p.activityState==='Stalled';
 const generating=p.phase==='Generate'&&p.state==='Running';
 const generatedPercent=finite(p.stepPercent)&&p.stepPercent>=0&&p.stepPercent<=100?p.stepPercent:null;
 const percent=transferring&&known&&!p.totalEstimated?Math.min(100,Math.max(0,bytes/p.totalBytes*100)):generating?generatedPercent:p.state==='Completed'?100:null;
 const lastAdvance=Date.parse(p.lastAdvanceUtc||'');
 const transferSeconds=transferring&&known&&!p.totalEstimated&&rate&&bytes<p.totalBytes?(p.totalBytes-bytes)/rate:null;
 const finish=transferSeconds!==null&&transferSeconds<=31536000?(finite(lastAdvance)?Math.min(lastAdvance,now):now)+transferSeconds*1000:null;
 const etaSeconds=stale||stalled||waiting?null:finish!==null&&finish>now?(finish-now)/1000:generating&&generatedPercent!==null&&finite(p.ratePercentPerSecond)&&p.ratePercentPerSecond>0?(100-generatedPercent)/p.ratePercentPerSecond:null;
 const stages={Analyze:'Analyzing source',Download:'Downloading',Probe:'Verifying saved media',PrepareAudio:'Preparing audio',Generate:'Generating transcript',Captions:'Downloading captions',Finalize:'Saving verified output'};
 let stage=stages[p.phase]||p.phase||p.state||'Ready';
 if(p.state==='Processing'&&p.phase==='Download') stage='Processing downloaded media';
 if(terminalStates.has(p.state)) stage={Completed:'Saved',Failed:'Operation failed',Cancelled:'Cancelled',NeedsReview:'Saved bytes need review'}[p.state];
 let etaReason='Overall estimate unavailable; verification and finalization still remain.';
 if(stale) etaReason='Connection to the worker is stale. Waiting for a new heartbeat.';
 else if(stalled) etaReason='No recent transfer progress. Waiting for the source.';
 else if(waiting) etaReason=transferring?'Waiting for fresh transfer progress.':'ETA starts after this item begins and enough progress is measured.';
 else if(transferring&&!known) etaReason='The source has not supplied a total size.';
 else if(transferring&&p.totalEstimated) etaReason='The transfer total is estimated; an exact total is needed for a completion estimate.';
 else if(transferring&&bytes>=p.totalBytes) etaReason=scope==='whole download'?'All reported transfer bytes received. Waiting for processing and verification.':'All reported bytes for this stream received. Waiting for the next stream or processing.';
 else if(transferring&&!rate) etaReason='Collecting enough transfer samples to measure a rate.';
 else if(transferring&&etaSeconds===null) etaReason='Waiting for a fresh, reliable transfer estimate.';
 else if(generating&&etaSeconds===null) etaReason='The model is warming up or has not supplied enough progress samples.';
 else if(p.state==='Completed') etaReason='Transfer, verification and finalization finished.';
 else if(terminalStates.has(p.state)) etaReason='No active completion estimate.';
 const projected=etaSeconds===null?null:new Date(now+etaSeconds*1000);
 const finishedDownload=p.state==='Completed'&&(p.byteScope||p.phase==='Probe'||p.phase==='Download');
 const savedSize=finishedDownload&&Number.isSafeInteger(p.savedBytes)&&p.savedBytes>0;
 const bytesTitle=savedSize?`${p.savedBytes.toLocaleString()} bytes`:'';
 const byteCounter=`${p.byteScope?(scope[0].toUpperCase()+scope.slice(1)+': '):''}${formatBytes(bytes,1)} / ${known?`${formatBytes(p.totalBytes,1)}${p.totalEstimated?' estimated':''}`:'total unknown'}`;
 const bytesLabel=finishedDownload?(savedSize?`Saved ${formatBytes(p.savedBytes,1)}`:'Saved file size unavailable'):
  generating?`${generatedPercent===null?'Audio progress unknown':`${Math.round(generatedPercent)}% of audio`}${finite(p.durationSeconds)?` · ${formatTime(p.durationSeconds)} source`:''}`:byteCounter;
 const meterValueText=finishedDownload?`${bytesLabel}${savedSize?` (${bytesTitle})`:''}. Transfer and verification finished.`:
  percent===null?`${stage}. Percentage unavailable.`:`${Math.floor(percent)} percent of the ${transferring?scope:'current step'}.`;
 return {percent,etaSeconds,overallEtaSeconds:null,etaLabel:etaSeconds===null?'ETA unavailable':`${generating?'Current generation':scope==='whole download'?'Download transfer':'Current stream transfer'}: about ${shortDuration(etaSeconds)} left`,etaReason,
  projectedLocal:projected?projected.toLocaleTimeString([], {hour:'numeric',minute:'2-digit',second:'2-digit'}):null,
  activity:stale?'Disconnected':stalled?'Stalled':waiting?'Waiting':terminalStates.has(p.state)?p.state:'Active',stage,
  bytesLabel,bytesTitle,meterValueText,
  rateLabel:terminalStates.has(p.state)?'No active transfer':generating&&finite(p.ratePercentPerSecond)?`${p.ratePercentPerSecond.toFixed(1)}% of audio/s`:rate?`${formatBytes(rate)}/s`:'Rate not yet measured',elapsedLabel:formatTime(p.elapsedSeconds||0),
  stepsLabel:p.totalSteps?`Step ${p.currentStep} of ${p.totalSteps} · ${p.completedSteps} complete, ${p.remainingSteps} remaining`:'Waiting to begin',
  heartbeatLabel:finite(heartbeat)?new Date(heartbeat).toLocaleTimeString([], {hour:'numeric',minute:'2-digit',second:'2-digit'}):'Waiting for worker'};
}

export function formatChoices(analysis,media='video',container='auto') {
 const formats=analysis?.formats||[];
 const audioOnly=formats.filter(f=>f.audioCodec&&!f.videoCodec).sort((a,b)=>(b.audioBitrateKbps||0)-(a.audioBitrateKbps||0));
 const choices=[{value:'',label:media==='audio'?'Best available audio':'Best available quality',formatIds:[]}];
 const video=formats.filter(f=>f.videoCodec).sort((a,b)=>(b.height||0)-(a.height||0)||(b.frameRate||0)-(a.frameRate||0));
 for(const f of media==='audio'?audioOnly:video) {
  const ids=[f.formatId];
  if(media==='video') {
   if(container==='mp4'&&(f.videoCodec!=='h264'||(f.audioCodec&&f.audioCodec!=='aac'))) continue;
   if(container==='webm'&&f.extension!=='webm') continue;
   if(!f.audioCodec) {
    const audio=audioOnly.find(a=>container==='mp4'?a.audioCodec==='aac':container==='webm'?a.extension==='webm':true);
    if(audio) ids.push(audio.formatId);
    else if(formats.some(a=>a.audioCodec)) continue;
   }
  }
  const desc=media==='audio'?`${f.audioCodec.toUpperCase()}${f.audioBitrateKbps?` · ${Math.round(f.audioBitrateKbps)} kb/s`:''}`:
   `${f.height?`${f.height}p`:'Video'}${f.frameRate?` · ${Math.round(f.frameRate)} fps`:''} · ${f.videoCodec.toUpperCase()}`;
  choices.push({value:f.formatId,label:desc,formatIds:ids});
 }
 return choices;
}

export function explainError(code='') {
 const messages={
  TLS_HANDSHAKE:['The encrypted connection closed during the TLS handshake.','Check the source service, network and supported engine version. Keep certificate verification and Windows protections enabled. Changing export format cannot fix a TLS failure.'],
  TLS_CERTIFICATE:['The source certificate could not be verified.','Check the PC clock and the legitimate network trust configuration. Do not disable certificate verification.'],
  AUTH_DATABASE_LOCKED:['The selected browser sign-in database is locked.','Close that browser yourself if appropriate, then retry with explicit consent. VidNap will not force it closed.'],
  AUTH_DECRYPTION:['The browser sign-in could not be decrypted.','Keep browser security enabled. Try the source without browser sign-in or use a supported owner-approved access method.'],
  NETWORK_TIMEOUT:['The source connection timed out.','Check connectivity and service availability, then retry. Partial and existing files are preserved.'],
  DISK_FULL:['D: does not have enough free space.','Free appropriate space yourself, then retry. VidNap does not switch to C: or delete existing media.'],
  EXTRACTOR_UNSUPPORTED:['The engine does not recognize this source URL.','Use the original media page URL. A site-specific update may be needed; universal support is not guaranteed.'],
  VIDNAP_ANALYSIS_LIMIT:['This source returned more metadata than VidNap can safely analyze.','If this is a playlist, try a single video link. If the error persists for one video, share this error code.'],
  VIDNAP_PROCESS_STDERR_LIMIT:['The engine produced too much diagnostic output while analyzing this link.','Retry once. If it happens again, share this error code.'],
  VIDNAP_OUTPUT_COLLISION:['Existing and new bytes were preserved.','Review the existing destination and staged file. No file was overwritten.'],
  VIDNAP_OUTPUT_VERIFICATION:['The saved streams did not match the selected source evidence.','Keep the staged file for review, analyze again, and choose a supported format.'],
  VIDNAP_OUTPUT_MISSING:['The engine exited without reporting a saved media file.','Analyze the source again and review source access. No completed download is claimed.'],
  VIDNAP_BACKEND_STATE_NOT_SAVED:['Queue state could not be saved on D:.','Check the D: drive and available space before starting more work.'],
  VIDNAP_TRANSCRIPTION_PREREQUISITE:['Local transcription prerequisites are missing.','Configure the separately approved engine and model on D:. Nothing is downloaded automatically.'],
  VIDNAP_TRANSCRIPTION_APPROVAL:['Local generation is not configured for this preview.','Source captions still work. An approved local engine and model are required for generation.'],
  VIDNAP_PREVIEW_PEER:['This request is not from the same Windows user.','Open VidNap locally under the account that started this preview.'],
  VIDNAP_DUPLICATE:['This source and export are already queued or saved.','Use its existing row or review the saved file before downloading another copy.'],
  VIDNAP_SOURCE_REQUIRED:['The private source link was not restored.','Paste the source link again. Browser sign-in consent is never restored.']
 };
 const [message,recovery]=messages[code]||['The operation could not finish. Saved and partial files were preserved.','Check the source, connection and D: storage, then retry. Site or network restrictions cannot be bypassed by changing export format.'];
 return {code,message,recovery};
}

export function transcriptPage(cues,query='',limit=200) {
 const search=String(query).trim().toLocaleLowerCase();
 const matching=search?cues.filter(c=>c.text.toLocaleLowerCase().includes(search)):cues;
 const count=Math.min(20000,Math.max(1,Math.floor(limit)||200));
 return {shown:matching.slice(0,count),total:matching.length,hasMore:matching.length>count};
}
