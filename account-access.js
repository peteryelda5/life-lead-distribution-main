'use strict';
async function accountDisableModal(id){
 if(S.profile?.role!=='admin'||id===S.profile.id)return;
 const epoch=portalSessionEpoch;
 closeModal();
 modal('<section id="accountDisableLoading" class="stack"><h2>Disable account</h2><p>Checking this account and its records…</p><button type="button" class="btn secondary" id="accountDisableCancel">Cancel</button></section>');
 const loading=q('#accountDisableLoading'),box=loading.closest('.modalbox');
 q('#accountDisableCancel').onclick=closeModal;
 let preview;
 try{preview=await api('/rest/v1/rpc/account_disable_preview',{method:'POST',body:{p_user:id}})}
 catch(e){if(loading.isConnected){closeModal();flash(e.message,true)}return}
 if(!loading.isConnected||epoch!==portalSessionEpoch)return;
 if(!preview.active){closeModal();flash('This account is already disabled. Refresh the account list.',true);return}
 const count=Number(preview.open_leads||0).toLocaleString(),deals=Number(preview.closed_deals||0).toLocaleString();
 box.innerHTML='<form id="accountDisableForm" class="stack account-disable" aria-labelledby="accountDisableTitle">'+
 '<h2 id="accountDisableTitle">Disable account</h2><p><strong>'+esc(preview.name)+'</strong> will lose portal access until you enable this account again.</p>'+
 '<fieldset><legend>What should happen to their leads?</legend>'+
 '<label class="account-disable-choice"><input type="radio" name="disableMode" value="keep" checked><span><strong>Disable and keep all leads and deals</strong><small>Keep every lead assigned to this account. All deals, clients and history stay in place.</small></span></label>'+
 '<label class="account-disable-choice"><input type="radio" name="disableMode" value="reclaim" '+(!preview.can_reclaim?'disabled':'')+'><span><strong>Disable and take back open leads</strong><small>Return '+count+' open leads to their original agency pools for reassignment. Deals, closed leads, client records and history stay with this account.</small></span></label></fieldset>'+
 (!preview.can_reclaim?'<p class="notice">Some leads belong to another agency. A Master Admin must return those leads. You can still disable and keep everything.</p>':'')+
 '<p class="notice">'+deals+' recorded deals preserved in either option. '+(preview.role==='admin'?'Only this admin’s personal leads are affected. Other agency accounts and their leads stay in place.':'Team memberships and other agents’ leads stay in place.')+'</p>'+
 '<p class="muted small">Existing sessions will lose access. Enabling the account later lets them sign in again. Returned leads will stay in the agency pool until reassigned.</p>'+
 '<div id="accountDisableError" role="alert" class="error hidden"></div><div class="row"><button type="button" class="btn secondary" id="accountDisableCancel">Cancel</button><button type="submit" class="btn danger" id="accountDisableSave">Disable and keep everything</button></div></form>';
 const form=q('#accountDisableForm'),save=q('#accountDisableSave'),cancel=q('#accountDisableCancel'),error=q('#accountDisableError');
 const reclaim=()=>form.querySelector('input[name="disableMode"]:checked')?.value==='reclaim';
 cancel.onclick=closeModal;
 form.onchange=()=>{save.textContent=reclaim()?'Disable and take back open leads':'Disable and keep everything'};
 let busy=false;
 form.onsubmit=async event=>{
  event.preventDefault();if(busy||epoch!==portalSessionEpoch||!form.isConnected)return;
  const takeBack=reclaim();if(takeBack&&!preview.can_reclaim)return;
  busy=true;save.disabled=true;cancel.disabled=true;form.querySelector('fieldset').disabled=true;error.classList.add('hidden');save.textContent='Disabling…';
  const overlay=form.closest('.modal');overlay.onclick=null;
  try{
   const result=await api('/rest/v1/rpc/disable_portal_account',{method:'POST',body:{p_user:id,p_reclaim_open_leads:takeBack,p_expected_role:preview.role,p_expected_division:preview.division}});
   if(epoch!==portalSessionEpoch)return;
   if(form.isConnected)closeModal();
   await reload(takeBack?'Account disabled. '+Number(result.reclaimed_leads||0).toLocaleString()+' open leads returned to their agency pools. All deals and client history preserved.':'Account disabled. All leads, deals and client history kept in place.');
  }catch(e){
   if(!form.isConnected||epoch!==portalSessionEpoch)return;
   error.textContent=e.message;error.classList.remove('hidden');busy=false;save.disabled=false;cancel.disabled=false;form.querySelector('fieldset').disabled=false;form.onchange();
   overlay.onclick=e=>{if(e.target===overlay)closeModal()};
  }
 };
 cancel.focus();
}
