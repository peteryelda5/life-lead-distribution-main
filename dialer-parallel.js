'use strict';
// Keep the existing factory name so cached portal shells remain compatible.
window.createParallelPilot=function(root,options){
 const stored=()=>{try{return JSON.parse(localStorage.getItem('lld_session')||'null');}catch{return null;}};
 const owner=stored()?.user?.id;if(!owner)return null;
 let disposed=false,shown=false,busy=false,loading=false,stopping=false,polling=false,launching=false,wrap=false;
 let health=null;
 let device=null,call=null,id=null,token=null,generation=0,muted=false,last=null,editor=null,canCall=false;
 let folders=[],rows=[],states=[],offset=0,count=0,folder=0,batchReady=false,presentedWinner=null,connectedAt=0,endedAt=0,returnFocus=null;
 const batchOutcomes=new Map();let reviewedBatch=null;
 let deviceKey=null,deviceFault=false,nextTimer=null,nextAt=0,continuous=false,sessionStarted=false,lastMeasured=null,pace=3;const retryAfter=new Map();
 const selected=new Map(),known=new Map(),cards=new Map(),returned=new Map();
 const button=document.createElement('button');button.dataset.view='parallel';button.textContent='Power Dialer';button.setAttribute('aria-selected','false');button.onclick=()=>options.openView('parallel');root.querySelector('.workspace-tabs').append(button);
 const panel=document.createElement('main');panel.id='parallel';panel.className='secondary-view power-workspace power-simple';panel.hidden=true;
 panel.innerHTML=`
 <header class="power-heading"><h2>Power Dialer</h2><span id="powerConnection" class="power-status" data-state="idle">Ready to start</span></header>
 <div id="powerSetup" class="power-notice" hidden>Activate your calling plan and caller ID to start. <button id="powerBilling">Open Numbers &amp; billing</button></div>
 <div class="power-session-strip"><span id="powerQueueSummary">All my leads · All states · 3 lines</span><button id="powerChange" aria-expanded="false" aria-controls="powerQueueDrawer">Change</button><button id="powerSettingsToggle" aria-expanded="false" aria-controls="powerSettings">⚙ Settings</button></div>
 <section id="powerSettings" class="power-panel power-settings" hidden aria-label="Calling settings"><div class="power-toolbar"><label>Calling from<select id="powerCaller"><option value="">Loading your numbers…</option></select></label><label>Lines per batch<select id="powerLines"><option value="1">1 line</option><option value="2">2 lines</option><option value="3" selected>3 lines</option></select></label><details class="power-detection"><summary>Machine detection <span>On</span></summary><div><select id="powerMode" aria-label="Answer connection" hidden><option value="human" selected>Answering-machine detection on</option></select><p id="powerModeHint" class="power-hint">Human answers connect automatically. Detected machines are skipped. An unclear pickup connects if you are free, with detection labeled uncertain; otherwise it is flagged for follow-up. Other lines keep ringing until someone connects. Detection can add a short delay.</p></div></details></div><label class="power-adaptive"><input id="powerAdaptive" type="checkbox"> Reduce lines after overlapping answers</label><button id="powerReliability" type="button">Connection report</button><div id="powerReliabilityReport" role="status" hidden></div><p id="powerPoolInfo" class="power-hint" hidden></p><p class="power-hint">Automatic machine detection · 30-minute automatic retry delay · Call again for immediate manual redial · 5 attempts per number per day</p><input id="powerContinuous" type="checkbox" hidden></section>
 <details id="powerQueueDrawer" class="power-queue-drawer"><summary id="powerChooseTitle">Choose leads <span id="powerQueueCount"></span></summary><div class="power-filters"><label>Lead folder<select id="powerFolder"><option value="0">All my leads</option></select></label><div class="power-state-filter"><span>States to dial</span><details id="powerStates"><summary id="powerStateSummary">All states</summary><div class="power-state-popover"><div id="powerStateChoices"></div><button id="powerApplyStates">Apply states</button></div></details></div><label class="power-search">Search this page<input id="powerSearch" type="search" placeholder="Name, phone or state" aria-label="Search leads"></label></div>
 <section class="power-panel power-queue" aria-labelledby="powerQueueTitle"><div class="power-section-title"><div><h3 id="powerQueueTitle">Lead queue</h3><p id="powerCount">0 selected</p></div><button id="powerReload">Refresh leads</button></div>

 <div class="power-queue-actions"><button id="powerSelect">Select this page</button><button id="powerClear">Clear selection</button><span id="powerSelectionHelp">Choose the leads you want to call.</span></div>
 <div class="power-table-scroll" tabindex="0" role="region" aria-label="Lead queue table"><table class="power-table"><thead><tr><th scope="col"><span class="power-sr-only">Select</span></th><th scope="col">Name</th><th scope="col">Phone</th><th scope="col">State</th><th scope="col">Status</th><th scope="col">Folder</th><th scope="col"><span class="power-sr-only">Lead details</span></th></tr></thead><tbody id="powerRows" class="power-rows"></tbody></table></div><div class="power-pagination"><span id="powerPage"></span><div><button id="powerPrevious">Previous</button><button id="powerNext">Next</button></div></div></section></details>
 <section class="power-calling" aria-label="Calling workspace"><h3 id="powerCallingTitle" class="power-sr-only">Calling</h3>
 <p id="powerMessage" class="power-message" role="status" aria-live="polite">Choose leads to get started.</p>
 <div class="power-columns"><section class="power-panel power-lead"><div class="power-section-title power-lead-section-title"><h3>Lead information</h3></div><div id="powerEmpty" class="power-empty"><span class="power-empty-icon">☎</span><h3>Your next conversation starts here</h3><p>Choose your leads, then press Start dialing once. The person who answers appears here.</p></div><div id="powerLead" hidden><header class="power-lead-heading"><span id="powerAvatar" class="power-avatar" aria-hidden="true"></span><div class="power-lead-identity"><h2 id="powerName"></h2><p id="powerContact"></p></div><div class="power-lead-connection"><span id="powerLeadBadge" class="power-status">Ready</span><time id="powerCallTime" aria-label="Call duration" hidden>00:00</time></div></header><p id="powerConnectedState" class="power-connected-state" role="status"></p><dl id="powerQuickDetails" class="power-quick-details"></dl><details id="powerAllDetails" class="power-all-details"><summary>View all lead details</summary><dl id="powerDetails"></dl></details><details id="powerPreviousNotes" class="power-previous-notes"><summary>Previous notes</summary><p id="powerPreviousText"></p></details><div id="powerConversationSlot"></div><h3 id="powerOutcomeTitle">Choose an outcome to continue</h3><select id="powerOutcome" hidden><option value="">Choose an outcome</option><option value="appointment_follow_up">Appointment / follow-up</option><option value="call_back">Call back</option><option value="not_interested">Not interested</option><option value="dead_number">Dead number</option></select><div id="powerQuickOutcomes" class="power-quick-outcomes" aria-label="Call outcome"><button type="button" data-power-outcome="call_back">Callback</button><button type="button" data-power-outcome="not_interested">Not interested</button><button type="button" data-power-outcome="appointment_follow_up">Appointment / follow-up</button><button type="button" id="powerMore" aria-expanded="false" aria-controls="powerMoreOutcomes">More ···</button><div id="powerMoreOutcomes" hidden><button type="button" data-power-outcome="dead_number">Dead number</button></div></div><p id="powerOutcomeHelp" class="power-hint">Selecting an outcome saves your notes and resumes dialing.</p><div id="powerSummarySlot"></div><div class="power-save-actions"><button id="powerSave">Save outcome</button><button id="powerSaveNext" class="primary">Save &amp; Call Next</button></div><p id="powerSaveMessage" role="status" aria-live="polite"></p></div></section><section class="power-panel power-notes-panel" aria-label="Notes and script"><div class="power-notes-tabs" role="tablist" aria-label="Conversation tools"><button id="powerNotesTab" role="tab" aria-selected="true" aria-controls="powerNotesPane">Notes</button><button id="powerScriptTab" role="tab" aria-selected="false" aria-controls="powerScriptPane" tabindex="-1">Script</button></div><div id="powerNotesPane" role="tabpanel" aria-labelledby="powerNotesTab"><label for="powerNotes" class="power-sr-only">Call notes</label><textarea id="powerNotes" rows="10" maxlength="10000" placeholder="Add details from your conversation…" disabled></textarea><p class="power-hint">Notes save with your outcome.</p></div><div id="powerScriptPane" role="tabpanel" aria-labelledby="powerScriptTab" hidden><label for="powerScriptSelect" class="power-sr-only">Agency script</label><select id="powerScriptSelect"></select><h3 id="powerScriptTitle"></h3><div id="powerScriptBody"></div></div></section></div>
 <div class="power-results-strip"><div id="powerCards" class="power-lines" aria-label="Call results"></div><button id="powerViewQueue" type="button">View queue</button></div>
 <div id="powerRedials" class="power-redials" aria-label="Call a lead again" hidden></div>
 <footer class="power-batch-bar"><div class="power-session-copy"><p id="powerSessionState" role="status">Start once. Calls advance automatically.</p><p id="powerBatchHint"></p></div><div class="power-actions"><button id="powerStart" class="primary" disabled>Start dialing</button><button id="powerPause" class="primary" hidden>Pause dialing</button><button id="powerMute" disabled hidden>Mute</button><button id="powerStop" class="danger" disabled hidden>End call</button><button id="powerEndSession" hidden>End session</button></div></footer>
 <details class="power-result-details"><summary>All results &amp; follow-ups</summary><div id="powerReturned" class="power-notice" role="status" hidden></div><div id="powerSkipped" class="power-notice" hidden></div><section id="powerBatchReview" class="power-batch-review" hidden aria-label="Batch outcomes"><div><h3>Finish this batch</h3><p>Choose outcomes below. Keep automatic results for lines you did not speak with.</p></div><div id="powerBatchOutcomes"></div><button id="powerBatchSaveNext" class="primary">Save &amp; Call Next 3</button><p id="powerBatchSaveMessage" role="status"></p></section>
 <section class="power-history"><h3>Recent batches</h3><button id="powerRefreshHistory">Refresh batches</button><div id="powerHistory"></div></section></details>
 <button id="powerReopen" hidden>View current lead</button><dialog id="powerConnectedDialog" class="power-connected-dialog" aria-modal="false" aria-labelledby="powerConnectedTitle"><header class="power-dialog-header"><h2 id="powerConnectedTitle">Connected call</h2><div class="power-dialog-actions"><button id="powerDialogExpand" aria-expanded="false" aria-label="Expand call panel">Expand</button><button id="powerDialogMinimize" aria-label="Minimize call panel">Minimize</button></div></header><div id="powerDialogBody"></div><footer class="power-dialog-footer"><p id="powerDialogMessage" class="power-message" role="status" aria-live="polite"></p><div class="power-dialog-controls"><button id="powerDialogMute" disabled>Mute</button><button id="powerDialogStop" class="danger" disabled>End call</button><button id="powerDialogSave" class="primary" disabled>Save outcome</button></div></footer></dialog>
 </section><div id="powerAssistantSlot"></div>`;
 root.append(panel);const $=name=>panel.querySelector('#'+name);
 const dialog=$('powerConnectedDialog'),leadPanel=panel.querySelector('.power-lead'),columns=panel.querySelector('.power-columns');
 function sidebarLayout(){root.classList.toggle('power-view-active',!panel.hidden);if(panel.hidden&&dialog.open){minimizeLead();return;}root.classList.toggle('power-sidebar-open',dialog.open&&!panel.hidden);root.dispatchEvent(new Event('powerlayoutchange'));}
 function restoreLeadCard(){if(leadPanel.parentElement!==columns)columns.append(leadPanel);dialog.classList.remove('is-expanded');$('powerDialogExpand').setAttribute('aria-expanded','false');$('powerDialogExpand').textContent='Expand';$('powerDialogExpand').setAttribute('aria-label','Expand call panel');sidebarLayout();controls();}
 function minimizeLead(){const focusInside=dialog.contains(document.activeElement);if(dialog.open)dialog.close();restoreLeadCard();if(focusInside){const target=!$('powerReopen').hidden?$('powerReopen'):returnFocus;if(target?.isConnected)target.focus({preventScroll:true});}}
 function showConnectedLead(){if(!editor)return;sidebarLayout();controls();}
 dialog.addEventListener('close',restoreLeadCard);dialog.addEventListener('cancel',e=>{e.preventDefault();minimizeLead();});dialog.addEventListener('keydown',e=>{if(e.key==='Escape'){e.preventDefault();minimizeLead();}});
 $('powerDialogExpand').onclick=()=>{const expanded=dialog.classList.toggle('is-expanded');$('powerDialogExpand').setAttribute('aria-expanded',String(expanded));$('powerDialogExpand').setAttribute('aria-label',expanded?'Restore sidebar width':'Expand call panel');$('powerDialogExpand').textContent=expanded?'Restore':'Expand';};
 $('powerDialogMinimize').onclick=minimizeLead;$('powerReopen').onclick=showConnectedLead;
 const viewObserver=new MutationObserver(sidebarLayout);viewObserver.observe(panel,{attributes:true,attributeFilter:['hidden']});
 const current=()=>!disposed&&stored()?.user?.id===owner;
 const name=l=>[l?.first_name,l?.last_name].filter(Boolean).join(' ')||'Unnamed lead';
 const phone=l=>String(l?.phone||'').replace(/\D/g,'').replace(/^1(?=\d{10}$)/,'');
 const callable=l=>l.agent_status!=='dead_number'&&/^[2-9]\d{2}[2-9]\d{6}$/.test(phone(l));
 function retryKind(s,l){
  if(!l.leadId||l.id===s.winnerId||!['canceled','completed','failed','busy','no-answer'].includes(l.state))return null;
  if(['second_answer','answer_unconfirmed','answered_not_connected'].includes(l.outcome))return l.outcome==='answer_unconfirmed'?'unconfirmed':'follow_up';
  return ['canceled','completed'].includes(l.state)&&!l.answer&&!l.pickedUp&&!l.durationSeconds&&(!l.outcome||l.outcome==='stopped')?'uncalled':null;
 }
 function rememberLeads(leads){for(const lead of leads||[]){known.set(lead.id,lead);rows=rows.map(row=>row.id===lead.id?lead:row);if(selected.has(lead.id))selected.set(lead.id,lead);}}
 function returnUnconnected(s){
  let uncalled=0,followup=0;
  for(const leg of s.legs||[]){const kind=retryKind(s,leg),lead=known.get(leg.leadId);if(!kind||!lead||!callable(lead))continue;selected.set(lead.id,lead);returned.set(lead.id,kind);if(kind==='uncalled')uncalled++;else followup++;}
  const messages=[];if(uncalled)messages.push(uncalled+' uncalled lead'+(uncalled===1?'':'s')+' returned to your queue.');if(followup)messages.push(followup+' lead'+(followup===1?'':'s')+' returned for follow-up.');
  $('powerReturned').hidden=!messages.length;$('powerReturned').textContent=messages.join(' ')+(messages.length?' Leads remain in their original folders. Calling continues when the session is running.':'');
 }
 function message(text,error=false){if(error)pauseSession('Paused — review the error before continuing.');for(const el of [$('powerMessage'),$('powerDialogMessage')]){el.textContent=text;el.classList.toggle('error',error);}}
 function ensure(){if(!current())throw Error('Your account changed. Reload Agent Dialer.');}
 async function request(path,body){ensure();const session=await options.getSession();ensure();token=session.access_token;const response=await fetch(path,{method:'POST',headers:{'Content-Type':'application/json',Authorization:'Bearer '+token},body:JSON.stringify(body),cache:'no-store',signal:AbortSignal.timeout(60000)});const data=await response.json();ensure();if(!response.ok){const error=Error(data.error||'The dialer could not complete this request. Please retry.');error.status=response.status;throw error;}return data;}
 const api=body=>request('/api/dialer/parallel',body),workspace=body=>request('/api/dialer/workspace-v2',body);
 function controls(){
  if(continuous&&(document.hidden||panel.hidden||navigator.onLine===false||(options.canDial&&!options.canDial())))pauseSession('Paused — keep this tab visible and your status Ready.');
  for(const button of $('powerQuickOutcomes').querySelectorAll('button'))button.disabled=busy||loading||!editor;
  const dirty=!!editor&&($('powerNotes').value!==(editor.call_notes||'')||!!$('powerOutcome').value);const locked=busy||loading||wrap||batchOutcomes.size>0;options.onBusyChange(busy||wrap||dirty||batchOutcomes.size>0);
  for(const el of panel.querySelectorAll('.power-toolbar select,.power-filters select,.power-filters input,.power-filters button,.power-queue-actions button'))el.disabled=locked;
  for(const el of panel.querySelectorAll('.power-rows input'))el.disabled=locked||el.dataset.callable!=='true';for(const el of panel.querySelectorAll('.power-rows button'))el.disabled=locked;
  for(const el of panel.querySelectorAll('.power-history button'))el.disabled=busy||wrap;
  $('powerReload').disabled=locked;$('powerPrevious').disabled=locked||offset===0;$('powerNext').disabled=locked||offset+500>=count;
  const size=Math.min(Number($('powerLines').value),selected.size);$('powerStart').textContent=sessionStarted?'Resume dialing':'Start dialing';$('powerStart').disabled=locked||!canCall||!selected.size||!$('powerCaller').value||(options.canDial&&!options.canDial());
  for(const el of $('powerRedials').querySelectorAll('button'))el.disabled=busy||loading||!!id||!canCall||(options.canDial&&!options.canDial());
  $('powerBatchSaveNext').disabled=busy||loading;
  $('powerBatchSaveNext').textContent='Save changed results';
  for(const input of $('powerBatchOutcomes').querySelectorAll('select'))input.disabled=busy||loading;
  $('powerReopen').hidden=true;$('powerReopen').textContent=busy?'Open connected lead':'Open lead summary';
  $('powerConnectedTitle').textContent=busy&&wrap?'Connected call':wrap?'Call summary':'Lead information';
  $('powerConnectedState').textContent=stopping&&busy?'Ending calls…':busy?'Connected to '+name(editor):wrap?'Call ended — save your notes and outcome.':presentedWinner?'Call summary':'Review lead details.';
  $('powerDialogStop').disabled=!busy;$('powerDialogMute').disabled=!call;$('powerDialogMute').textContent=muted?'Unmute':'Mute';
  if(wrap)$('powerLeadBadge').textContent=busy?'Connected':'Call ended';
  $('powerCallTime').hidden=!connectedAt;updateCallTime();
  $('powerDialogSave').disabled=busy||loading||!editor;
  $('powerStop').hidden=$('powerMute').hidden=!busy;
  $('powerRows').closest('.power-table-scroll').setAttribute('aria-busy',String(loading));
  $('powerSelectionHelp').textContent=selected.size?selected.size+' in your calling queue':'Choose the leads you want to call.';
  $('powerBatchHint').textContent=busy?'Finish the current call to continue.':wrap||dirty?'Save your notes and outcome to continue.':!canCall?'Set up your calling plan and caller ID to begin.':options.canDial&&!options.canDial()?'Set your agent status to Ready to start calling.':selected.size?'Calling continues when the session is running.':'Select leads to start your next batch.';
  $('powerSaveNext').hidden=true;
  $('powerStop').disabled=!busy;$('powerMute').disabled=!call;$('powerSave').disabled=$('powerSaveNext').disabled=busy||loading||!editor;$('powerCount').textContent=selected.size+' selected · '+count.toLocaleString()+' matching leads';updateSimpleUI();
 }
 function release(){health?.close();health=null;const c=call;call=null;if(c)c.disconnect();if(disposed||deviceFault){device?.destroy();device=null;deviceKey=null;}muted=false;$('powerMute').textContent='Mute';busy=false;controls();}
 function updateCallTime(){if(!connectedAt)return;const seconds=Math.max(0,Math.floor(((endedAt||Date.now())-connectedAt)/1000));$('powerCallTime').textContent=String(Math.floor(seconds/60)).padStart(2,'0')+':'+String(seconds%60).padStart(2,'0');}
 function quickDetails(l){const box=$('powerQuickDetails');box.replaceChildren();for(const [label,value] of [['State',l.state],['Folder',l.lead_type],['Email',l.email],['Status',String(l.agent_status||'New lead').replace(/_/g,' ')]]){if(!value)continue;const group=document.createElement('div'),dt=document.createElement('dt'),dd=document.createElement('dd');dt.textContent=label;dd.textContent=String(value);group.append(dt,dd);box.append(group);}}
 function details(l){const box=$('powerDetails');box.replaceChildren();const pairs=[['State',l.state],['Email',l.email],['Folder',l.lead_type],['Current status',String(l.agent_status||'New lead').replace(/_/g,' ')]];if(Array.isArray(l.csv_headers)&&Array.isArray(l.csv_values))l.csv_headers.forEach((h,i)=>{if(String(h||'').trim())pairs.push([h,l.csv_values[i]]);});for(const [label,value] of pairs){if(value===null||value===undefined||String(value).trim()==='')continue;const group=document.createElement('div'),dt=document.createElement('dt'),dd=document.createElement('dd');dt.textContent=label;dd.textContent=String(value);group.append(dt,dd);box.append(group);}}
 function openLead(l,required=false){
  if(!l)return;if(editor?.id===l.id){if(required)wrap=true;controls();return;}
  if(editor&&($('powerNotes').value!==(editor.call_notes||'')||$('powerOutcome').value))return message('Save the current lead’s notes and outcome before opening another lead.',true);
  editor={...l};wrap=required;if(!required){presentedWinner=null;connectedAt=0;endedAt=0;}dialog.dataset.leadId=l.id;$('powerEmpty').hidden=true;$('powerLead').hidden=false;$('powerName').textContent=name(l);$('powerContact').textContent=(l.phone||'No phone number')+(l.state?' · '+l.state:'');details(l);quickDetails(l);renderPowerScript(true);$('powerAvatar').textContent=[l.first_name,l.last_name].filter(Boolean).map(v=>String(v).trim().charAt(0)).join('').slice(0,2).toUpperCase()||'—';$('powerAllDetails').open=false;$('powerPreviousNotes').hidden=!l.call_notes;$('powerPreviousNotes').open=false;$('powerPreviousText').textContent=l.call_notes||'';$('powerNotes').value=l.call_notes||'';$('powerOutcome').value='';$('powerSaveMessage').textContent='';$('powerLeadBadge').textContent=required?'Save after call':'Lead card';controls();
 }
 function resetEditor(){minimizeLead();presentedWinner=null;connectedAt=0;endedAt=0;editor=null;wrap=false;$('powerLead').hidden=true;$('powerEmpty').hidden=false;$('powerLeadBadge').textContent='Ready';}
 function visible(){const q=$('powerSearch').value.trim().toLowerCase();return rows.filter(l=>[name(l),l.phone,l.state].join(' ').toLowerCase().includes(q));}
 function updateRowStates(){
  const legs=new Map((last?.legs||[]).map(l=>[l.leadId,l]));
  for(const row of $('powerRows').querySelectorAll('[data-lead-id]')){
   const lead=known.get(row.dataset.leadId);if(!lead)continue;const leg=legs.get(lead.id),returnedAs=returned.get(lead.id),badge=row.querySelector('.power-row-status');
   const connected=busy&&last?.state==='connected'&&!!leg&&leg.id===last.winnerId;row.classList.toggle('is-connected',connected);
   let label=({appointment_follow_up:'Follow-up',call_back:'Call back',not_interested:'Not interested',dead_number:'Dead number'})[lead.agent_status]||String(lead.agent_status||'New lead').replace(/_/g,' '),tone=['appointment_follow_up','call_back'].includes(lead.agent_status)?'follow-up':'neutral';
   if(returnedAs){label=returnedAs==='uncalled'?'Uncalled':returnedAs==='unconfirmed'?'Pickup unconfirmed':'Follow-up needed';tone=returnedAs==='uncalled'?'neutral':'follow-up';}
   if(busy&&leg&&!returnedAs){label=leg.outcome==='machine'?'Machine detected':leg.outcome==='second_answer'?'Follow-up needed':leg.outcome==='answer_unconfirmed'?'Pickup unconfirmed':leg.state==='ringing'?'Ringing':leg.state==='in-progress'?'Checking answer':['prepared','creating','queued'].includes(leg.state)?'Calling':label;tone='calling';}
   if(connected){label='Connected';tone='connected';}else if(!callable(lead)){label=lead.agent_status==='dead_number'?'Dead number':'Invalid number';tone='invalid';}
   badge.textContent=label;badge.dataset.tone=tone;
  }
 }
 function renderRows(){
  const box=$('powerRows'),matches=visible(),fragment=document.createDocumentFragment();
  for(const lead of matches){
   const row=document.createElement('tr');row.className='power-row';row.dataset.leadId=lead.id;
   const checkbox=document.createElement('input');checkbox.type='checkbox';checkbox.dataset.callable=String(callable(lead));checkbox.checked=selected.has(lead.id);checkbox.disabled=busy||wrap||!callable(lead);checkbox.setAttribute('aria-label','Select '+name(lead));
   checkbox.onchange=()=>{if(checkbox.checked){if(selected.size>=1000){checkbox.checked=false;return message('Your queue can contain up to 1,000 leads.',true);}selected.set(lead.id,lead);}else selected.delete(lead.id);controls();};
   const pick=document.createElement('td');pick.append(checkbox);row.append(pick);
   const info=document.createElement('td'),title=document.createElement('strong');title.textContent=name(lead);info.className='power-row-name';info.append(title);
   if(returned.has(lead.id)){const badge=document.createElement('small');badge.className='power-returned';badge.textContent=returned.get(lead.id)==='uncalled'?'Uncalled · returned to queue':returned.get(lead.id)==='unconfirmed'?'Pickup unconfirmed · follow-up queued':'Answered · follow-up queued';info.append(badge);}
   row.append(info);
   for(const value of [lead.phone||'No phone',lead.state||'—']){const cell=document.createElement('td');cell.textContent=value;row.append(cell);}
   const status=document.createElement('td'),badge=document.createElement('span');badge.className='power-row-status';status.append(badge);row.append(status);
   const folderCell=document.createElement('td');folderCell.className='power-row-folder';folderCell.textContent=lead.lead_type||'Unlabeled';row.append(folderCell);
   const action=document.createElement('td'),view=document.createElement('button');view.type='button';view.textContent='View';view.setAttribute('aria-label','View '+name(lead));view.disabled=busy||wrap;view.onclick=()=>{openLead(lead);if(editor?.id===lead.id)showConnectedLead();};action.append(view);row.append(action);fragment.append(row);
  }
  if(!matches.length){const row=document.createElement('tr'),cell=document.createElement('td'),title=document.createElement('strong'),hint=document.createElement('p');cell.colSpan=7;cell.className='power-queue-empty';title.textContent=$('powerSearch').value.trim()?'No leads match your search':'No leads in this selection';hint.textContent=$('powerSearch').value.trim()?'Try another name, phone number or state on this page.':'Choose another folder or adjust your state filters.';cell.append(title,hint);row.append(cell);fragment.append(row);}
  box.replaceChildren(fragment);updateRowStates();$('powerPage').textContent=count?($('powerSearch').value.trim()?matches.length+' shown · ':'')+(offset+1)+'–'+Math.min(offset+500,count)+' of '+count.toLocaleString():'No leads';controls();
 }
 function lineCard(position){let card=cards.get(position);if(!card){card=document.createElement('button');card.type='button';card.className='power-line';card.innerHTML='<span class="power-line-top"><span class="power-line-number"></span><span class="power-line-state"></span></span><span class="power-line-person"><span class="power-line-avatar" aria-hidden="true"></span><span class="power-line-info"><strong></strong><span class="power-line-phone"></span></span></span>';card.querySelector('.power-line-number').textContent='LINE '+position;cards.set(position,card);$('powerCards').append(card);}return card;}
 function idleLines(){if(last)return;const size=Number($('powerLines').value);for(let position=1;position<=3;position++){const card=lineCard(position);card.hidden=position>size;card.disabled=true;card.classList.add('is-idle');card.querySelector('.power-line-avatar').textContent='—';card.querySelector('strong').textContent='Line available';card.querySelector('.power-line-phone').textContent='Select leads to begin';card.querySelector('.power-line-state').textContent='Standby';}}
 async function loadRows(){const body={action:'leads',offset,states};if(folder>0)body.folder=folders[folder-1].lead_type;const d=await workspace(body);rows=d.leads||[];count=Number(d.count||0);rows.forEach(l=>known.set(l.id,l));const box=$('powerStateChoices');box.replaceChildren();for(const state of d.states||[]){const label=document.createElement('label'),input=document.createElement('input');input.type='checkbox';input.value=state.state||'';input.checked=states.includes(input.value);label.append(input,document.createTextNode((state.state||'State not set')+' ('+Number(state.lead_count)+')'));box.append(label);}$('powerStateSummary').textContent=states.length?states.map(s=>s||'State not set').join(', '):'All states';renderRows();}
 async function work(fn){if(loading||busy||wrap||batchOutcomes.size)return;loading=true;controls();try{await fn();}catch(e){message(e.message,true);}finally{loading=false;renderRows();}}
 async function loadFolders(){const d=await workspace({action:'folders'});folders=d.folders||[];const select=$('powerFolder');select.replaceChildren(new Option('All my leads','0'));folders.forEach((f,i)=>select.add(new Option((f.lead_type||'Unlabeled')+' ('+f.lead_count+')',String(i+1))));folder=0;offset=0;states=[];selected.clear();await loadRows();}
 function render(s){
  if(!s)return;if(s.state==='complete'&&s.id===id)returnUnconnected(s);last=s;const labels={prepared:'Ready',creating:'Starting',queued:'Starting',ringing:'Ringing', 'in-progress':'Answered',completed:'Ended',busy:'Busy',failed:'Number could not connect','no-answer':'No answer',canceled:'Stopped'};
  for(const l of s.legs||[]){const card=lineCard(l.position);card.disabled=false;card.classList.remove('is-idle');card.dataset.state=l.state;const lead=known.get(l.leadId);card.querySelector('.power-line-avatar').textContent=lead?[lead.first_name,lead.last_name].filter(Boolean).map(v=>String(v).trim().charAt(0)).join('').slice(0,2).toUpperCase()||'—':'—';card.querySelector('strong').textContent=lead?name(lead):l.phone;card.querySelector('.power-line-phone').textContent=l.phone+(l.callerId?' · From '+l.callerId:'');
   card.classList.toggle('connected',l.id===s.winnerId&&s.state!=='complete');card.classList.toggle('follow-up',['second_answer','answer_unconfirmed','answered_not_connected'].includes(l.outcome));
   card.querySelector('.power-line-state').textContent=l.outcome==='second_answer'?'Answered · follow-up needed':l.outcome==='answer_unconfirmed'?'Pickup unconfirmed · follow-up needed':l.outcome==='answered_not_connected'?'Answered · not connected':l.outcome==='lead_changed'?'Assignment changed · skipped':l.outcome==='creation_uncertain'?'Confirming with provider':l.outcome==='number_rejected'?'Number rejected'+(l.errorCode?' ('+l.errorCode+')':''):l.id===s.winnerId?(s.state==='complete'?'Conversation ended':l.answer==='unknown'?'Connected · detection uncertain':'Connected to you'):retryKind(s,l)==='uncalled'?(s.state==='complete'?'Uncalled · available in folder':'Uncalled · returning after batch'):l.outcome==='machine'?'Machine / screening detected':l.outcome==='fax'?'Fax detected':l.outcome==='unknown'?'Answer not identified':s.connectMode==='human'&&l.state==='in-progress'&&!l.answer?'Checking answer…':labels[l.state]||l.state;
   card.onclick=()=>{if(l.id===s.winnerId&&(busy||wrap))showConnectedLead();else if(!busy&&!wrap){openLead(lead);if(editor?.id===lead?.id)showConnectedLead();}};
  }
  for(const [position,card] of cards)card.hidden=!(s.legs||[]).some(l=>l.position===position);
  $('powerConnection').textContent=({prepared:'Connecting headset',ready:'Headset ready',dialing:'Calling',connected:'Connected',stopping:'Ending calls',complete:'Batch finished'}[s.state]||s.state);
  $('powerConnection').dataset.state=s.state;for(const row of $('powerRows').querySelectorAll('[data-lead-id]'))row.querySelector('input').checked=selected.has(row.dataset.leadId);updateRowStates();
  renderRedials(s);
  const winner=s.legs?.find(l=>l.id===s.winnerId);if(winner&&s.id===id){if(lastMeasured!==s.id){lastMeasured=s.id;health?.record('conversation_presented');health?.flush();}const lead=known.get(winner.leadId);openLead(lead,true);const key=s.id+':'+winner.id;if(lead&&editor?.id===lead.id&&presentedWinner!==key){presentedWinner=key;connectedAt=Date.now();endedAt=0;message('Connected to '+name(lead)+'. Your lead information is open.');showConnectedLead();}}
  if(s.state==='complete'&&s.id===id){if(connectedAt&&!endedAt)endedAt=Date.now();health?.record('batch_finished');id=null;stopping=false;release();renderRows();showBatchReview(s);
   if($('powerAdaptive').checked&&(s.legs||[]).some(l=>['second_answer','answer_unconfirmed','answered_not_connected'].includes(l.outcome))){pace=Math.max(1,pace-1);$('powerSessionState').textContent='Pacing reduced to '+pace+' line(s) after overlapping or uncertain answers.';}
   if((s.legs||[]).some(l=>l.state==='failed'||['creation_uncertain','number_rejected'].includes(l.outcome)))pauseSession('Paused — review the failed line.');
   scheduleNext();message(wrap?'Call ended. Choose an outcome to continue.':continuous?'Results saved automatically.':'Batch finished.');refresh().catch(e=>message(e.message,true));}
 }
 function renderRedials(s){
  const box=$('powerRedials');box.replaceChildren();box.hidden=s.state!=='complete';if(box.hidden)return;
  for(const leg of s.legs||[]){const lead=known.get(leg.leadId);if(!lead||!callable(lead)||!['completed','busy','no-answer','failed','canceled'].includes(leg.state))continue;
   const button=document.createElement('button');button.type='button';button.dataset.redialLead=lead.id;button.textContent='↻ Call again · '+name(lead);button.setAttribute('aria-label','Call '+name(lead)+' again');button.disabled=busy||loading||!!id;
   button.onclick=()=>startBatch({sessionId:s.id,legId:leg.id,leadId:lead.id});box.append(button);
  }box.hidden=!box.children.length;
 }
 function showBatchReview(s){
  if(reviewedBatch===s.id)return;reviewedBatch=s.id;batchOutcomes.clear();const box=$('powerBatchOutcomes');box.replaceChildren();
  for(const leg of s.legs||[]){const lead=known.get(leg.leadId);if(!lead)continue;
   const row=document.createElement('label'),title=document.createElement('strong'),result=document.createElement('span'),select=document.createElement('select');row.className='power-batch-outcome';title.textContent=name(lead);result.textContent=cards.get(leg.position)?.querySelector('.power-line-state').textContent||leg.state;select.dataset.leadId=lead.id;select.setAttribute('aria-label','Outcome for '+name(lead));
   select.add(new Option(leg.id===s.winnerId?'Choose conversation outcome':'Keep automatic result',''));
   for(const [value,label] of [['appointment_follow_up','Appointment / follow-up'],['call_back','Call back'],['not_interested','Not interested'],['dead_number','Dead number']])select.add(new Option(label,value));
   if(editor?.id===lead.id)select.value=$('powerOutcome').value;
   if(select.value)batchOutcomes.set(lead.id,select.value);
   select.onchange=()=>{if(select.value)batchOutcomes.set(lead.id,select.value);else batchOutcomes.delete(lead.id);if(editor?.id===lead.id)$('powerOutcome').value=select.value;controls();};row.append(title,result,select);box.append(row);
  }
  $('powerBatchSaveMessage').textContent='';$('powerBatchReview').hidden=!box.children.length;controls();
 }
 async function saveBatchNext(next=true){
  if(busy||loading)return;
  if(editor&&$('powerOutcome').value)batchOutcomes.set(editor.id,$('powerOutcome').value);
  if(wrap&&editor&&!batchOutcomes.get(editor.id)){minimizeLead();$('powerBatchSaveMessage').textContent='Choose an outcome for '+name(editor)+'. The other lines can keep their automatic results.';return;}
  if(editor&&$('powerNotes').value!==(editor.call_notes||'')&&!batchOutcomes.get(editor.id)){message('Choose an outcome for the lead with unsaved notes.',true);return;}
  loading=true;controls();let complete=false;
  try{
   for(const [leadId,status] of [...batchOutcomes]){
    const lead=editor?.id===leadId?editor:known.get(leadId);if(!lead)throw Error('Reload this lead before saving.');
    const notes=editor?.id===leadId?$('powerNotes').value:(lead.call_notes||'');
    const d=await workspace({action:'save',leadId,status,notes,expectedNotes:lead.call_notes,expectedStatus:lead.agent_status});rememberLeads([d.lead]);selected.delete(leadId);returned.delete(leadId);batchOutcomes.delete(leadId);
    if(editor?.id===leadId){editor={...d.lead};wrap=false;$('powerNotes').value=d.lead.call_notes||'';$('powerOutcome').value='';}
    const input=[...$('powerBatchOutcomes').querySelectorAll('select')].find(el=>el.dataset.leadId===leadId);if(input){input.value='';input.options[0].textContent='Saved · '+status.replace(/_/g,' ');}
   }
   complete=true;$('powerSaveMessage').textContent='Notes and outcome saved.';if(editor)$('powerLeadBadge').textContent='Saved';minimizeLead();$('powerBatchReview').hidden=true;message('Results saved.');
  }catch(e){pauseSession('Paused — your outcome has not saved.');$('powerSaveMessage').textContent=e.message;$('powerBatchSaveMessage').textContent=e.message+' Saved outcomes are kept; retry the remaining outcomes.';}finally{loading=false;renderRows();}
  if(!complete)return;if(!next){scheduleNext();updateSimpleUI();return;}if(!selected.size)return message('Batch saved. Your selected queue is finished.');
  if(options.beforeNext&&!await options.beforeNext()){pauseSession('Paused for a due callback.');return;}
  if(current()&&!busy&&!loading&&!wrap&&(!options.canDial||options.canDial()))await $('powerStart').onclick();
 }
 $('powerBatchSaveNext').onclick=()=>saveBatchNext(false);
 async function refresh(){const d=await api({action:'options'});canCall=d.canCall===true;$('powerPoolInfo').hidden=!d.callerPool;$('powerPoolInfo').textContent=d.callerPool?'Shared caller IDs · '+d.callerPool.count+' numbers rotate per lead. Callbacks route to the original agent. Agency usage charges apply.':'';const old=$('powerCaller').value;$('powerCaller').replaceChildren();for(const phone of d.numbers||[])$('powerCaller').add(new Option((d.callerPool?'Shared pool · fallback ':'')+phone,phone));if(d.numbers?.includes(old))$('powerCaller').value=old;if(!d.numbers?.length)$('powerCaller').add(new Option('Activate a caller ID',''));$('powerSetup').hidden=canCall&&!!d.numbers?.length;
  const box=$('powerHistory');box.replaceChildren();for(const s of d.sessions||[]){const row=document.createElement('div');row.className='power-history-row';const label=document.createElement('span');label.textContent=new Date(s.created_at).toLocaleString()+' · '+s.state+(s.kind==='test'?' · Earlier test':'');const view=document.createElement('button');view.textContent='Review';view.disabled=busy||wrap;view.onclick=async()=>{try{const result=await api({action:'status',id:s.id,details:true});(result.leads||[]).forEach(l=>known.set(l.id,l));render(result.session);message('Select a line card to review that lead or save a follow-up.');}catch(e){message(e.message,true);}};row.append(label,view);if(s.state!=='complete'){const stop=document.createElement('button');stop.textContent='End batch';stop.onclick=async()=>{try{await api({action:'stop',id:s.id});await refresh();message('Batch stop requested. Refresh to check the result.');}catch(e){message(e.message,true);}};row.append(stop);}box.append(row);}if(!box.children.length)box.textContent='Your recent batches will appear here.';controls();
 }
 async function stop(){generation++;stopping=true;if(!id){release();message('Calling canceled.');return;}if(!batchReady){message('Canceling call setup…');return;}const target=id;message('Ending every line…');const c=call;call=null;c?.disconnect();controls();try{const d=await api({action:'stop',id:target});if(target===id){rememberLeads(d.leads);render(d.session);}if(d.session.state!=='complete')message('Stop requested. Waiting for the provider to confirm all lines have ended.');}catch(e){message('Stop confirmation is pending. Keep this page open or press End all calls again. '+e.message,true);}}
 async function poll(){if(!current()||!id||!batchReady||polling)return;polling=true;try{const target=id,d=await api({action:'status',id:target,heartbeat:!!call&&!stopping});if(id!==target)return;rememberLeads(d.leads);render(d.session);if(d.session.state==='ready'&&call&&!launching&&!stopping){launching=true;health?.record('headset_ready');health?.record('launch_requested');message('Headset ready. Calling your selected leads…');try{const result=await api({action:'launch',id:target});if(id===target)render(result.session);}finally{launching=false;}}}catch(e){if(current())message(e.message,true);}finally{polling=false;}}
 $('powerStart').onclick=()=>startBatch();
 async function startBatch(redial=null){
  if(redial){
   if(busy||loading||id||options.isBusy())return message('Finish the active call before redialing.',true);
   pauseSession('Manual redial — automatic dialing paused.');
   if(batchOutcomes.size||(editor&&($('powerNotes').value!==(editor.call_notes||'')||$('powerOutcome').value)))return message('Save your pending notes and outcomes before redialing.',true);
   if(wrap&&editor?.id!==redial.leadId)return message('Save the conversation outcome before calling a different lead.',true);
   const lead=known.get(redial.leadId);if(!lead||!callable(lead))return message('This lead is no longer callable.',true);
   wrap=false;controls();
  }
  if(nextTimer){clearTimeout(nextTimer);nextTimer=null;nextAt=0;}
  if(options.canDial&&!options.canDial()){message('Set your agent status to Ready and wait for the connection before calling.',true);return;}
  if(busy||wrap||loading||options.isBusy()){message('Finish your current call and save its outcome before starting a batch.',true);return;}
  if(batchOutcomes.size)return message('Save the batch outcomes before starting the next calls.',true);
  if(editor&&($('powerNotes').value!==(editor.call_notes||'')||$('powerOutcome').value))return message('Save this lead’s notes and outcome before starting a batch.',true);
  const lineLimit=$('powerAdaptive').checked?Math.min(pace,Number($('powerLines').value)):Number($('powerLines').value);
  const unique=new Set(),batch=redial?[known.get(redial.leadId)]:[];for(const lead of (redial?[]:selected.values())){if(callable(lead)&&(retryAfter.get(phone(lead))||0)<=Date.now()&&!unique.has(phone(lead))){batch.push(lead);unique.add(phone(lead));}if(batch.length===lineLimit)break;}
  if(!batch.length)return message('No eligible leads right now. Select more leads or wait for the 30-minute retry delay.',true);
  const attemptStarted=Date.now(),attempt=++generation;busy=true;stopping=false;batchReady=false;continuous=!redial;sessionStarted=true;$('powerContinuous').checked=continuous;$('powerQueueDrawer').open=false;$('powerSettings').hidden=true;$('powerReturned').hidden=true;resetEditor();batchOutcomes.clear();reviewedBatch=null;$('powerBatchReview').hidden=true;controls();message('Checking your microphone and calling access…');let prepared=false,target=null;
  try{ensure();if(!window.Twilio?.Device)throw Error('Calling support did not load. Refresh Agent Dialer.');if(!navigator.mediaDevices?.getUserMedia)throw Error('Microphone access is unavailable. Open this page in a supported browser.');const stream=await navigator.mediaDevices.getUserMedia({audio:true});stream.getTracks().forEach(track=>track.stop());ensure();if(attempt!==generation)return;
   target=crypto.randomUUID();id=target;const d=await api({action:'prepareLeads',id:target,callerId:$('powerCaller').value,leadIds:batch.map(l=>l.id),connectMode:$('powerMode').value,reuseDevice:true,...(redial?{redial:{sessionId:redial.sessionId,legId:redial.legId}}:{})});prepared=true;batchReady=true;const skipped=$('powerSkipped');skipped.replaceChildren();skipped.hidden=!d.skipped?.length;for(const item of d.skipped||[]){const row=document.createElement('p');row.textContent=name(known.get(item.leadId))+' · Skipped: '+item.reason;skipped.append(row);}
   if(attempt!==generation){await stop();return;}(d.leads||batch).forEach(l=>known.set(l.id,l));for(const leg of d.session.legs||[]){selected.delete(leg.leadId);returned.delete(leg.leadId);const lead=known.get(leg.leadId);if(lead)retryAfter.set(phone(lead),Date.now()+30*60*1000);}render(d.session);
   health=window.VividCallHealth?.create({kind:'parallel',id:target,session:await options.getSession(),getSession:options.getSession,notice:message});
   health?.record('prepared',{metrics:{setupMs:Date.now()-attemptStarted}});
   if(!device||!d.deviceKey||deviceKey!==d.deviceKey||deviceFault||typeof device.updateToken!=='function'){
    device?.destroy();device=new Twilio.Device(d.token,{logLevel:0,closeProtection:true,enableImprovedSignalingErrorPrecision:true,maxCallSignalingTimeoutMs:30000});deviceKey=d.deviceKey||null;deviceFault=false;
    device.on('error',()=>{deviceFault=true;if(current()&&id&&!stopping){if(window.VividCallHealth?.live(call)){message('Headset connection needs attention. Keeping your current call open while it recovers.',true);return;}pauseSession('Paused after a connection error.');stop();}});
   }else device.updateToken(d.token);
   // Silence SDK connection cues before opening the microphone-backed call.
   device.audio?.outgoing?.(false);device.audio?.disconnect?.(false);
   health?.bindDevice(device);const connection=await device.connect({params:{ParallelGrant:d.callGrant}});if(!current()||id!==target||attempt!==generation){connection.disconnect();return;}call=connection;health?.bindCall(call);controls();for(const event of ['disconnect','cancel','reject'])call.on(event,()=>{if(current()&&id===target&&!stopping)stop();});call.on('error',()=>{if(current()&&id===target&&!stopping){if(window.VividCallHealth?.live(call)){message('The headset reported a connection problem. Keeping your call open while it recovers.',true);return;}pauseSession('Paused after a connection error.');stop();}});message('Headset connected. Preparing your lines…');await poll();
  }catch(e){if(current()&&(attempt===generation||(target&&id===target))){batchReady=true;const reason=e.name==='NotAllowedError'?'Allow microphone access in your browser, then retry.':e.name==='NotFoundError'?'No microphone was found. Connect a microphone or headset, then retry.':e.message;if(id){try{const stopped=await api({action:'stop',id});render(stopped.session);if(stopped.session.state==='complete')id=null;}catch(cleanupError){if(!prepared&&cleanupError.status===404)id=null;}}if(!id)release();else{stopping=true;message(reason+' Checking whether this batch needs cleanup.',true);return;}message(reason,true);}}
 };
 async function saveOutcome(next){
  if(busy||loading||!editor)return;const status=$('powerOutcome').value;if(!status)return $('powerSaveMessage').textContent='Choose an outcome before saving.';
  loading=true;controls();let saved=false;
  try{const d=await workspace({action:'save',leadId:editor.id,status,notes:$('powerNotes').value,expectedNotes:editor.call_notes,expectedStatus:editor.agent_status});
   batchOutcomes.delete(d.lead.id);const batchSelect=[...$('powerBatchOutcomes').querySelectorAll('select')].find(el=>el.dataset.leadId===d.lead.id);if(batchSelect){batchSelect.value='';batchSelect.options[0].textContent='Saved outcome';}
   known.set(d.lead.id,d.lead);rows=rows.map(l=>l.id===d.lead.id?d.lead:l);editor={...d.lead};wrap=false;saved=true;
   $('powerNotes').value=d.lead.call_notes||'';$('powerOutcome').value='';$('powerLeadBadge').textContent='Saved';$('powerSaveMessage').textContent='Notes and outcome saved.';
   message('Saved. Calling continues when the session is running.');minimizeLead();
  }catch(e){pauseSession('Paused — your outcome has not saved.');$('powerSaveMessage').textContent=e.message;}finally{loading=false;renderRows();}
  if(saved&&!next)scheduleNext();
  if(saved&&next){if(!selected.size)return message('Saved. Your selected queue is finished.');if(options.beforeNext&&!await options.beforeNext()){pauseSession('Paused for a due callback.');return;}
   if(!disposed&&!busy&&!loading&&!wrap&&(!options.canDial||options.canDial()))await $('powerStart').onclick();}
 }
 $('powerSave').onclick=$('powerDialogSave').onclick=()=>saveOutcome(false);$('powerSaveNext').onclick=()=>saveOutcome(true);
 $('powerNotes').oninput=controls;$('powerOutcome').onchange=()=>{const input=[...$('powerBatchOutcomes').querySelectorAll('select')].find(el=>el.dataset.leadId===editor?.id);if(input){input.value=$('powerOutcome').value;if(input.value)batchOutcomes.set(editor.id,input.value);else batchOutcomes.delete(editor.id);}controls();};
 $('powerStop').onclick=()=>{health?.record('user_hangup');return stop();};$('powerDialogStop').onclick=()=>{health?.record('user_hangup');return stop();};$('powerMute').onclick=$('powerDialogMute').onclick=()=>{if(call){muted=!muted;call.mute(muted);$('powerMute').textContent=muted?'Unmute':'Mute';controls();}};
 $('powerBilling').onclick=()=>options.openView('billing');$('powerLines').onchange=()=>{pace=Number($('powerLines').value);idleLines();controls();};
 $('powerSearch').oninput=renderRows;$('powerFolder').onchange=()=>work(async()=>{folder=Number($('powerFolder').value);offset=0;states=[];selected.clear();await loadRows();});$('powerApplyStates').onclick=()=>work(async()=>{states=[...$('powerStateChoices').querySelectorAll('input:checked')].map(x=>x.value);offset=0;selected.clear();$('powerStates').open=false;await loadRows();});
 $('powerReload').onclick=()=>work(loadFolders);$('powerPrevious').onclick=()=>work(async()=>{offset=Math.max(0,offset-500);await loadRows();});$('powerNext').onclick=()=>work(async()=>{offset+=500;await loadRows();});$('powerSelect').onclick=()=>{for(const l of visible())if(callable(l)&&selected.size<1000)selected.set(l.id,l);renderRows();};$('powerClear').onclick=()=>{selected.clear();renderRows();};$('powerRefreshHistory').onclick=()=>refresh().catch(e=>message(e.message,true));
 function pauseSession(reason){continuous=false;if(nextTimer)clearTimeout(nextTimer);nextTimer=null;nextAt=0;if($('powerContinuous'))$('powerContinuous').checked=false;if(reason&&$('powerSessionState'))$('powerSessionState').textContent=reason;updateSimpleUI();}
 function scheduleNext(){
  if(!continuous||busy||loading||wrap||batchOutcomes.size||nextTimer||!current()||panel.hidden||document.hidden)return;
  if(editor&&($('powerNotes').value!==(editor.call_notes||'')||$('powerOutcome').value))return;
  if(!selected.size){sessionStarted=false;pauseSession('Queue finished. Choose more leads to start again.');return;}
  nextAt=Date.now()+5000;$('powerSessionState').textContent='Next batch in 5 seconds — Pause stops future calls.';
  nextTimer=setTimeout(async()=>{nextTimer=null;nextAt=0;
   if(!continuous||!current()||busy||loading||wrap||batchOutcomes.size||panel.hidden||document.hidden||navigator.onLine===false||options.isBusy()||(options.canDial&&!options.canDial())){pauseSession('Paused — review your availability before continuing.');return;}
   if(options.beforeNext&&!await options.beforeNext()){pauseSession('Paused for a due callback.');return;}
   if(continuous&&current()&&!busy&&!loading&&!wrap&&!panel.hidden&&!document.hidden&&(!options.canDial||options.canDial()))await $('powerStart').onclick();
  },5000);updateSimpleUI();
 }
 $('powerContinuous').onchange=()=>{continuous=$('powerContinuous').checked;if(continuous){$('powerSessionState').textContent='Continuous dialing enabled. Start a batch when ready.';if(last?.state==='complete')scheduleNext();}else pauseSession('Manual next batch.');};
 $('powerPause').onclick=()=>{pauseSession(busy?'Paused — current call stays connected.':'Paused. Resume when ready.');controls();};
 $('powerEndSession').onclick=async()=>{sessionStarted=false;pauseSession('Session ended.');if(busy){health?.record('user_hangup');await stop();}controls();};
 $('powerAdaptive').onchange=()=>{pace=Number($('powerLines').value);};
 for(const button of $('powerQuickOutcomes').querySelectorAll('[data-power-outcome]'))button.onclick=()=>{if(busy||loading||!editor)return;$('powerOutcome').value=button.dataset.powerOutcome;$('powerOutcome').dispatchEvent(new Event('change'));return saveBatchNext(false);};
 $('powerReliability').onclick=async()=>{const box=$('powerReliabilityReport');box.hidden=false;box.textContent='Loading connection measurements…';try{const d=await request('/api/dialer/reliability',{});box.textContent=d.summary;}catch(e){box.textContent=e.message;}};

 function updateSimpleUI(){
  $('powerQueueSummary').textContent=(folder>0?folders[folder-1]?.lead_type||'Unlabeled':'All my leads')+' · '+(states.length?states.map(s=>s||'State not set').join(', '):'All states')+' · '+$('powerLines').value+' lines';
  $('powerQueueCount').textContent=selected.size?' · '+selected.size+' selected':'';
  $('powerChange').setAttribute('aria-expanded',String($('powerQueueDrawer').open));
  $('powerSettingsToggle').setAttribute('aria-expanded',String(!$('powerSettings').hidden));
  $('powerStart').hidden=continuous||busy;
  $('powerPause').hidden=!continuous;
  $('powerEndSession').hidden=!sessionStarted&&!busy;
  $('powerNotes').disabled=!editor||loading;
  $('powerOutcomeTitle').textContent=busy?'Call in progress':continuous?'Choose an outcome to continue':'Choose a call outcome';
  $('powerOutcomeHelp').textContent=busy?'Outcome controls are available after the call.':continuous?'Selecting an outcome saves your notes and resumes dialing.':'Selecting an outcome saves your notes. Dialing stays paused.';
  if(!busy){$('powerConnection').textContent=continuous?'Session on':sessionStarted?'Paused':'Ready to start';$('powerConnection').dataset.state=continuous?'dialing':'idle';}
  if(continuous&&!nextTimer)$('powerSessionState').textContent=busy?'Session on · Calls advance automatically':wrap?'Finish this conversation to continue':'Continuous dialing';
  $('powerMoreOutcomes').hidden=$('powerMore').getAttribute('aria-expanded')!=='true';
  if(last)for(const [position,card] of cards){const leg=last.legs?.find(l=>l.position===position);card.hidden=!leg||leg.id===last.winnerId&&editor?.id===leg.leadId;}
 }
 let scriptProfile=null;
 function renderPowerScript(match=false){
  const profile=options.getScriptProfile?.()||{scripts:[],agentName:''},scripts=profile.scripts||[];
  const select=$('powerScriptSelect');
  if(scriptProfile!==scripts){const previous=select.value;select.replaceChildren();for(const script of scripts)select.add(new Option(script.title,script.id));if(scripts.some(s=>s.id===previous))select.value=previous;scriptProfile=scripts;}
  if(match){const script=scripts.find(s=>s.lead_type&&s.lead_type.toLowerCase()===String(editor?.lead_type||'').toLowerCase());if(script)select.value=script.id;}
  const script=scripts.find(s=>s.id===select.value);select.hidden=!scripts.length;
  $('powerScriptTitle').textContent=script?.title||'Agency script';
  $('powerScriptBody').textContent=script?String(script.body||'').replace(/\{\{\s*(Your Name|Agent Name)\s*\}\}/gi,profile.agentName||'Your name').replace(/\{\{\s*First Name\s*\}\}/gi,editor?.first_name||'the client'):'Your saved agency scripts will appear here. Add scripts in Sales scripts.';
 }
 function noteTab(notes){for(const [id,active] of [['powerNotesTab',notes],['powerScriptTab',!notes]]){$(id).setAttribute('aria-selected',String(active));$(id).tabIndex=active?0:-1;}$('powerNotesPane').hidden=!notes;$('powerScriptPane').hidden=notes;if(!notes)renderPowerScript();}
 $('powerNotesTab').onclick=()=>noteTab(true);$('powerScriptTab').onclick=()=>noteTab(false);$('powerScriptSelect').onchange=()=>renderPowerScript();
 for(const id of ['powerNotesTab','powerScriptTab'])$(id).onkeydown=e=>{if(['ArrowLeft','ArrowRight','Home','End'].includes(e.key)){e.preventDefault();const notes=e.key==='Home'||e.key!=='End'&&id==='powerScriptTab';noteTab(notes);$(notes?'powerNotesTab':'powerScriptTab').focus();}};
 const toggleQueue=()=>{$('powerQueueDrawer').open=!$('powerQueueDrawer').open;updateSimpleUI();};
 $('powerChange').onclick=$('powerViewQueue').onclick=toggleQueue;$('powerQueueDrawer').addEventListener('toggle',updateSimpleUI);
 $('powerSettingsToggle').onclick=()=>{$('powerSettings').hidden=!$('powerSettings').hidden;updateSimpleUI();};
 $('powerMore').onclick=()=>{$('powerMore').setAttribute('aria-expanded',String($('powerMore').getAttribute('aria-expanded')!=='true'));updateSimpleUI();};
 const visibility=()=>{if(document.hidden)pauseSession('Paused — return to the dialer to resume.');};document.addEventListener('visibilitychange',visibility);
 const timer=setInterval(poll,1200),clockTimer=setInterval(updateCallTime,1000);
 function abandon(){health?.record('page_exit');health?.flush(true);if(id&&token)fetch('/api/dialer/parallel',{method:'POST',headers:{'Content-Type':'application/json',Authorization:'Bearer '+token},body:JSON.stringify({action:'stop',id}),keepalive:true}).catch(()=>{});}
 function dispose(){if(disposed)return;pauseSession();document.removeEventListener('visibilitychange',visibility);abandon();minimizeLead();disposed=true;id=null;clearInterval(timer);clearInterval(clockTimer);viewObserver.disconnect();root.classList.remove('power-sidebar-open','power-view-active');window.removeEventListener('storage',storage);window.removeEventListener('pagehide',pagehide);window.removeEventListener('beforeunload',beforeunload);release();panel.remove();button.remove();}
 function storage(e){if(e.key==='lld_session'&&!current())dispose();}function pagehide(){pauseSession();abandon();call?.disconnect();device?.destroy();device=null;deviceKey=null;}function beforeunload(e){if(busy||wrap||batchOutcomes.size||(editor&&$('powerNotes').value!==(editor.call_notes||''))){e.preventDefault();e.returnValue='';}}
 window.addEventListener('storage',storage);window.addEventListener('pagehide',pagehide);window.addEventListener('beforeunload',beforeunload);
 idleLines();
 return {show(){if(!shown){shown=true;work(async()=>{await Promise.all([refresh(),loadFolders()]);message('Choose your leads, then press Start dialing.');});}},dispose,conversation:()=>busy&&last?.winnerId?{kind:'power',id:last.id,active:last.state==='connected',label:last.legs.find(l=>l.id===last.winnerId)?.phone}:null,changed:controls,lead:()=>editor,activity:()=>busy?(last?.winnerId?'on_call':'dialing'):(wrap||batchOutcomes.size>0||!!editor&&($('powerNotes').value!==(editor.call_notes||'')||!!$('powerOutcome').value))?'wrap':null,isBusy:()=>busy||wrap||batchOutcomes.size>0||!!editor&&($('powerNotes').value!==(editor.call_notes||'')||!!$('powerOutcome').value)};
};
