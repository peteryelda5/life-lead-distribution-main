/* Super Master transfers the existing account; personal records keep their IDs. */
async function moveAccountAgentModal(id){
 if(S.profile?.role!=='admin'||!S.profile.is_super_admin||id===S.profile.id)return;
 const actor=S.profile.id,epoch=portalSessionEpoch;
 closeModal();modal('<h2>Move / make regular agent</h2><p id="accountMoveLoading">Checking this account and its records…</p><button type="button" id="accountMoveCancel" class="btn secondary">Cancel</button>');
 const loading=q('#accountMoveLoading'),box=loading.closest('.modalbox'),valid=()=>loading.isConnected&&S.profile?.id===actor&&portalSessionEpoch===epoch;
 q('#accountMoveCancel').onclick=closeModal;
 let preview;
 try{preview=await api('/rest/v1/rpc/account_agent_move_preview',{method:'POST',body:{p_user:id}})}catch(e){if(valid()){loading.className='error';loading.textContent=e.message}return}
 if(!valid())return;
 const agencies=preview.agencies||[],blocked=Number(preview.members)>0;
 box.innerHTML='<form id="accountMoveForm" class="stack account-move" aria-labelledby="accountMoveTitle"><h2 id="accountMoveTitle">Move / make regular agent</h2><p><strong>'+esc(preview.name)+'</strong> will use the same account as a <strong>regular agent</strong>.</p>'+
 '<div class="field"><label for="accountMoveAgency">Destination agency</label><select id="accountMoveAgency" required>'+agencies.map(a=>'<option value="'+esc(a.id)+'">'+esc(a.name)+(a.id===preview.division?' (current agency)':'')+'</option>').join('')+'</select></div>'+
 (preview.role==='admin'||preview.is_master_admin?'<p class="notice">Admin and Master permissions will be removed. This person keeps their own leads, deals and clients. The agency pool and other people’s records stay in place.</p>':preview.is_team_leader?'<p class="notice">Team leader permissions will be removed.</p>':'')+
 '<p class="notice"><strong>'+Number(preview.open_leads||0).toLocaleString()+' open leads</strong> and <strong>'+Number(preview.deals||0).toLocaleString()+' recorded deals</strong> stay with this account. Client records, notes and sales history are preserved. Leads keep their original source agencies.</p>'+
 (!preview.active?'<p class="notice">This account is disabled and will remain disabled.</p>':'')+
 (preview.onboarding_needed?'<p class="notice">Agent onboarding is incomplete. This person must complete onboarding before using the agent workspace. Existing waivers and signed documents are preserved.</p>':'')+
 (blocked?'<p class="error">This leader has '+Number(preview.members)+' team members. Reassign them in Team settings before making this person a regular agent.</p>':'')+
 '<label class="account-move-review"><input id="accountMoveReviewed" type="checkbox" required> I reviewed the destination and regular-agent role.</label><div id="accountMoveError" role="alert"></div><div class="row"><button type="button" class="btn secondary" id="accountMoveCancel">Cancel</button><button class="btn primary" id="accountMoveSave" '+(blocked||!agencies.length?'disabled':'')+'>Save move and role</button></div></form>';
 const form=q('#accountMoveForm'),select=q('#accountMoveAgency'),review=q('#accountMoveReviewed'),save=q('#accountMoveSave'),cancel=q('#accountMoveCancel');let busy=false;
 if(agencies.some(a=>a.id===preview.division))select.value=preview.division;
 select.onchange=()=>{review.checked=false};cancel.onclick=closeModal;
 form.onsubmit=async e=>{
  e.preventDefault();if(busy||blocked||!form.isConnected||actor!==S.profile?.id||epoch!==portalSessionEpoch||!form.reportValidity()||!review.checked)return;
  const destination=select.value;if(!agencies.some(a=>a.id===destination))return;
  busy=true;[...form.elements].forEach(el=>el.disabled=true);const overlay=form.closest('.modal');overlay.onclick=null;const error=q('#accountMoveError');error.textContent='';
  let result;
  try{result=await api('/rest/v1/rpc/move_account_as_agent',{method:'POST',body:{p_user:id,p_division:destination,p_expected_role:preview.role,p_expected_division:preview.division}})}
  catch(e){if(form.isConnected){error.className='error';error.textContent=e.message;[...form.elements].forEach(el=>el.disabled=false);review.checked=false;overlay.onclick=e=>{if(e.target===overlay)closeModal()}}busy=false;return}
  if(actor!==S.profile?.id||epoch!==portalSessionEpoch)return;
  if(form.isConnected)closeModal();S.tab='organization';S.divisionFilter=result.division;ORG.view='list';ORG.list='agents';
  const message=preview.name+' is now a regular agent in '+result.agency_name+'. Leads, deals and client history preserved.'+(result.sign_in_again?' They should sign in again.':'')+(result.onboarding?.required&&!result.onboarding?.allowed?' Agent onboarding must be completed.':'');
  try{await loadCore();flash(message)}catch{flash(message+' Refresh Management to reload the list.',true)}
 };
 cancel.focus();
}
