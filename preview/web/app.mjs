import {adaptiveMode,parseLinks,progressView,formatChoices,formatTime,terminalStates,explainError,transcriptPage,consumeBrowserConsent} from './view-model.mjs';

const $=id=>document.getElementById(id);
const el=(tag,className='',text='')=>{const n=document.createElement(tag);if(className)n.className=className;n.textContent=text;return n};
const text=(node,value)=>{const next=String(value??'');if(node.textContent!==next)node.textContent=next};
const ui={state:null,view:'downloads',selected:'',analysis:new Map(),rows:new Map(),opRows:new Map(),optionsKey:'',historyKey:'',transcriptKey:'',polling:false,connected:false,transcript:null,cueLimit:200,detailsOpen:false,lastAnnouncement:'',lastWarning:''};
const containers=media=>media==='audio'?[['original','Original audio codec'],['mp3','MP3 (lossy conversion)'],['m4a','M4A / AAC'],['flac','FLAC (lossless container)'],['wav','WAV (large PCM)'],['opus','Opus']]:[['best','Automatic container'],['mp4','MP4 compatible'],['mkv','MKV (original codecs)'],['webm','WebM']];
function setOptions(select,items,value='') {
 select.replaceChildren(...items.map(([v,label])=>{const o=el('option','',label);o.value=v;return o}));
 if(items.some(([v])=>v===value))select.value=value;
}
function consent() {const next=consumeBrowserConsent($('browser-consent').checked,$('browser').value);$('browser-consent').checked=next.nextChecked;return next.request;}
function notify(code,extra='') {
 const e=explainError(code);text($('notice-title'),e.message);text($('notice-body'),`${e.recovery}${extra?' '+extra:''} ${code||''}`);$('notice').hidden=false;
}
function announce(value){if(value!==ui.lastAnnouncement){text($('live-status'),value);ui.lastAnnouncement=value}}
async function api(url,options={}) {
 const response=await fetch(url,{...options,headers:{'X-VidNap-Request':'1',...options.headers},cache:'no-store'});
 const value=await response.json();if(!response.ok||value.error)throw Object.assign(new Error('VidNap operation failed.'),{code:value.error?.code||'VIDNAP_PREVIEW_OPERATION'});return value;
}
async function command(method,params={},button=null) {
 if(button)button.disabled=true;
 try {const result=await api('/api/command',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({method,params})});await poll();return result;}
 catch(e){notify(e.code||'VIDNAP_PREVIEW_UNREACHABLE');throw e;}
 finally{if(button)button.disabled=false;}
}
const safely=fn=>event=>{Promise.resolve(fn(event)).catch(()=>{});};

function showView(name) {
 ui.view=name;
 for(const n of ['downloads','history','transcripts','settings'])$(`${n}-view`).hidden=n!==name;
 for(const b of document.querySelectorAll('[data-view]')){if(b.dataset.view===name)b.setAttribute('aria-current','page');else b.removeAttribute('aria-current')}
 updateLayout();
 $('main').scrollTop=0;window.scrollTo({top:0,left:0,behavior:'instant'});
}
function updateLayout() {
 const mode=adaptiveMode(ui.state?.jobs||[]);
 $('workspace').className=`workspace mode-${mode}${ui.view!=='downloads'?' mode-library':''}`;
 const visible=ui.state?.jobs?.filter(j=>!j.dismissed)||[];
 $('nav-count').hidden=visible.length<2;text($('nav-count'),visible.length);
 text($('queue-heading'),visible.length>1?'Queue':'Your download');
 $('empty-state').hidden=visible.length>0;
 $('workspace').classList.toggle('has-jobs',visible.length>0);
 $('start-all').hidden=visible.length<2;
 text($('analyze'),visible.length?'Analyze':'Analyze links');
 $('links').placeholder=visible.length?'Add another media link':'Paste a video or audio link';
 $('new-link-options').hidden=visible.length>0&&!$('links').value.trim();
}
function makeRow(id,operation=false) {
 const li=el('li','job');li.dataset.id=id;
 const head=el('div','job-header'),title=el('button','job-title'),state=el('span','state-label');title.type='button';head.append(title,state);
 const description=el('p','job-description'),meter=el('progress','meter');meter.max=100;
 const metrics=el('div','job-metrics'),bytes=el('span'),rate=el('span'),eta=el('p','job-eta'),steps=el('p','job-steps'),activity=el('p','job-activity'),error=el('p','job-error'),actions=el('div','job-actions');metrics.append(bytes,rate);
 const buttons={};
 for(const [action,label] of operation?[['cancel','Cancel'],['read','Read transcript'],['dismiss','Dismiss']]:[['start','Download'],['cancel','Cancel'],['retry','Retry'],['read','Transcript'],['reveal','Show on D:'],['dismiss','Dismiss']]) {
  const b=el('button',action==='start'?'secondary-button':'quiet',label);b.type='button';b.dataset.action=action;b.dataset.tooltip={cancel:'Stop only this item. Existing and partial files are preserved.',dismiss:'Hide this finished row. Keep its saved files and history.',reveal:'Show this verified output in its D: folder.'}[action]||'';
  b.addEventListener('click',safely(async()=>{
   if(action==='read'){
    if(operation){const op=ui.state.operations.find(o=>o.id===id);if(op?.transcriptId)await loadTranscript(op.transcriptId)}
    else {showView('transcripts');$('transcript-media').value=id;setPlayer(id);renderTranscriptControls()}
    return;
   }
   if(action==='reveal'){await command('reveal',{id,index:0},b);return}
   const params={id,...(['start','retry'].includes(action)?consent():{})};await command(action,params,b);
   if(action==='dismiss'){ui.analysis.delete(id);ui.optionsKey=''}
  }));actions.append(b);buttons[action]=b;
 }
 title.addEventListener('click',safely(async()=>{
  if(operation)return;
  ui.selected=id;ui.detailsOpen=true;ui.optionsKey='';await poll();
 }));
 li.append(head,description,meter,metrics,eta,steps,activity,error,actions);
 return {li,title,state,description,meter,bytes,rate,eta,steps,activity,error,buttons};
}
function renderRow(row,item,operation=false) {
 const p={...item.progress,state:item.state};const view=progressView(p);
 const labels={Draft:'Waiting to analyze',Ready:'Ready',Queued:'Queued',Analyzing:'Analyzing',Running:operation?view.stage:'Downloading',Processing:'Processing',Verifying:'Verifying',Cancelling:'Stopping',Cancelled:'Cancelled',Completed:'Saved',Failed:'Failed',Interrupted:'Resume needed',NeedsReview:'Needs review',NeedsAuthentication:'Sign-in consent needed',NeedsSourceUrl:'Source link needed'};
 row.li.dataset.state=item.state;row.li.dataset.selected=String(item.id===ui.selected);
 text(row.title,operation?(item.kind==='Generate'?'Local transcript generation':'Source captions'):item.title||item.sourceHost||'Media item');
 text(row.state,labels[item.state]||item.state);
 text(row.description,operation?`${item.kind==='Generate'?'Audio remains on this PC':'Text from the source'} · ${view.stage}`:`${item.selection.media==='audio'?'Audio':'Video'} · ${containers(item.selection.media).find(([v])=>v===item.selection.format)?.[1]||item.selection.format}${ui.analysis.get(item.id)?.durationSeconds?` · ${formatTime(ui.analysis.get(item.id).durationSeconds)}`:''}`);
 if(view.percent===null)row.meter.removeAttribute('value');else row.meter.value=view.percent;
 row.meter.setAttribute('aria-label',operation?'Transcript step progress':item.state==='Completed'?'Saved download':p.byteScope==='Download'?'Whole download progress':p.byteScope==='Stream'?'Current stream progress':'Download progress');
 row.meter.setAttribute('aria-valuetext',view.meterValueText);
 text(row.bytes,view.bytesLabel);row.bytes.title=view.bytesTitle;text(row.rate,view.rateLabel);
 text(row.eta,`${view.etaLabel}${view.projectedLocal?` · ~${view.projectedLocal} local (current step only)`:''}. ${view.etaReason}`);
 const counters=p.totalFiles!==undefined?` · Files ${p.verifiedFiles||0}/${p.totalFiles??'unknown'} verified, ${p.savedFiles||0} saved`:'';
 text(row.steps,view.stepsLabel+counters);
 text(row.activity,`${view.stage} · ${view.activity} · Elapsed ${view.elapsedLabel} · Heartbeat ${view.heartbeatLabel}`);
 const failure=item.errorCode?explainError(item.errorCode):null;
 text(row.error,failure?`${failure.message} ${failure.recovery} (${item.errorCode})`:'');row.error.hidden=!failure;
 const running=['Analyzing','Running','Processing','Verifying','Cancelling'].includes(item.state);
 if(row.buttons.start)row.buttons.start.hidden=!['Ready','Queued'].includes(item.state);
 const canCancel=running||['Draft','Ready','Queued','Interrupted','NeedsSourceUrl','NeedsAuthentication'].includes(item.state);
 row.buttons.cancel.hidden = !canCancel;
 row.buttons.cancel.disabled=item.state==='Cancelling';
 if(row.buttons.retry)row.buttons.retry.hidden=!['Failed','Cancelled','NeedsReview','Interrupted','NeedsAuthentication'].includes(item.state);
 row.buttons.read.hidden=operation?!item.transcriptId:item.state!=='Completed';
 if(row.buttons.reveal)row.buttons.reveal.hidden=item.state!=='Completed';
 row.buttons.dismiss.hidden=!terminalStates.has(item.state);
 const idle=!operation&&['Draft','Ready','Queued','Interrupted','NeedsAuthentication','NeedsSourceUrl'].includes(item.state);
 row.meter.hidden=idle;row.bytes.parentElement.hidden=idle||(operation&&item.state==='Completed');row.steps.hidden=idle;row.activity.hidden=idle;
 if(idle)text(row.eta,item.state==='Ready'?'Analysis complete. Choose an export, then download.':item.state==='Draft'?'Waiting for an analysis slot. No transfer has started.':item.state==='NeedsSourceUrl'?'Paste this source link again to restore the row, or cancel it. Its private URL was not saved.':item.state==='Interrupted'?'Stopped after restart. Resume explicitly to analyze and continue.':'Waiting for an available slot or your action. ETA is unavailable until work begins.');
 const announceKey=`${item.id}:${item.state}`;row.li.dataset.announcement=announceKey;
}
function renderRows() {
 const visible=ui.state.jobs.filter(j=>!j.dismissed),ids=new Set(visible.map(j=>j.id));
 for(const [id,r] of ui.rows)if(!ids.has(id)){r.li.remove();ui.rows.delete(id)}
 for(const job of visible){let row=ui.rows.get(job.id);if(!row){row=makeRow(job.id);ui.rows.set(job.id,row);$('jobs').append(row.li)}renderRow(row,job)}
 const opIds=new Set(ui.state.operations.map(o=>o.id));
 for(const [id,r] of ui.opRows)if(!opIds.has(id)){r.li.remove();ui.opRows.delete(id)}
 for(const op of ui.state.operations){let row=ui.opRows.get(op.id);if(!row){row=makeRow(op.id,true);ui.opRows.set(op.id,row);$('operations').append(row.li)}renderRow(row,op,true)}
 $('operations-region').hidden=!ui.state.operations.length;
 const queued=visible.filter(j=>['Draft','Queued'].includes(j.state)).length;
 text($('queue-summary'),`${ui.state.activeCount} active${queued?` · ${queued} waiting`:''} · up to two at once`);
 $('start-all').disabled=!ui.connected||!visible.some(j=>['Draft','Ready','Queued','Analyzing'].includes(j.state));
}
function fillItemQuality() {
 const analysis=ui.analysis.get(ui.selected);const choices=formatChoices(analysis,$('item-media').value,$('item-format').value);
 const value=$('item-quality').value;setOptions($('item-quality'),choices.map(c=>[c.value,c.label]),value);
 const media=$('item-media').value,format=$('item-format').value;
 text($('quality-help'),media==='audio'&&format!=='original'?'Converting cannot restore detail missing from the source. FLAC and WAV may be larger without improving source quality.':format==='mp4'?'Compatible MP4 selects H.264 video and AAC audio when the source provides them.':'Automatic preserves the best available source streams. Exact choices show the source codecs.');
}
function renderInspector() {
 const item=ui.state.jobs.find(j=>j.id===ui.selected&&!j.dismissed);
 const visible=!!item&&(['Ready','Draft'].includes(item.state)||ui.detailsOpen);
 $('inspector').hidden=!visible;$('workspace').classList.toggle('inspector-hidden',!visible);if(!visible)return;
 const a=ui.analysis.get(item.id);text($('selected-title'),item.title);text($('selected-source'),`${item.sourceHost}${a?.durationSeconds?` · ${formatTime(a.durationSeconds)}`:''}${a?` · ${a.formats.length} source formats`:''}`);
 const editable=['Ready','Draft'].includes(item.state)&&!!a;
 $('item-options').hidden=!editable;
 const key=JSON.stringify([item.id,item.state,item.selection,a?.formats.length]);
 if(ui.optionsKey!==key){
  $('item-media').value=item.selection.media;setOptions($('item-format'),containers(item.selection.media),item.selection.format);fillItemQuality();
  $('item-quality').value=item.selection.formatIds[0]||'';ui.optionsKey=key;
 }
 for(const id of ['item-media','item-format','item-quality','apply-options'])$(id).disabled=!editable;
 text($('selected-status'),editable?'Options apply to this item. Apply them before downloading.':'This item keeps its selected export. Active downloads are not changed by new-link defaults.');
 const captions=a?.captions||[];$('caption-options').hidden=!captions.length;
 if(captions.length){const key=captions.map(c=>`${c.language}:${c.automatic}`).join('|');if($('caption-language').dataset.key!==key){
   setOptions($('caption-language'),captions.map(c=>[`${c.language}|${c.automatic?'auto':'manual'}`,`${c.language}${c.automatic?' (source automatic)':' (manual)'}`]));$('caption-language').dataset.key=key;$('allow-automatic').checked=false;
  }}
 const auto=$('caption-language').value.endsWith('|auto');$('get-captions').disabled=!captions.length||(auto&&!$('allow-automatic').checked)||!ui.connected;
}
function renderHistory() {
 const key=JSON.stringify(ui.state.history);if(key===ui.historyKey)return;ui.historyKey=key;
 $('history-empty').hidden=ui.state.history.length>0;$('history-list').replaceChildren();
 for(const h of ui.state.history){
  const li=el('li','history-row'),copy=el('div'),actions=el('div','history-actions');copy.append(el('p','',h.files[0]||'No completed media file'),el('p','help',`${h.result}${h.verification?.length?` · ${h.verification.map(v=>v.Status).join(', ')} structural verification`:''}`));
  if(h.result==='Completed'&&h.files.length){
   const reveal=el('button','quiet','Show on D:');reveal.type='button';reveal.addEventListener('click',safely(()=>command('reveal',{id:h.id,index:0},reveal)));
   const transcript=el('button','secondary-button','Transcript');transcript.type='button';transcript.addEventListener('click',()=>{showView('transcripts');$('transcript-media').value=h.id;setPlayer(h.id);renderTranscriptControls()});actions.append(reveal,transcript);
  }
  li.append(copy,actions);$('history-list').append(li);
 }
 const prior=$('transcript-media').value;
 setOptions($('transcript-media'),[['','Choose a verified download'],...ui.state.history.filter(h=>h.result==='Completed'&&h.files.length).map(h=>[h.id,h.files[0]])],prior);
}
function renderTranscriptControls() {
 const ready=ui.state?.transcription.ready;
 $('generate').disabled=!ui.connected||!ready||!$('transcript-media').value;
 text($('generation-help'),ui.state?.transcription.reason||'Checking local generation prerequisites.');
 if(ui.state){text($('setting-transcription'),`${ui.state.transcription.reason}${ready?` Model: ${ui.state.transcription.model}. Two CPU threads.`:''}`)}
 const key=ui.state?.transcripts.map(t=>t.id).join('|')||'';
 if(key!==ui.transcriptKey){ui.transcriptKey=key;const prior=$('transcript-select').value;setOptions($('transcript-select'),[['','Choose a transcript'],...ui.state.transcripts.slice().reverse().map(t=>[t.id,`${new Date(t.createdUtc).toLocaleString()} · ${t.provenance==='LocalGenerated'?'Local generation':t.provenance==='SourceManual'?'Manual source':'Source automatic'} · ${t.cueCount} cues`])],prior)}
}
function setPlayer(id) {
 const player=$('media-player');
 if(!id){player.removeAttribute('src');player.hidden=true;$('player-help').hidden=true;return}
 const source=`/api/media/${encodeURIComponent(id)}/0`;
 if(player.getAttribute('src')!==source){player.src=source;player.load()}
 player.hidden=false;$('player-help').hidden=false;text($('player-help'),'Playback depends on browser support for the saved original format.');
}
async function loadTranscript(id) {
 showView('transcripts');const result=await command('transcript',{id});ui.transcript=result;ui.cueLimit=200;$('transcript-select').value=id;
 const r=result.record;text($('provenance'),r.provenance==='LocalGenerated'?'Locally generated by the approved model. Review for accuracy.':r.provenance==='SourceAutomatic'?'Automatic captions supplied by the source. Review for accuracy.':'Manual captions supplied by the source.');
 $('transcript-search').disabled=false;$('transcript-search').value='';
 for(const b of document.querySelectorAll('[data-export]'))b.disabled=false;
 if(ui.state.history.some(h=>h.id===r.jobId&&h.result==='Completed')){$('transcript-media').value=r.jobId;setPlayer(r.jobId)}else setPlayer('');
 renderCues();announce(`Transcript opened, ${result.cues.length} cues.`);
}
function renderCues() {
 const query=$('transcript-search').value.trim().toLocaleLowerCase(),cues=ui.transcript?.cues||[];
 const page=transcriptPage(cues,query,ui.cueLimit),shown=page.shown;$('cues').replaceChildren();
 for(const cue of shown){
  const row=el('li','cue'),seek=el('button','',formatTime(cue.startMs/1000)),body=el('p','',cue.text);seek.type='button';seek.disabled=!$('media-player').hasAttribute('src');seek.setAttribute('aria-label',`Play from ${formatTime(cue.startMs/1000)}`);
  seek.addEventListener('click',()=>{const p=$('media-player');p.currentTime=cue.startMs/1000;p.play().catch(()=>{text($('player-help'),'Press Play in the media controls, or use a browser-supported container.')})});row.dataset.start=cue.startMs;row.dataset.end=cue.endMs;row.append(seek,body);$('cues').append(row);
 }
 $('reader-empty').hidden=shown.length>0;
 text($('reader-empty'),ui.transcript?'No cues match this search.':'Choose a saved transcript, or generate one from verified media.');
 text($('cue-count'),ui.transcript?`${shown.length} of ${page.total} ${query?'matching ':''}cues shown`:'');$('more-cues').hidden=!page.hasMore;
}
function render() {
 updateLayout();renderRows();renderInspector();renderHistory();renderTranscriptControls();
 text($('setting-media'),ui.state.mediaRoot);text($('setting-data'),ui.state.dataRoot);text($('storage-label'),`Save to ${ui.state.mediaRoot}`);
 text($('footer-activity'),`${ui.state.activeCount} active · Heartbeat ${new Date(ui.state.heartbeatUtc).toLocaleTimeString([], {hour:'numeric',minute:'2-digit',second:'2-digit'})}`);
 const warning=ui.state.persistenceError||ui.state.diagnosticError;
 if(warning&&warning!==ui.lastWarning){notify(warning);ui.lastWarning=warning}
 const states=ui.state.jobs.filter(j=>!j.dismissed).map(j=>`${j.title}: ${j.state}`).join('. ');announce(states||'Ready for a media link.');
}
async function poll() {
 if(ui.polling)return;
 ui.polling=true;
 try {
  const state=await api(`/api/state${ui.selected?`?selected=${encodeURIComponent(ui.selected)}`:''}`);ui.state=state;ui.connected=true;
  for(const job of state.jobs)if(job.analysis)ui.analysis.set(job.id,job.analysis);
  if(!state.jobs.some(j=>j.id===ui.selected&&!j.dismissed)){ui.selected=state.jobs.find(j=>!j.dismissed)?.id||'';ui.detailsOpen=false}
  $('connection').dataset.connected='true';text($('connection'),'Local worker connected');render();
 }catch(e){ui.connected=false;$('connection').dataset.connected='false';text($('connection'),'Local worker unavailable');$('analyze').disabled=true;$('start-all').disabled=true;$('generate').disabled=true;if(ui.state){renderRows()}else{text($('queue-summary'),`Waiting for the D: worker. No work has started. ${e.code||'Connection unavailable'}`)}}
 finally{ui.polling=false;if(ui.connected)$('analyze').disabled=false;}
}

setOptions($('default-format'),containers('video'),'best');
$('default-media').addEventListener('change',()=>setOptions($('default-format'),containers($('default-media').value),$('default-media').value==='audio'?'original':'best'));
$('links').addEventListener('input',()=>{$('links').style.height='auto';$('links').style.height=`${Math.min(168,Math.max(50,$('links').scrollHeight))}px`;if(ui.state)updateLayout()});
$('links').addEventListener('keydown',e=>{if((e.ctrlKey||e.metaKey)&&e.key==='Enter'){e.preventDefault();$('link-form').requestSubmit()}});
$('link-form').addEventListener('submit',safely(async e=>{
 e.preventDefault();let links;try{links=parseLinks($('links').value)}catch(error){text($('notice-title'),error.message);text($('notice-body'),'Use one ordinary media URL per line. Your input has been preserved.');$('notice').hidden=false;return}
 const result=await command('add',{links,selection:{media:$('default-media').value,format:$('default-format').value,formatIds:[]},...consent()},$('analyze'));
 $('links').value='';$('links').style.height='';ui.selected=result.ids?.[0]||ui.selected;ui.detailsOpen=false;ui.optionsKey='';await poll();
}));
$('start-all').addEventListener('click',safely(()=>command('start',consent(),$('start-all'))));
$('notice-close').addEventListener('click',()=>{$('notice').hidden=true});
for(const b of document.querySelectorAll('[data-view]'))b.addEventListener('click',()=>{showView(b.dataset.view)});
$('item-media').addEventListener('change',()=>{setOptions($('item-format'),containers($('item-media').value),$('item-media').value==='audio'?'original':'best');fillItemQuality()});
$('item-format').addEventListener('change',fillItemQuality);
$('item-options').addEventListener('submit',safely(async e=>{
 e.preventDefault();const choices=formatChoices(ui.analysis.get(ui.selected),$('item-media').value,$('item-format').value),choice=choices.find(c=>c.value===$('item-quality').value);
 if(!choice)return;await command('selection',{id:ui.selected,selection:{media:$('item-media').value,format:$('item-format').value,formatIds:choice.formatIds}},$('apply-options'));ui.optionsKey='';await poll();
}));
$('caption-language').addEventListener('change',renderInspector);$('allow-automatic').addEventListener('change',renderInspector);
$('get-captions').addEventListener('click',safely(async()=>{
 await command('captions',{id:ui.selected,language:$('caption-language').value.split('|')[0],allowAutomatic:$('allow-automatic').checked,...consent()},$('get-captions'));
}));
$('transcript-media').addEventListener('change',()=>{setPlayer($('transcript-media').value);renderTranscriptControls();if(ui.transcript)renderCues()});
$('transcript-select').addEventListener('change',safely(async()=>{if($('transcript-select').value)await loadTranscript($('transcript-select').value)}));
$('generate').addEventListener('click',safely(async()=>{await command('generate',{id:$('transcript-media').value,index:0},$('generate'));showView('downloads')}));
$('transcript-search').addEventListener('input',()=>{ui.cueLimit=200;renderCues()});
$('more-cues').addEventListener('click',()=>{ui.cueLimit+=200;renderCues()});
$('media-player').addEventListener('error',()=>{text($('player-help'),'The browser could not play this saved format. Keep the original file, or use MP4 compatible for a supported source.');$('player-help').hidden=false});
$('media-player').addEventListener('timeupdate',()=>{const ms=$('media-player').currentTime*1000;for(const row of $('cues').children)row.dataset.active=String(ms>=Number(row.dataset.start)&&ms<Number(row.dataset.end))});
for(const button of document.querySelectorAll('[data-export]'))button.addEventListener('click',safely(async()=>{
 const result=await command('export',{id:ui.transcript.record.id,format:button.dataset.export},button);
 const p=$('export-result');p.replaceChildren(el('span','',`Saved on D: ${result.path}`));const reveal=el('button','quiet','Show in folder');reveal.type='button';reveal.addEventListener('click',safely(()=>command('reveal',{kind:'transcript',id:ui.transcript.record.id,format:button.dataset.export},reveal)));p.append(reveal);
}));
function tooltip(target) {
 const tip=$('tooltip');if(ui.tooltipTarget){ui.tooltipTarget.removeAttribute('aria-describedby');ui.tooltipTarget=null}if(!target?.dataset.tooltip){tip.hidden=true;return}
 target.setAttribute('aria-describedby','tooltip');ui.tooltipTarget=target;
 text(tip,target.dataset.tooltip);tip.hidden=false;const r=target.getBoundingClientRect();tip.style.left=`${Math.max(8,Math.min(r.left,window.innerWidth-tip.offsetWidth-8))}px`;tip.style.top=`${Math.max(8,Math.min(r.bottom+8,window.innerHeight-tip.offsetHeight-8))}px`;
}
document.addEventListener('mouseover',e=>tooltip(e.target.closest('[data-tooltip]')));document.addEventListener('focusin',e=>tooltip(e.target.closest('[data-tooltip]')));document.addEventListener('mouseout',()=>{$('tooltip').hidden=true});document.addEventListener('focusout',()=>{$('tooltip').hidden=true});document.addEventListener('keydown',e=>{if(e.key==='Escape')$('tooltip').hidden=true});
window.addEventListener('pageshow',()=>{$('browser-consent').checked=false});
window.addEventListener('beforeunload',e=>{if(ui.state?.activeCount){e.preventDefault();e.returnValue='';}});
if('serviceWorker' in navigator)navigator.serviceWorker.register('/sw.js',{type:'module'}).then(()=>navigator.serviceWorker.ready).then(()=>text($('setting-offline'),'Offline interface is ready. Only static interface files are cached. Private media, API responses, transcripts and source URLs are not cached. The PC worker is still required for downloads and generation.')).catch(()=>text($('setting-offline'),'Offline interface is unavailable in this browser. The live PC worker is required.'));
await poll();setInterval(poll,1000);
