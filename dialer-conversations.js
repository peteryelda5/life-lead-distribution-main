/* Owner-scoped live transcript and reviewable AI call notes. */
(() => {
 'use strict';
 window.createDialerConversations=function(root,options){
  const owner=options.owner;let disposed=false,visible=true,current=null,data=null,flight=false,actionBusy=false,version=0,lastPoll=0,historyOpen=false,summaryKey='';
  const panel=document.createElement('details');panel.className='conversation-panel';panel.open=true;
  panel.innerHTML='<summary><span>Conversation assistant</span><small>Live transcript · AI summary</small></summary><div class="conversation-content"><header><div><strong id="conversationTitle">Your conversation</strong><p id="conversationStatus" role="status">Connect a call to start a transcript.</p></div><button id="conversationHistory">Recent transcripts</button></header><div id="conversationHistoryRows" hidden></div><div id="conversationConsent"><label><input id="conversationAgreed" type="checkbox"> The client agreed to transcription and AI call notes.</label><p>Twilio processes both sides of the call. Transcription and AI usage charges apply. Text is kept for 30 days. Start after consent; stop before collecting payment or other sensitive details.</p></div><div class="conversation-actions"><button id="conversationStart" disabled>Start transcript + summary</button><button id="conversationStop" hidden>Stop transcript</button><button id="conversationSetup" hidden>Prepare AI summaries</button><button id="conversationCurrent" hidden>Back to current call</button></div><div class="conversation-columns"><section><h3>Live conversation <span>Latest 250 statements</span></h3><div id="conversationLines" class="conversation-lines" role="log" aria-label="Live conversation transcript" aria-live="polite"><p>Statements appear here as they are transcribed.</p></div></section><details id="conversationSummarySection" class="conversation-summary" open><summary>AI call summary <small>Review before saving</small></summary><div class="conversation-summary-content"><p id="conversationSummaryState">Available after transcription ends.</p><textarea id="conversationSummary" rows="6" aria-label="Review AI call summary" hidden></textarea><button id="conversationAdd" hidden>Add reviewed summary to lead notes</button></div></details></div><p id="conversationFeedback" role="status"></p></div>';
  const anchor=document.createElement('div');anchor.className='conversation-anchor';root.querySelector('.workspace-toolbar').after(anchor);anchor.append(panel);
  const elements=new Map([...panel.querySelectorAll('[id]')].map(el=>[el.id,el]));const $=id=>elements.get(id),same=()=>{try{return !disposed&&JSON.parse(localStorage.getItem('lld_session')||'null')?.user?.id===owner;}catch{return false;}};
  const key=c=>c?c.kind+':'+c.id:'';
  const summaryHome=panel.querySelector('.conversation-columns');let docked=false,summaryWasOpen=true,inPower=false,homeWasOpen=true;
  function place(){
   const powerHome=root.querySelector('#parallel:not([hidden]) #powerAssistantSlot'),nextPower=!!powerHome;
   if(nextPower!==inPower){if(nextPower){homeWasOpen=panel.open;if(!current&&!data&&!options.getCall()?.active)panel.open=false;}else panel.open=homeWasOpen;inPower=nextPower;}
   const dialog=root.querySelector('#powerConnectedDialog[open]'),slot=dialog?.querySelector('#powerConversationSlot'),target=slot||dialog?.querySelector('#powerDialogBody')||powerHome||anchor;
   const summaryTarget=slot?dialog.querySelector('#powerSummarySlot'):null,nextDocked=!!slot;
   if(nextDocked!==docked){if(nextDocked){summaryWasOpen=$('conversationSummarySection').open;$('conversationSummarySection').open=!!data?.conversation?.summary;panel.open=true;}else $('conversationSummarySection').open=summaryWasOpen;docked=nextDocked;}
   if(panel.parentNode!==target)target.append(panel);
   const destination=summaryTarget||summaryHome;if($('conversationSummarySection').parentNode!==destination)destination.append($('conversationSummarySection'));
   panel.classList.toggle('is-docked',nextDocked);
  }
  async function request(action,extra={}){if(!same())throw Error('Your account changed. Reload the dialer.');const s=await options.getSession();if(!same())throw Error('Account changed.');const r=await fetch('/api/dialer/conversations',{method:'POST',headers:{'Content-Type':'application/json',Authorization:'Bearer '+s.access_token},body:JSON.stringify({action,...extra}),signal:AbortSignal.timeout(45000),cache:'no-store'});const d=await r.json();if(!same())throw Error('Account changed.');if(!r.ok)throw Error(d.error||'Conversation tools unavailable.');return d;}
  function switchCall(c){current=c?{...c}:null;data=null;version++;summaryKey='';$('conversationLines').replaceChildren();$('conversationSummary').value='';$('conversationAgreed').checked=false;$('conversationFeedback').textContent='';lastPoll=0;}
  function controls(){
   if(!same())return;place();const live=options.getCall(),matches=key(current)===key(live),row=data?.conversation;
   $('conversationTitle').textContent=row?.phone||current?.label||'Your conversation';
   const states={starting:'Starting transcription…',live:'Live · You and Client',stopped:'Transcription ended',error:'Transcription needs attention'};
   $('conversationStatus').textContent=row?states[row.state]+(row.errorCode?' · '+row.errorCode:''):live?.active&&matches?'Connected · transcript is off':'Connect a call to start a transcript.';
   $('conversationConsent').hidden=!!row;$('conversationStart').hidden=!!row;
   $('conversationStart').disabled=actionBusy||flight||!matches||!live?.active||!$('conversationAgreed').checked;
   $('conversationStop').hidden=!row||!['starting','live'].includes(row.state);$('conversationStop').disabled=actionBusy;
   $('conversationSetup').hidden=owner!=='8139e230-055d-4247-8133-684ed817b4fa'||!!row||!!live?.active;$('conversationSetup').disabled=actionBusy;
   $('conversationCurrent').hidden=!historyOpen||!live;$('conversationAdd').hidden=!row?.summary||!row.leadId||!options.canAddNotes(row.leadId);$('conversationAdd').disabled=!!live?.active||actionBusy;
  }
  function render(){
   const row=data?.conversation,lines=data?.lines||[],box=$('conversationLines');
   const nearBottom=box.scrollHeight-box.scrollTop-box.clientHeight<50;const existing=new Map([...box.querySelectorAll('[data-sequence]')].map(el=>[el.dataset.sequence,el]));
   let position=0;for(const line of lines){let item=existing.get(String(line.sequence));if(item){existing.delete(String(line.sequence));if(box.children[position]!==item)box.insertBefore(item,box.children[position]||null);position++;continue;}item=document.createElement('article');item.dataset.sequence=line.sequence;item.dataset.speaker=line.speaker;const label=document.createElement('strong'),words=document.createElement('p');label.textContent=(line.speaker==='agent'?'You':'Client')+' · '+new Date(line.spoken_at).toLocaleTimeString();words.textContent=line.content;item.append(label,words);box.insertBefore(item,box.children[position]||null);position++;}
   for(const el of existing.values())el.remove();if(nearBottom)box.scrollTop=box.scrollHeight;
   $('conversationSummary').hidden=!row?.summary;
   if(row?.summary&&summaryKey!==row.id){$('conversationSummary').value=row.summary;summaryKey=row.id;$('conversationSummarySection').open=true;}
   $('conversationSummaryState').textContent=row?.summary?'AI draft — check names, dates, and next steps.':row?.state==='error'?'The transcript did not finish normally. A summary may be unavailable.':row?.state==='stopped'?'Generating the summary. This can take a few minutes.':'Available after transcription ends.';
   controls();
  }
  async function poll(force=false){
   if(!same()){dispose();return;}place();const live=options.getCall();
   if(live?.id&&!historyOpen&&key(live)!==key(current))switchCall(live);
   if(current&&key(current)===key(live))current={...current,...live};controls();
   const now=Date.now();if(!current||flight||actionBusy||!visible||document.hidden||!panel.open||(!force&&now-lastPoll<(data?.conversation?.state==='live'||live?.active?2500:10000)))return;
   flight=true;lastPoll=now;const ticket=version,c={...current};
   try{const d=await request('state',{kind:c.kind,id:c.id});if(ticket===version&&same()){data=d;render();}}
   catch(e){if(ticket===version&&same())$('conversationFeedback').textContent=e.message;}
   finally{flight=false;controls();}
  }
  async function work(action,extra={}){
   if(actionBusy)return;actionBusy=true;const ticket=version,c=current?{...current}:null;controls();$('conversationFeedback').textContent='';
   try{const d=await request(action,{...(c?{kind:c.kind,id:c.id}:{}),...extra});if(!same()||ticket!==version)return;if(action==='setup')$('conversationFeedback').textContent=d.ready?'AI summaries are ready. Start a transcript on a connected call.':'Setup is unavailable.';else{data=d;render();}}
   catch(e){if(same())$('conversationFeedback').textContent=e.message;}finally{actionBusy=false;controls();}
  }
  $('conversationAgreed').onchange=controls;$('conversationStart').onclick=()=>{if(!$('conversationStart').disabled)work('start',{consent:true,acceptCharges:true});};
  $('conversationStop').onclick=()=>work('stop');$('conversationSetup').onclick=()=>work('setup');
  $('conversationAdd').onclick=()=>{const row=data?.conversation,text=$('conversationSummary').value.trim();if(!row?.leadId||!text)return;if(options.addNotes(row.leadId,'[AI call summary — reviewed]\n'+text))$('conversationFeedback').textContent='Added to the notes draft. Save the lead outcome to keep it.';else $('conversationFeedback').textContent='Open this lead and finish the call before adding the summary.';};
  $('conversationHistory').onclick=async()=>{if(actionBusy)return;try{const d=await request('list'),box=$('conversationHistoryRows');box.replaceChildren();box.hidden=false;for(const c of d.conversations||[]){const b=document.createElement('button');b.textContent=c.phone+' · '+new Date(c.created_at).toLocaleString();b.onclick=()=>{historyOpen=true;switchCall({kind:c.kind,id:c.source_id,label:c.phone,active:false});box.hidden=true;poll(true);};box.append(b);}if(!box.children.length)box.textContent='No transcripts yet.';}catch(e){$('conversationFeedback').textContent=e.message;}};
  $('conversationCurrent').onclick=()=>{historyOpen=false;switchCall(options.getCall());poll(true);};panel.ontoggle=()=>{if(panel.open)poll(true);};
  const timer=setInterval(()=>poll(),1500);root.addEventListener('powerlayoutchange',place);
  function dispose(){if(disposed)return;disposed=true;clearInterval(timer);root.removeEventListener('powerlayoutchange',place);$('conversationSummarySection').remove();panel.remove();anchor.remove();}
  controls();return {dispose,changed:()=>{place();controls();},setVisible(value){visible=value;if(value)poll(true);}};
 };
})();
