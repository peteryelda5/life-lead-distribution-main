function closedLeadEditForm(deal){
 const l=deal.leads;if(!l||!(S.profile?.role==='admin'||deal.agent_id===S.profile?.id))return;
 const box=q('#modal .modalbox');if(!box)return;
 const field=(name,label,value,type='text')=>'<div class="field"><label for="correct-'+name+'">'+esc(label)+'</label><input id="correct-'+name+'" name="'+name+'" type="'+type+'" value="'+esc(value??'')+'" '+(['first_name','last_name'].includes(name)?'required':'')+'></div>';
 const names=[['first_name','First name'],['last_name','Last name'],['phone','Phone'],['email','Email'],['state','State'],['source','Source'],['lead_type','Lead type / batch']];
 const headers=jsonArray(l.csv_headers),values=jsonArray(l.csv_values);
 box.innerHTML='<h2>Correct lead information</h2><p class="notice">The closed deal and original lead stay in place. Prior values and your reason are saved in correction history. Carrier and premium are not changed here.</p><form id="closedLeadCorrectionForm" class="stack">'+
 '<div class="row">'+names.map(([name,label])=>field(name,label,l[name],name==='email'?'email':'text')).join('')+'</div>'+
 '<div class="field"><label for="correct-notes">Lead notes</label><textarea id="correct-notes" name="notes">'+esc(l.notes??'')+'</textarea></div>'+
 '<h3>Uploaded fields</h3><p class="muted small">These are the lead’s current column values. Changing one does not silently change the matching contact field above; check both when correcting a name, phone, or email.</p>'+
 '<div class="row">'+headers.map((h,i)=>field('csv_'+i,(h||'Column '+(i+1))+' · column '+(i+1),values[i]??'')).join('')+'</div>'+
 '<div class="field"><label for="correctionReason">Reason for correction</label><textarea id="correctionReason" name="reason" minlength="3" maxlength="500" required placeholder="For example: corrected phone number after speaking with client"></textarea></div>'+
 '<div id="correctionError" role="alert"></div><div class="row"><button type="button" id="cancelLeadCorrection" class="btn secondary">Cancel</button><button class="btn primary">Save corrected lead</button></div></form>';
 q('#cancelLeadCorrection').onclick=()=>openClosedDeal(deal.id);
 q('#closedLeadCorrectionForm').onsubmit=async ev=>{
  ev.preventDefault();const form=new FormData(ev.target),button=ev.submitter;
  const payload={};for(const [name] of names)payload[name]=String(form.get(name)??'');
  payload.notes=String(form.get('notes')??'');payload.csv_values=headers.map((_,i)=>String(form.get('csv_'+i)??''));
  if(button)button.disabled=true;
  try{
   const result=await api('/rest/v1/rpc/correct_closed_lead',{method:'POST',body:{p_deal_id:deal.id,p_expected_updated_at:l.updated_at,p_fields:payload,p_reason:String(form.get('reason')||'')}});
   if(!result?.changed){q('#correctionError').className='notice';q('#correctionError').textContent='No lead information changed.';if(button)button.disabled=false;return}
   closeModal();await loadCore();render();S.msg='Lead corrected. Original values are saved in correction history.';await openClosedDeal(deal.id);
  }catch(e){const error=q('#correctionError');if(error){error.className='error';error.textContent=e.message}if(button)button.disabled=false}
 };
}
function correctionSnapshot(snapshot){
 if(!snapshot)return '';
 const items=[['First name',snapshot.first_name],['Last name',snapshot.last_name],['Phone',snapshot.phone],['Email',snapshot.email],['State',snapshot.state],['Source',snapshot.source],['Lead type',snapshot.lead_type],['Notes',snapshot.notes]];
 const h=jsonArray(snapshot.csv_headers),v=jsonArray(snapshot.csv_values);
 return '<div class="row">'+items.map(([k,val])=>'<div class="field"><strong>'+esc(k)+'</strong><div style="white-space:pre-wrap;overflow-wrap:anywhere">'+esc(val??'—')+'</div></div>').join('')+'</div><h4>Uploaded fields</h4><div class="row">'+h.map((label,i)=>'<div class="field"><strong>'+esc(label||'Column '+(i+1))+'</strong><div style="white-space:pre-wrap;overflow-wrap:anywhere">'+esc(v[i]??'—')+'</div></div>').join('')+'</div>';
}
async function loadClosedLeadCorrections(leadId){
 const target=q('#closedCorrectionHistory');if(!target)return;
 try{
  const path='/rest/v1/lead_corrections?select=id,actor_id,reason,created_at,before_data,after_data&lead_id=eq.'+encodeURIComponent(leadId);
  const [first,recent]=await Promise.all([api(path+'&order=id.asc&limit=1'),api(path+'&order=id.desc&limit=20')]);
  if(!target.isConnected)return;
  if(!recent?.length){target.innerHTML='<p class="muted small">No corrections recorded yet.</p>';return}
  const oldest=first?.[0];
  const changed=entry=>{
   const fields=['first_name','last_name','phone','email','state','source','notes','lead_type','csv_values'];
   return fields.filter(k=>JSON.stringify(entry.before_data?.[k])!==JSON.stringify(entry.after_data?.[k])).map(k=>k==='csv_values'?'Uploaded fields':k.replaceAll('_',' ')).join(', ');
  };
  target.innerHTML='<h3>Correction history</h3><p class="muted small">The first recorded values remain available here. Recent changes are shown below.</p><details><summary>Original values before the first correction</summary>'+correctionSnapshot(oldest.before_data)+'</details><div class="stack section">'+recent.map(e=>'<details><summary>'+esc(new Date(e.created_at).toLocaleString())+' · '+esc(e.reason)+' · '+esc(changed(e))+'</summary><p class="muted small">Saved by '+esc(e.actor_id===S.profile.id?S.profile.full_name:S.admins.find(a=>a.id===e.actor_id)?.full_name||'Team member')+'</p><strong>Before</strong>'+correctionSnapshot(e.before_data)+'<strong>After</strong>'+correctionSnapshot(e.after_data)+'</details>').join('')+'</div>';
 }catch(e){if(target.isConnected){target.className='error';target.textContent='Correction history could not be loaded: '+e.message}}
}
function bindClosedLeadCorrection(deal){
 const button=q('#editClosedLead');if(!button||!deal?.leads||!(S.profile?.role==='admin'||deal.agent_id===S.profile?.id))return;
 button.onclick=()=>closedLeadEditForm(deal);
 loadClosedLeadCorrections(deal.leads.id);
}

function closedDealEditForm(deal){
 if(!(S.profile.role==='admin'||deal.agent_id===S.profile.id))return;
 const box=q('#modal .modalbox');if(!box)return;
 const fields=['carrier','policy_type','monthly_premium','application_date','policy_number','notes'];
 const expected=Object.fromEntries(fields.map(k=>[k,deal[k]??null]));
 const input=(name,label,type,attrs='')=>'<label class="bob-field"><span>'+label+'</span><input name="'+name+'" type="'+type+'" value="'+esc(deal[name]??'')+'" '+attrs+'></label>';
 box.innerHTML='<h2>Edit closed deal</h2><form id="editClosedDealForm" class="stack"><div class="row">'+input('carrier','Carrier','text','required maxlength="100"')+input('policy_type','Policy type','text','required maxlength="100"')+input('monthly_premium','Monthly premium','number','required min="0" max="100000" step="0.01"')+input('application_date','Application date','date','required')+input('policy_number','Policy / application number','text','maxlength="100"')+'</div><label class="bob-field"><span>Deal notes</span><textarea name="notes" maxlength="5000">'+esc(deal.notes||'')+'</textarea></label><label class="bob-field"><span>Reason for correction</span><textarea name="reason" minlength="3" maxlength="500" required></textarea></label><p class="muted small">Changes update production and the deal’s advance estimate. Original values are saved in the audit record.</p><div id="closedDealEditError" role="alert"></div><div class="row"><button type="button" class="btn secondary" id="cancelClosedDealEdit">Cancel</button><button class="btn primary">Save deal changes</button></div></form>';
 q('#cancelClosedDealEdit').onclick=()=>openClosedDeal(deal.id);
 q('#editClosedDealForm').onsubmit=async e=>{e.preventDefault();const form=new FormData(e.target),payload=Object.fromEntries(fields.map(k=>[k,form.get(k)]));payload.monthly_premium=Number(payload.monthly_premium);const button=e.submitter;if(button)button.disabled=true;try{await api('/rest/v1/rpc/correct_closed_deal',{method:'POST',body:{p_deal_id:deal.id,p_expected:expected,p_fields:payload,p_reason:form.get('reason')}});closeModal();await loadCore();render();await openClosedDeal(deal.id);}catch(x){q('#closedDealEditError').textContent=x.message;if(button)button.disabled=false;}};
}
function bindClosedDealEdit(deal){const b=q('#editClosedDeal');if(b)b.onclick=()=>closedDealEditForm(deal);}
