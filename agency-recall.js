/* Agency recall is Master-only; the server validates every previewed lead again. */
async function chooseAgencyRecall(){
 if(S.profile?.role!=='admin'||!S.profile.is_super_admin)return;
 const user=S.profile.id,epoch=portalSessionEpoch;
 closeModal();modal('<h2>Take back agency leads</h2><p class="muted">Return open leads from any agency to Owner / Master.</p><form id="recallAgencyForm" class="stack"><div class="field"><label for="recallAgency">Agency</label><select id="recallAgency" disabled><option>Loading agencies…</option></select></div><div id="recallAgencyError" role="alert"></div><div class="row"><button type="button" id="recallAgencyCancel" class="btn secondary">Cancel</button><button id="recallAgencyNext" class="btn primary" disabled>Continue</button></div></form>');
 const root=q('#modal'),valid=()=>root.isConnected&&S.profile?.id===user&&portalSessionEpoch===epoch;
 root.querySelector('#recallAgencyCancel').onclick=()=>root.remove();
 try{
  const agencies=await api('/rest/v1/rpc/agency_recall_agencies',{method:'POST',body:{}})||[];
  if(!valid())return;
  const select=root.querySelector('#recallAgency');select.innerHTML=agencies.map((a,i)=>'<option value="'+i+'">'+esc(a.name)+(a.archived?' (archived)':'')+'</option>').join('');
  select.disabled=!agencies.length;root.querySelector('#recallAgencyNext').disabled=!agencies.length;select.focus();
  root.querySelector('#recallAgencyForm').onsubmit=e=>{e.preventDefault();if(!valid())return;const agency=agencies[Number(select.value)];if(agency)openAgencyRecall(agency.id,agency);};
 }catch(error){if(valid())root.querySelector('#recallAgencyError').textContent=error.message;}
}
async function openAgencyRecall(source,selectedAgency){
 if(S.profile?.role!=='admin'||!S.profile.is_super_admin||source==='owner')return;
 const agency=selectedAgency||(S.divisionDirectory||[]).find(d=>d.id===source);
 if(!agency)return;
 const user=S.profile.id,epoch=portalSessionEpoch,opener=document.activeElement;
 closeModal();
 modal('<div class="agency-recall-header"><h2 id="agencyRecallTitle">Take back leads</h2><p>From <strong>'+esc(agency.name)+'</strong> to <strong>Owner / Master</strong></p></div><form id="agencyRecallForm" class="stack"><div class="agency-recall-fields"><div class="field"><label for="recallType">Lead folder</label><select id="recallType" disabled><option value="all">Loading folders…</option></select></div><div class="field"><label for="recallScope">Which leads?</label><select id="recallScope"><option value="all">All open leads</option><option value="pool">Unassigned agency pool only</option><option value="assigned">Assigned to agents / admins</option></select></div><div class="field"><label for="recallCount">Number of leads</label><input id="recallCount" type="number" min="1" max="1000" step="1" value="100" required></div></div><fieldset class="agency-recall-state-field"><legend>States to take back</legend><p id="recallStatesHelp" class="muted small">Choose one or more states.</p><div id="recallStates" class="agency-recall-states"></div></fieldset><div class="agency-recall-availability" aria-live="polite"><strong id="recallAvailableTitle"></strong><span id="recallFolderTotals"></span><span id="recallScopeHelp"></span><strong id="recallQuantityHelp"></strong><button type="button" id="recallIncludeAssigned" class="btn secondary" hidden>Include assigned leads too</button></div><p id="recallNote" class="agency-recall-note">Oldest matching leads first, up to 1,000 at a time. Assigned leads will be removed from the current agent or admin. Notes, lead statuses, and folder details stay with each lead. Closed business is excluded.</p><div id="recallMessage" role="status" aria-live="polite">Loading available folders…</div><div id="recallPreview" hidden></div><div class="agency-recall-actions"><button id="recallCancel" class="btn secondary" type="button">Cancel</button><button id="recallPreviewButton" class="btn secondary" type="submit" disabled>Preview leads</button><button id="recallConfirm" class="btn primary" type="button" hidden>Take back leads</button></div></form>');
 const root=q('#modal'),box=root.querySelector('.modalbox'),find=s=>root.querySelector(s);
 root.classList.add('agency-recall-modal');box.setAttribute('role','dialog');box.setAttribute('aria-modal','true');box.setAttribute('aria-labelledby','agencyRecallTitle');
 let folders=[],preview=null,requestId=null,busy=false,loading=true,generation=0,selectedStates=null;
 const valid=()=>root.isConnected&&S.profile?.id===user&&portalSessionEpoch===epoch&&S.profile.is_super_admin;
 const message=(text,error=false)=>{find('#recallMessage').textContent=text;find('#recallMessage').className=error?'error':'muted small';};
 const updateControls=()=>{
  root.setAttribute('aria-busy',String(busy));
  for(const id of ['recallType','recallScope','recallCount','recallPreviewButton'])find('#'+id).disabled=busy||loading;
  for(const input of root.querySelectorAll('#recallStates input'))input.disabled=busy||loading;
  find('#recallPreviewButton').disabled=busy||loading||selectedStates?.size===0;
  find('#recallCancel').disabled=busy;
  find('#recallConfirm').disabled=busy;
  find('#recallIncludeAssigned').disabled=busy||loading;
 };
 const dismiss=()=>{if(busy)return;generation++;root.remove();if(opener?.isConnected)opener.focus();};
 const invalidate=()=>{generation++;preview=null;requestId=null;find('#recallPreview').hidden=true;find('#recallConfirm').hidden=true;message('Preview the leads before taking them back.');};
 const updateAvailability=()=>{
  const type=find('#recallType').value,scope=find('#recallScope').value;
  const chosen=type==='all'?folders:[folders[Number(type)]].filter(Boolean);
  const count=(folder,kind,filterStates)=> (folder.states||[]).filter(s=>!filterStates||selectedStates===null||selectedStates.has(s.state)).reduce((n,s)=>n+Number(kind==='all'?s.count:s[kind]||0),0);
  const sum=(kind,filterStates)=>chosen.reduce((n,f)=>n+count(f,kind,filterStates),0);
  // Every number in the folder picker describes the currently selected filters.
  Array.from(find('#recallType').options).forEach(option=>{
   const all=option.value==='all',folder=folders[Number(option.value)];
   const n=all?folders.reduce((total,f)=>total+count(f,scope,true),0):count(folder,scope,true);
   option.textContent=(all?'All folders':folder.type||'Untitled folder')+' ('+n.toLocaleString()+' matching)';
  });
  const available=sum(scope,true),total=sum('all',false),pool=sum('pool',false),assigned=sum('assigned',false);
  const requested=Number(find('#recallCount').value),validCount=Number.isInteger(requested)&&requested>=1&&requested<=1000;
  find('#recallAvailableTitle').textContent=selectedStates?.size===0?'Select a state to continue':available.toLocaleString()+' leads match your filters';
  find('#recallFolderTotals').textContent='Folder total across all states: '+total.toLocaleString()+' open · '+pool.toLocaleString()+' unassigned · '+assigned.toLocaleString()+' assigned.';
  find('#recallQuantityHelp').textContent=selectedStates?.size===0?'Check a state or All states to enable Preview.':!validCount?'Enter a quantity from 1 to 1,000.':available<requested?'You requested '+requested.toLocaleString()+', but only '+available.toLocaleString()+' match. The preview will contain '+available.toLocaleString()+'.':'The preview will contain up to '+Math.min(requested,available).toLocaleString()+' leads.';
  find('#recallIncludeAssigned').hidden=scope!=='pool'||assigned===0;
  find('#recallIncludeAssigned').textContent='Include assigned leads too';
  find('#recallScopeHelp').textContent=scope==='pool'?'Unassigned only. The '+assigned.toLocaleString()+' assigned leads in this folder are excluded.':scope==='assigned'?'Assigned only. Unassigned leads in the agency pool are excluded.':'Includes both unassigned leads and leads currently held by agents or admins.';
  find('#recallNote').textContent='Oldest matching leads first, up to 1,000 at a time. '+(scope==='pool'?'': 'Assigned leads will be removed from the current agent or admin. ')+'Notes, lead statuses, and folder details stay with each lead. Closed business is excluded.';
 };
 const drawStates=()=>{
  const focused=document.activeElement,restoreFocus=focused?.closest('#recallStates')?{all:focused.id==='recallAllStates',state:focused.value}:null;
  const type=find('#recallType').value,scope=find('#recallScope').value,counts=new Map();
  const chosen=type==='all'?folders:[folders[Number(type)]].filter(Boolean);
  for(const folder of chosen)for(const state of folder.states||[]){const count=Number(scope==='all'?state.count:state[scope]||0);if(count)counts.set(state.state,(counts.get(state.state)||0)+count);}
  for(const state of selectedStates||[])if(!counts.has(state))counts.set(state,0);
  find('#recallStates').innerHTML='<label><input id="recallAllStates" type="checkbox" '+(selectedStates===null?'checked':'')+'><span>All states</span></label>'+Array.from(counts).sort((a,b)=>a[0].localeCompare(b[0])).map(([state,count])=>'<label><input class="recallState" type="checkbox" value="'+esc(state)+'" '+(selectedStates?.has(state)?'checked':'')+'><span>'+esc(state||'State not set')+'</span><small>'+count.toLocaleString()+'</small></label>').join('');
  find('#recallAllStates').onchange=e=>{selectedStates=e.target.checked?null:new Set();invalidate();drawStates();};
  root.querySelectorAll('.recallState').forEach(input=>input.onchange=()=>{
   if(selectedStates===null)selectedStates=new Set();
   if(input.checked)selectedStates.add(input.value);else selectedStates.delete(input.value);
   invalidate();drawStates();
  });
  find('#recallStatesHelp').textContent=selectedStates===null?'All available states are included. Choose states below to narrow the recall.':selectedStates.size?'Selected: '+Array.from(selectedStates).map(s=>s||'State not set').join(', '):'Choose at least one state, or select All states.';
  updateAvailability();
  updateControls();
  if(restoreFocus){const input=restoreFocus.all?find('#recallAllStates'):Array.from(root.querySelectorAll('.recallState')).find(el=>el.value===restoreFocus.state);input?.focus();}
 };
 find('#recallCancel').onclick=dismiss;root.onclick=e=>{if(e.target===root)dismiss();};
 root.onkeydown=e=>{
  if(e.key==='Escape'){e.preventDefault();dismiss();}
  if(e.key==='Tab'){
   const items=Array.from(root.querySelectorAll('button,input,select')).filter(el=>!el.disabled&&!el.hidden),first=items[0],last=items.at(-1);
   if(e.shiftKey&&document.activeElement===first){e.preventDefault();last?.focus();}
   else if(!e.shiftKey&&document.activeElement===last){e.preventDefault();first?.focus();}
  }
 };
 for(const id of ['recallType','recallScope','recallCount'])find('#'+id).oninput=invalidate;
 for(const id of ['recallType','recallScope'])find('#'+id).onchange=()=>{invalidate();drawStates();};
 find('#recallCount').oninput=()=>{invalidate();updateAvailability();};
 find('#recallIncludeAssigned').onclick=()=>{if(busy||loading)return;find('#recallScope').value='all';invalidate();drawStates();};
 find('#agencyRecallForm').onsubmit=async e=>{
  e.preventDefault();if(busy||loading||!valid())return;
  if(selectedStates?.size===0){message('Choose at least one state, or select All states.',true);return;}
  const count=Number(find('#recallCount').value);
  if(!Number.isInteger(count)||count<1||count>1000){message('Enter a whole number from 1 to 1,000.',true);return;}
  invalidate();const version=generation;busy=true;updateControls();message('Preparing your preview…');
  try{
   const type=find('#recallType').value;
   const result=await api('/rest/v1/rpc/agency_recall_preview_states',{method:'POST',body:{p_source:source,p_type:type==='all'?null:folders[Number(type)].type,p_scope:find('#recallScope').value,p_count:count,p_states:selectedStates===null?null:Array.from(selectedStates)}});
   if(!valid()||generation!==version)return;
   const leads=result.leads||[];
   if(!leads.length){message('No open leads match these filters.');return;}
   preview=leads.map(l=>({id:l.id,updated_at:l.updated_at}));requestId=crypto.randomUUID();
   const assigned=leads.filter(l=>l.assigned_to).length;
   message(leads.length.toLocaleString()+' leads ready to return · '+assigned.toLocaleString()+' currently assigned · '+Number(result.available).toLocaleString()+' available'+(leads.length<count?' (fewer than requested)':''));
   find('#recallPreview').innerHTML='<div class="agency-recall-table" tabindex="0" aria-label="Leads to take back"><table><thead><tr><th>Lead</th><th>State</th><th>Folder</th><th>Currently with</th></tr></thead><tbody>'+leads.map(l=>'<tr><td><strong>'+esc([l.first_name,l.last_name].filter(Boolean).join(' ')||'Unnamed lead')+'</strong><small>'+esc(l.phone||'No phone')+'</small></td><td>'+esc(l.state||'State not set')+'</td><td>'+esc(l.lead_type||'Untitled folder')+'</td><td>'+esc(l.assignee)+'</td></tr>').join('')+'</tbody></table></div><p class="small muted">These exact leads will return to the unassigned Owner / Master pool.</p>';
   find('#recallPreview').hidden=false;find('#recallConfirm').hidden=false;find('#recallConfirm').textContent='Take back '+leads.length.toLocaleString()+' leads';
  }catch(error){if(valid())message(error.message,true);}
  finally{busy=false;if(valid())updateControls();}
 };
 find('#recallConfirm').onclick=async()=>{
  if(busy||!preview||!requestId||!valid())return;
  busy=true;updateControls();message('Returning leads to Owner / Master…');
  let completed=false;
  try{
   const count=await api('/rest/v1/rpc/agency_recall_commit',{method:'POST',body:{p_source:source,p_leads:preview,p_request_id:requestId}});
   if(!valid())return;
   completed=true;S.selected.clear();root.remove();
   await reload(Number(count).toLocaleString()+' leads taken back from '+agency.name+' into Owner / Master.');
  }catch(error){
   if(completed){if(S.profile?.id===user&&portalSessionEpoch===epoch)flash('The leads were taken back. Reload the page to refresh the list.',true);}
   else if(valid()){
    if(error.code==='40001')invalidate();
    message(error.message+(error.code==='40001'?'':' You can retry this same recall safely.'),true);
   }
  }finally{busy=false;if(valid())updateControls();}
 };
 try{
  folders=await api('/rest/v1/rpc/agency_recall_options',{method:'POST',body:{p_source:source}})||[];
  if(!valid())return;
  find('#recallType').innerHTML='<option value="all">All folders</option>'+folders.map((f,i)=>'<option value="'+i+'">'+esc(f.type||'Untitled folder')+' ('+Number(f.count).toLocaleString()+')</option>').join('');
  loading=false;drawStates();message(folders.length?'Choose a folder, states, and quantity, then preview the leads.':'This agency has no open leads to take back.');find('#recallType').focus();
 }catch(error){if(valid())message(error.message,true);}
}
