/* The server authorizes the caller's live role and each exact assignment again. */
(()=>{
 'use strict';
 const eligible=()=>S.profile?.role==='admin'||(S.profile?.role==='agent'&&S.profile.is_team_leader===true);
 const button=()=>eligible()?'<button id="returnMyLeads" class="btn secondary" '+(!Number(S.myCount)?'disabled':'')+'>Return to agency pool</button>':'';
 let opening=false;
 async function open(){
  if(opening||!eligible()||S.tab!=='my-leads')return;
  opening=true;
  const user=S.profile.id,epoch=portalSessionEpoch,opener=document.activeElement;
  const sameAccount=()=>S.profile?.id===user&&portalSessionEpoch===epoch&&eligible();
  try{
   if(window.PortalCallNotes&&!await window.PortalCallNotes.flushAll()){
    if(sameAccount()){flash('Save or resolve your call notes before returning leads.',true);window.PortalCallNotes.openReview();}return;
   }
   if(!sameAccount()||S.tab!=='my-leads')return;
   const filters={p_search:(S.mySearch||'').trim(),p_lead_type:S.myFolder?.type??null,p_folder:S.myFolder!==null,p_page:S.myPage||1,p_limit:500,p_states:[...(S.myStates||[])]};
   closeModal();modal('<h2 id="leadReturnTitle">Return to agency pool</h2><p class="lead-return-intro">Choose your leads below. They will leave My Leads and become available in the agency pool shown for each lead. Notes and call statuses stay with them. Closed business cannot be returned.</p><p id="leadReturnFilters" class="muted small"></p><div id="leadReturnMessage" role="status" aria-live="polite">Loading your current page…</div><div id="leadReturnPreview" hidden></div><div class="lead-return-actions"><button id="leadReturnCancel" class="btn secondary" type="button">Cancel</button><button id="leadReturnConfirm" class="btn primary" type="button" disabled>Return selected leads</button></div>');
   const root=q('#modal'),find=s=>root.querySelector(s),box=find('.modalbox');
   root.classList.add('lead-return-modal');box.setAttribute('role','dialog');box.setAttribute('aria-modal','true');box.setAttribute('aria-labelledby','leadReturnTitle');
   find('#leadReturnFilters').textContent='Page '+filters.p_page+' · '+(filters.p_folder?(filters.p_lead_type||'Untitled folder'):'All folders')+' · '+(filters.p_states.length?filters.p_states.map(s=>s||'State not set').join(', '):'All states')+(filters.p_search?' · Search: '+filters.p_search:'');
   let leads=[],selected=new Set(),requestId=null,frozen=null,busy=false,stale=false;
   const valid=()=>root.isConnected&&sameAccount();
   const message=(value,error=false)=>{find('#leadReturnMessage').textContent=value;find('#leadReturnMessage').className=error?'error':'muted small';};
   const controls=()=>{
    const confirm=find('#leadReturnConfirm');confirm.disabled=busy||stale||!selected.size;confirm.textContent='Return '+selected.size.toLocaleString()+' selected leads';
    find('#leadReturnCancel').disabled=busy;
    root.querySelectorAll('#leadReturnPreview input').forEach(input=>input.disabled=busy||stale||!!frozen);
    root.setAttribute('aria-busy',String(busy));
   };
   const dismiss=()=>{if(busy)return;root.remove();if(opener?.isConnected)opener.focus();};
   find('#leadReturnCancel').onclick=dismiss;root.onclick=e=>{if(e.target===root)dismiss();};
   root.onkeydown=e=>{
    if(e.key==='Escape'){e.preventDefault();dismiss();}
    if(e.key==='Tab'){
     const items=Array.from(root.querySelectorAll('input,button')).filter(el=>!el.disabled&&!el.hidden),first=items[0],last=items.at(-1);
     if(e.shiftKey&&document.activeElement===first){e.preventDefault();last?.focus();}
     else if(!e.shiftKey&&document.activeElement===last){e.preventDefault();first?.focus();}
    }
   };
   find('#leadReturnConfirm').onclick=async()=>{
    if(busy||stale||!selected.size||!valid())return;
    if(window.PortalCallNotes?.hasPending()){stale=true;message('You have unsaved call notes. Close this window, save them, and open a new preview.',true);controls();return;}
    // Freeze exact IDs/versions and keep the same request ID on a network retry.
    if(!frozen){frozen=leads.filter(l=>selected.has(l.id)).map(l=>({id:l.id,updated_at:l.updated_at}));requestId=crypto.randomUUID();}
    busy=true;controls();message('Returning selected leads…');let completed=false;
    try{
     const count=await api('/rest/v1/rpc/return_my_leads_to_pool',{method:'POST',body:{p_leads:frozen,p_request_id:requestId}});
     if(!valid())return;
     completed=true;root.remove();await reload(Number(count).toLocaleString()+' lead'+(Number(count)===1?'':'s')+' returned to the agency pool.');
    }catch(error){
     if(completed){if(sameAccount())flash('The leads were returned. Reload the page to refresh My Leads.',true);}
     else if(valid()){stale=error.code==='40001';message(error.message+(stale?'':' Retry to safely check this same return, or close the window.'),true);}
    }finally{busy=false;if(valid())controls();}
   };
   try{
    const result=await api('/rest/v1/rpc/my_assigned_leads_filtered',{method:'POST',body:filters});
    if(!valid())return;
    leads=(result.data||[]).filter(l=>l.assigned_to===user&&l.status==='assigned'&&l.updated_at);
    if(!leads.length){message('No open leads are available on this page. Close this window and refresh My Leads.');return;}
    selected=new Set(leads.map(l=>l.id));
    find('#leadReturnPreview').innerHTML='<label class="lead-return-select-all"><input id="leadReturnAll" type="checkbox" checked> Select all '+leads.length.toLocaleString()+' leads on this page</label><div class="lead-return-table"><table><thead><tr><th>Select</th><th>Lead</th><th>Folder / State</th><th>Return to</th></tr></thead><tbody>'+leads.map((l,i)=>'<tr><td><input class="leadReturnCheck" type="checkbox" data-index="'+i+'" aria-label="Select '+esc([l.first_name,l.last_name].filter(Boolean).join(' ')||'lead')+'" checked></td><td><strong>'+esc([l.first_name,l.last_name].filter(Boolean).join(' ')||'Unnamed lead')+'</strong><small>'+esc(l.phone||'No phone')+'</small></td><td>'+esc(l.lead_type||'Untitled folder')+'<small>'+esc(l.state||'State not set')+'</small></td><td>'+esc(divisionLabel(l.division))+' pool</td></tr>').join('')+'</tbody></table></div>';
    find('#leadReturnPreview').hidden=false;
    const selectAll=find('#leadReturnAll');
    const selectionChanged=()=>{selectAll.checked=selected.size===leads.length;selectAll.indeterminate=selected.size>0&&selected.size<leads.length;message(selected.size.toLocaleString()+' selected. Only these leads will be returned.');controls();};
    selectAll.onchange=()=>{if(busy||frozen||stale)return;selected=new Set(selectAll.checked?leads.map(l=>l.id):[]);root.querySelectorAll('.leadReturnCheck').forEach(input=>input.checked=selectAll.checked);selectionChanged();};
    root.querySelectorAll('.leadReturnCheck').forEach(input=>input.onchange=()=>{if(busy||frozen||stale)return;const lead=leads[Number(input.dataset.index)];if(input.checked)selected.add(lead.id);else selected.delete(lead.id);selectionChanged();});
    selectionChanged();selectAll.focus();
   }catch(error){if(valid())message(error.message,true);}
  }finally{opening=false;}
 }
 window.PortalLeadReturn={button,open,bind(){const control=q('#returnMyLeads');if(control&&eligible())control.onclick=open;}};
})();
