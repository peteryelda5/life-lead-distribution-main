/* Shared agent status, durable callback tasks, and permission-scoped supervision. */
(() => {
 'use strict';
 window.createDialerOperations=function(root,options){
  const browserId=crypto.randomUUID(),owner=options.owner;
  let disposed=false,visible=true,mode='ready',pendingMode=null,modeRevision=0,renderedMode='ready',statusError='',verifiedAt=0,supervisor=false,changing=false,flight=null,again=false,lastActivity='',activeView='',priorityFlight=null,supervisorFlight=null,scheduleLead=null,scheduleId=null,latestTasks=[];
  const labels={ready:'Ready',dialing:'Dialing',on_call:'On call',wrap:'Finishing notes',break:'Break',offline:'Offline'};
  const $=id=>root.querySelector('#'+id),sameOwner=()=>{try{return !disposed&&JSON.parse(localStorage.getItem('lld_session')||'null')?.user?.id===owner;}catch{return false;}};
  const bar=document.createElement('section');bar.className='agent-status-bar';bar.setAttribute('aria-label','Agent availability');
  bar.innerHTML='<div class="agent-live-state"><span class="agent-state-dot"></span><div><strong id="agentState" role="status">Connecting…</strong><small id="agentStateHint">Checking your workspace</small></div></div><label>Availability<select id="agentMode"><option value="ready">Ready</option><option value="break">Break</option><option value="offline">Offline</option></select></label><button id="agentPriority">Priority callbacks <span id="agentPriorityCount">0</span></button><button id="agentSchedule">Schedule callback</button><button id="agentTeam" hidden>Team live view</button>';
  root.querySelector('.workspace-toolbar').before(bar);
  const priority=document.createElement('main');priority.id='priority';priority.className='secondary-view agent-operations';priority.hidden=true;
  priority.innerHTML='<header class="agent-ops-heading"><div><span class="agent-eyebrow">FOLLOW THROUGH</span><h2>Priority callbacks</h2><p>Due callbacks first. Open a lead to call it individually, then mark the task handled.</p></div><button id="priorityRefresh">Refresh</button></header><p id="priorityMessage" role="status"></p><div id="priorityRows" class="priority-grid"></div>';
  const team=document.createElement('main');team.id='supervisor';team.className='secondary-view agent-operations';team.hidden=true;
  team.innerHTML='<header class="agent-ops-heading"><div><span class="agent-eyebrow">TEAM ACTIVITY</span><h2>Live supervisor view</h2><p>Call totals are for today, Eastern time. Call minutes include machine answers. Conversations count Power Dialer connections.</p></div><button id="teamRefresh">Refresh</button></header><p id="teamMessage" role="status"></p><div id="teamSummary" class="agent-team-summary"></div><div class="agent-table-scroll"><table class="agent-team-table"><thead><tr><th>Agent</th><th>Status</th><th>Calls placed</th><th>Conversations</th><th>Call minutes</th><th>Unresolved inbound</th><th>Failed calls</th></tr></thead><tbody id="teamRows"></tbody></table></div>';
  const dialog=document.createElement('dialog');dialog.className='agent-schedule-dialog';dialog.setAttribute('aria-labelledby','scheduleTitle');
  dialog.innerHTML='<form id="scheduleForm"><h2 id="scheduleTitle">Schedule callback</h2><p id="scheduleName"></p><label>Callback date &amp; time<input id="scheduleDue" type="datetime-local" required></label><small id="scheduleTimezone"></small><label>Reminder note<textarea id="scheduleNote" maxlength="1000" rows="3"></textarea></label><p id="scheduleMessage" role="status"></p><div><button id="scheduleCancel" type="button">Cancel</button><button id="scheduleSave" class="primary" type="submit">Save callback</button></div></form>';
  root.append(priority,team,dialog);
  const liveMonitor=window.createDialerMonitor?.(team,options);
  async function request(action,extra={}){
   if(!sameOwner())throw Error('Your account changed. Reload the dialer.');const s=await options.getSession();
   if(!sameOwner())throw Error('Your account changed.');
   const r=await fetch('/api/dialer/operations',{method:'POST',headers:{'Content-Type':'application/json',Authorization:'Bearer '+s.access_token},body:JSON.stringify({action,...extra}),cache:'no-store',signal:AbortSignal.timeout(20000)});
   let data;try{data=await r.json();}catch{throw Error('Agent workspace unavailable. Please retry.');}
   if(!sameOwner())throw Error('Your account changed.');if(!r.ok)throw Error(data.error||'Agent workspace unavailable.');return data;
  }
  function activity(){return options.getActivity()||'idle';}
  function canDial(){return !liveMonitor?.active()&&sameOwner()&&!changing&&verifiedAt>Date.now()-45000&&mode==='ready';}
  function draw(){
   if(disposed)return;const current=activity(),fresh=verifiedAt>Date.now()-45000;
   const chosen=pendingMode??mode,status=current==='idle'?chosen:current;
   $('agentState').textContent=fresh?labels[status]:'Connection interrupted';bar.dataset.state=fresh?status:'offline';
   // Reassigning a native select on every refresh cancels an open popup / keyboard choice.
   if(renderedMode!==chosen){$('agentMode').value=chosen;renderedMode=chosen;}
   $('agentMode').disabled=false;
   $('agentStateHint').textContent=statusError?'Could not save status. New calls paused; retrying…':changing?'Saving '+labels[chosen]+'…':!fresh?'New calls paused. Reconnecting…':current!=='idle'&&chosen!=='ready'?labels[chosen]+' after this call':chosen==='ready'?'Ready for outgoing calls • use Go online for incoming calls':'New calls paused • callers go to voicemail';
   $('agentTeam').hidden=!supervisor;$('agentSchedule').disabled=!options.getLead()||changing;
  }
  function presence(nextMode){
   if(!sameOwner())return Promise.resolve();
   if(nextMode!==undefined){pendingMode=nextMode;modeRevision++;changing=true;statusError='';draw();options.onChange();}
   if(flight){again=true;return flight;}
   const sentMode=pendingMode,revision=modeRevision,sentActivity=activity();
   flight=(async()=>{try{
    const d=await request('presence',{browserId,activity:sentActivity,visible, ...(sentMode===null?{}:{mode:sentMode})});
    if(!sameOwner())return;
    if(!Object.hasOwn(labels,d.mode)||!['ready','break','offline'].includes(d.mode))throw Error('Invalid availability response.');
    mode=d.mode;supervisor=d.supervisor;verifiedAt=Date.now();lastActivity=sentActivity;statusError='';
    if(sentMode!==null&&revision===modeRevision)pendingMode=null;
   }catch(e){verifiedAt=0;statusError=e.message;}
   finally{changing=pendingMode!==null;flight=null;if(sameOwner()){draw();options.onChange();if(again){again=false;presence();}}}})();return flight;
  }
  function changed(){draw();const current=activity();if(current!==lastActivity){lastActivity=current;presence();}}
  function textElement(tag,text,className){const el=document.createElement(tag);el.textContent=text;if(className)el.className=className;return el;}
  function leadName(l){return [l.first_name,l.last_name].filter(Boolean).join(' ')||'Unnamed lead';}
  async function loadPriority(){
   if(priorityFlight)return priorityFlight;
   priorityFlight=(async()=>{try{
    const d=await request('priority');latestTasks=d.tasks||[];$('agentPriorityCount').textContent=d.due||0;
    $('priorityMessage').textContent=d.total?d.due+' due · '+d.total+' open'+(d.total>50?' · showing the first 50':''):'You’re caught up. New missed calls and follow-ups will appear here.';
    const box=$('priorityRows');box.replaceChildren();
    for(const t of latestTasks){
     const card=document.createElement('article');card.className='priority-card';const due=Date.parse(t.due_at)<=Date.now();card.dataset.due=String(due);
     card.append(textElement('span',due?'DUE NOW':'SCHEDULED','priority-badge'),textElement('h3',t.reason),textElement('p',new Date(t.due_at).toLocaleString()+' · '+(t.phone||'No phone number'),'priority-meta'));
     if(t.note)card.append(textElement('p',t.note));
     for(const l of t.matches||[]){const b=textElement('button',leadName(l)+' · '+(l.lead_type||'Unlabeled folder'),'priority-open');b.onclick=()=>{if(options.openLead(l))dialog.close();};card.append(b);card.append(textElement('small',[l.state,l.email].filter(Boolean).join(' · ')));}
     if(!t.matches?.length)card.append(textElement('p','No currently assigned lead matches this caller.','priority-meta'));
     if(t.matches?.length>1)card.append(textElement('small','Multiple matches — choose the correct lead.'));
     const actions=document.createElement('div');actions.className='priority-actions';
     if(t.source==='incoming'){const b=textElement('button','View call / voicemail');b.onclick=()=>options.openView('callbacks');actions.append(b);}
     const done=textElement('button','Mark handled');done.onclick=async()=>{done.disabled=true;try{await request('resolve',{id:t.id});await loadPriorityAfter();}catch(e){$('priorityMessage').textContent=e.message;done.disabled=false;}};actions.append(done);card.append(actions);box.append(card);
    }
    return d;
   }catch(e){$('priorityMessage').textContent=e.message;throw e;}finally{priorityFlight=null;}})();return priorityFlight;
  }
  async function loadPriorityAfter(){if(priorityFlight)await priorityFlight;return loadPriority();}
  async function loadTeam(){
   if(!supervisor||supervisorFlight)return;liveMonitor?.refresh();supervisorFlight=true;
   try{const d=await request('supervisor'),agents=d.agents||[];const rows=$('teamRows');rows.replaceChildren();
    for(const a of agents){const tr=document.createElement('tr'),name=document.createElement('td');name.append(textElement('strong',a.full_name||'Agent'),textElement('small',String(a.division||'').replace(/_/g,' ')));tr.append(name);
     const state=textElement('td',labels[a.state]||a.state);if(a.requested_mode&&a.requested_mode!=='ready'&&['on_call','dialing','wrap'].includes(a.state))state.append(textElement('small',labels[a.requested_mode]+' next'));tr.append(state);
     for(const value of [a.attempts,a.power_conversations,(Number(a.call_seconds)/60).toFixed(1),a.missed_callbacks,a.errors])tr.append(textElement('td',String(value)));rows.append(tr);
    }
    const summary=$('teamSummary');summary.replaceChildren();for(const [label,value] of [['Ready',agents.filter(a=>a.state==='ready').length],['On calls',agents.filter(a=>['on_call','dialing'].includes(a.state)).length],['Finishing notes',agents.filter(a=>a.state==='wrap').length],['Unresolved inbound',agents.reduce((n,a)=>n+Number(a.missed_callbacks),0)]]){const tile=document.createElement('div');tile.append(textElement('strong',String(value)),textElement('span',label));summary.append(tile);}
    $('teamMessage').textContent='Updated '+new Date(d.updatedAt).toLocaleTimeString()+' · refreshes every 15 seconds · '+agents.length+' agents in your permitted scope';
   }catch(e){$('teamRows').replaceChildren();$('teamSummary').replaceChildren();$('teamMessage').textContent=e.message;}finally{supervisorFlight=false;}
  }
  $('agentMode').onchange=()=>presence($('agentMode').value);
  $('agentPriority').onclick=()=>options.openView('priority');$('agentTeam').onclick=()=>options.openView('supervisor');
  $('priorityRefresh').onclick=()=>loadPriority().catch(()=>{});$('teamRefresh').onclick=loadTeam;
  $('agentSchedule').onclick=()=>{
   const lead=options.getLead();if(!lead)return;scheduleLead={...lead};scheduleId=crypto.randomUUID();$('scheduleName').textContent=leadName(lead);$('scheduleNote').value='';$('scheduleMessage').textContent='';
   const local=new Date(Date.now()+3600000);local.setMinutes(local.getMinutes()-local.getTimezoneOffset());$('scheduleDue').value=local.toISOString().slice(0,16);$('scheduleTimezone').textContent='Your local time zone: '+Intl.DateTimeFormat().resolvedOptions().timeZone;dialog.showModal();
  };
  $('scheduleCancel').onclick=()=>dialog.close();$('scheduleForm').onsubmit=async e=>{
   e.preventDefault();if(!scheduleLead)return;const due=new Date($('scheduleDue').value);if(!Number.isFinite(+due))return;
   $('scheduleSave').disabled=true;try{await request('schedule',{id:scheduleId,leadId:scheduleLead.id,dueAt:due.toISOString(),note:$('scheduleNote').value});dialog.close();await loadPriorityAfter();}catch(error){$('scheduleMessage').textContent=error.message;}finally{$('scheduleSave').disabled=false;}
  };
  const timer=setInterval(()=>{if(!sameOwner()){dispose();return;}draw();options.onChange();presence();if(visible&&!document.hidden){loadPriority().catch(()=>{});if(activeView==='supervisor')loadTeam();}},15000);
  function dispose(){if(disposed)return;visible=false;if(sameOwner())request('presence',{browserId,activity:'idle',visible:false}).catch(()=>{});liveMonitor?.dispose();disposed=true;clearInterval(timer);if(dialog.open)dialog.close();bar.remove();priority.remove();team.remove();dialog.remove();}
  presence();loadPriority().catch(()=>{});
  return {canDial,changed,dispose,mode:()=>mode,setVisible(value){visible=value;presence();},show(view){activeView=view;if(view==='priority')loadPriority().catch(()=>{});if(view==='supervisor')loadTeam();},async beforeNext(){
   if(!canDial())return false;
   try{const d=await loadPriorityAfter();if(d.due){options.openView('priority');$('priorityMessage').textContent='Your outcome was saved. Review the due callbacks before starting another batch. '+$('priorityMessage').textContent;return false;}return canDial();}catch{return false;}
  }};
 };
})();
