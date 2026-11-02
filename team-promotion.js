/* Owner-only promotion. The server rechecks roles, roster and destination atomically. */
let teamPromotionRequest=0;
function canPromoteTeamLeader(a){return !!(S.profile?.role==='admin'&&S.profile.is_super_admin&&S.profile.active&&!S.profile.archived&&a?.is_team_leader&&a.active&&!a.archived);}
async function promoteTeamModal(id){
 const agent=S.agents.find(a=>a.id===id);if(!canPromoteTeamLeader(agent))return;
 const request=++teamPromotionRequest,owner=S.profile.id,epoch=portalSessionEpoch;
 modal('<h2>Promote &amp; move team</h2><div id="promotionLoading" role="status">Loading the current team…</div><button id="promotionCancel" type="button" class="btn secondary">Cancel</button>');
 const loading=q('#promotionLoading');q('#promotionCancel').onclick=closeModal;
 let preview;
 try{preview=await api('/rest/v1/rpc/team_admin_promotion_preview',{method:'POST',body:{p_leader:id}});}catch(e){if(loading.isConnected){loading.className='error';loading.textContent=e.message;}return;}
 if(!loading.isConnected||request!==teamPromotionRequest||owner!==S.profile?.id||epoch!==portalSessionEpoch)return;
 const members=preview.members||[],agencies=preview.agencies||[];
 modal('<h2>Promote &amp; move team</h2><p><strong>'+esc(preview.leader.name)+'</strong> will become an agency admin using the same account.</p><form id="promotionForm" class="stack"><div class="field"><label for="promotionAgency">Destination agency</label><select id="promotionAgency"><option value="">Create a new agency</option>'+agencies.map(a=>'<option value="'+esc(a.id)+'">'+esc(a.name)+'</option>').join('')+'</select></div><div id="promotionNameField" class="field"><label for="promotionName">New agency name</label><input id="promotionName" required minlength="2" maxlength="80" placeholder="Enter the new agency name"></div><div class="notice" id="promotionAccess" role="status"></div><section aria-label="Team members moving"><strong>'+members.length+' team member'+(members.length===1?'':'s')+' moving</strong><div class="promotion-members">'+(members.length?'<ul>'+members.map(m=>'<li>'+esc(m.name)+(m.archived?' <span class="badge">Archived</span>':!m.active?' <span class="badge red">Disabled</span>':'')+'</li>').join('')+'</ul>':'<p class="muted">This leader has no assigned team members.</p>')+'</div></section><p class="muted small">The team will report directly to this admin in the destination agency. Existing logins, assigned leads, client records and sales stay with each person. Lead source agencies stay unchanged. Pending team lead requests move to the new admin. Disabled and archived accounts keep their status.</p><p class="small">'+Number(preview.open_leads||0).toLocaleString()+' open leads and '+Number(preview.closed_deals||0).toLocaleString()+' recorded deals retained.</p><label class="promotion-confirm"><input id="promotionReviewed" type="checkbox" required> I reviewed the team and destination agency.</label><div id="promotionError" role="alert"></div><div class="row"><button id="promotionCancel" type="button" class="btn secondary">Cancel</button><button id="promotionRefresh" type="button" class="btn secondary">Refresh team</button><button id="promotionSave" class="btn primary">Promote &amp; move team</button></div></form>');
 const form=q('#promotionForm'),select=q('#promotionAgency'),name=q('#promotionName'),check=q('#promotionReviewed');let busy=false;
 const sync=()=>{const existing=agencies.find(a=>a.id===select.value);name.required=!existing;name.disabled=!!existing;q('#promotionNameField').hidden=!!existing;check.checked=false;q('#promotionAccess').textContent=existing?preview.leader.name+' will have agency-admin access to all agents and records normally available to admins in '+existing.name+'.':preview.leader.name+' will administer the new agency. Your Master Admin access stays in place.';};
 select.onchange=sync;name.oninput=()=>{check.checked=false;};sync();
 q('#promotionCancel').onclick=closeModal;q('#promotionRefresh').onclick=()=>promoteTeamModal(id);
 form.onsubmit=async e=>{
  e.preventDefault();if(busy||!form.reportValidity()||!check.checked)return;
  const division=select.value||null,agencyName=division?null:name.value.trim();
  if(division&&!agencies.some(a=>a.id===division)||!division&&agencyName.length<2)return;
  const payload={p_leader:id,p_expected_division:preview.leader.division,p_expected_members:members.map(m=>m.id),p_division:division,p_agency_name:agencyName};
  busy=true;[...form.elements].forEach(el=>el.disabled=true);const error=q('#promotionError');error.textContent='';
  let result;
  try{result=await api('/rest/v1/rpc/promote_team_leader_with_agency',{method:'POST',body:payload});}
  catch(e){if(form.isConnected){error.className='error';error.textContent=e.message+' Refresh the team before trying again.';[...form.elements].forEach(el=>el.disabled=false);sync();}busy=false;return;}
  if(owner!==S.profile?.id||epoch!==portalSessionEpoch)return;
  if(form.isConnected)closeModal();
  S.tab='organization';S.divisionFilter=result.division;ORG.view='hierarchy';ORG.expanded.clear();ORG.expanded.add(result.division);
  const message=preview.leader.name+' is now an admin of '+result.agency_name+'. '+Number(result.members_moved)+' team members moved with them.';
  try{await loadCore();flash(message);}catch{flash(message+' Refresh Management to reload the updated list.',true);}
 };
}
