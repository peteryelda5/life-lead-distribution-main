/* One complete, atomic submission flow for assigned leads and manual/chat deals. */
window.PortalDealIntake=(()=>{
 const today=()=>new Date().toLocaleDateString('en-CA',{timeZone:'America/Detroit'});
 const types=['Final Expense','Term','IUL','Mortgage Protection','Whole Life','Other'];
 const stages=[['submitted','Application submitted'],['approved','Approved'],['in_force','In force']];
 const field=(label,name,type='text',extra='',value='')=>'<label class="bob-field"><span>'+label+'</span><input name="'+name+'" type="'+type+'" '+extra+' value="'+esc(value)+'"></label>';
 const opts=items=>items.map(x=>'<option value="'+esc(x)+'">'+esc(x)+'</option>').join('');
 function leadContact(lead){
  if(!lead)return {};
  const array=v=>{try{const a=typeof v==='string'?JSON.parse(v):v;return Array.isArray(a)?a:[];}catch{return [];}};
  const headers=array(lead.csv_headers),values=array(lead.csv_values),csv=keys=>{
   for(const key of keys){const i=headers.findIndex(h=>String(h).toLowerCase().replace(/[^a-z0-9]/g,'')===key),v=values[i];if(i>=0&&['string','number'].includes(typeof v)&&!['','null','undefined','nan','n/a'].includes(String(v).trim().toLowerCase()))return String(v).trim();}return '';
  };
  return {client_name:[lead.first_name,lead.last_name].filter(Boolean).join(' ').trim()||csv(['fullname','clientname','insuredname','name'])||[csv(['firstname','clientfirstname']),csv(['lastname','clientlastname'])].filter(Boolean).join(' '),phone:lead.phone||csv(['phone','phonenumber','cellphone','mobilephone']),email:lead.email||csv(['email','emailaddress']),state:lead.state||csv(['state']),address_line1:csv(['address','streetaddress','addressline1']),city:csv(['city']),zip:csv(['zip','zipcode','postalcode'])};
 }
 function open({lead=null,division=null,beforeSave=null,afterSave=null}={}){
  const owner=S.profile,epoch=typeof portalSessionEpoch==='undefined'?null:portalSessionEpoch,requestId=crypto.randomUUID(),contact=leadContact(lead);
  const current=()=>S.profile===owner&&(epoch===null||epoch===portalSessionEpoch);
  const catalog=window.PORTAL_CRM_PRODUCTS||[],carriers=[...new Set([...catalog.map(c=>c.carrier),'Aetna','American Home Life','InstaBrain'])].sort((a,b)=>a.localeCompare(b));
  closeModal();
  modal('<div class="deal-intake-heading"><div><span class="deal-intake-eyebrow">CLIENT + POLICY + PRODUCTION</span><h2>Submit a deal</h2><p>'+ (lead?'Review the lead’s details and complete the policy.':'Enter the client once. Their CRM record is created automatically.')+'</p></div><button type="button" class="bob-detail-close" id="dealIntakeClose" aria-label="Close">×</button></div><form id="dealIntakeForm"><div class="deal-intake-layout"><div class="deal-intake-fields"><section><div class="deal-intake-section"><span>1</span><h3>Client information</h3>'+(lead?'<small>Prefilled from your lead</small>':'')+'</div><div class="bob-client-fields">'+field('Client name <em>*</em>','client_name','text','required maxlength="200" autocomplete="name" placeholder="Full client name"',contact.client_name)+field('Phone number <em>*</em>','phone','tel','required maxlength="50" autocomplete="tel" placeholder="123-123-1234"',contact.phone)+'</div><details class="bob-extra"><summary>Additional client details</summary><div class="bob-client-fields">'+field('Email','email','email','maxlength="254" autocomplete="email"',contact.email)+field('Alternate phone','alternate_phone','tel','maxlength="50"')+field('Street address','address_line1','text','maxlength="200" autocomplete="address-line1"',contact.address_line1)+field('Apartment / suite','address_line2','text','maxlength="200"')+field('City','city','text','maxlength="200" autocomplete="address-level2"',contact.city)+field('State','state','text','maxlength="50" autocomplete="address-level1"',contact.state)+field('ZIP code','zip','text','maxlength="20" autocomplete="postal-code"',contact.zip)+field('Date of birth','date_of_birth','date','min="1900-01-01" max="'+today()+'"')+field('Mortgage balance ($)','mortgage_balance','number','min="0" max="999999999999.99" step="0.01"')+'</div></details></section><section><div class="deal-intake-section"><span>2</span><h3>Policy details</h3></div>'+(!lead?'<label class="bob-field deal-credit"><span>Credit this deal to <em>*</em></span><select name="agent_id" required disabled><option value="">Loading agents…</option></select></label>':'')+'<div class="bob-client-fields"><label class="bob-field"><span>Carrier <em>*</em></span><select name="carrier" required><option value="">Select carrier</option>'+opts(carriers)+'</select></label><label class="bob-field"><span>Policy type / product <em>*</em></span><select name="policy_type" required><option value="">Select product</option>'+opts(types)+'</select></label>'+field('Monthly premium ($) <em>*</em>','monthly_payment','number','required min="0.01" max="100000" step="0.01" placeholder="125.00"')+field('Policy / application number','policy_number','text','maxlength="200" placeholder="If available"')+field('Application date <em>*</em>','application_date','date','required min="2000-01-01" max="'+today()+'"',today())+field('Policy effective date <em id="dealEffectiveStar" hidden>*</em>','effective_date','date','min="2000-01-01"')+'<label class="bob-field deal-intake-stage"><span>Agent pipeline stage <em>*</em></span><select name="pipeline_stage" required>'+stages.map(([v,n])=>'<option value="'+v+'">'+n+'</option>').join('')+'</select></label></div><p id="dealStageHint" class="bob-form-hint"></p><label class="bob-field"><span>Policy notes</span><textarea name="notes" maxlength="5000" rows="2" placeholder="Anything helpful for follow-up"></textarea></label></section></div><aside class="deal-intake-summary" aria-label="Submission summary"><span class="deal-intake-eyebrow">LIVE SUMMARY</span><h3 id="dealSummaryName">Your next client</h3><p id="dealSummaryPolicy">Choose a carrier and product</p><div class="deal-intake-premium"><strong id="dealSummaryPremium">$0.00</strong><span>/ month</span></div><span id="dealSummaryStage" class="deal-intake-badge">Application submitted</span><hr><h4>One submission updates</h4><ul><li>Client profile & contact details</li><li>Policy, dates & pipeline stage</li><li>Production & team deal feed</li><li>Comp & advance from saved rates</li></ul><p>Carrier status starts as <strong>Unverified</strong>. Record the carrier’s confirmation separately.</p><p class="deal-intake-private">Client contact details stay in the CRM; they are not posted in team chat.</p></aside></div><div id="dealIntakeError" role="alert"></div><footer class="bob-modal-footer"><span>Required fields are marked <em>*</em></span><button type="button" class="btn secondary" id="dealIntakeCancel">Cancel</button><button type="submit" class="btn primary" id="dealIntakeSave">Submit deal & update CRM</button></footer></form>');
  const box=q('#modal'),form=q('#dealIntakeForm');box.querySelector('.modalbox').classList.add('bob-client-modal','deal-intake-modal');
  const error=box.querySelector('#dealIntakeError'),save=box.querySelector('#dealIntakeSave');let saving=false,agentsReady=!!lead,committed=false;
  const close=()=>{if(!saving)closeModal();};q('#dealIntakeCancel').onclick=q('#dealIntakeClose').onclick=close;
  window.PortalClientPhone?.bind(form);
  // Preserve custom agency carrier resources without blocking the known catalog.
  api('/rest/v1/carrier_resources?select=carrier&order=carrier.asc&limit=1000',{method:'GET'}).then(rows=>{
   if(!current()||!box.isConnected||saving)return;const select=form.elements.carrier,value=select.value;
   const names=[...new Set([...carriers,...rows.map(r=>String(r.carrier||'').trim()).filter(Boolean)])].sort((a,b)=>a.localeCompare(b));select.innerHTML='<option value="">Select carrier</option>'+opts(names);select.value=value;
  }).catch(()=>{});
  const update=()=>{
   const f=form.elements,stage=f.pipeline_stage.value,required=stage!=='submitted';f.effective_date.required=required;f.effective_date.max=stage==='in_force'?today():'';
   q('#dealEffectiveStar').hidden=!required;q('#dealStageHint').textContent=stage==='submitted'?'Effective date can stay blank while the application is pending.':stage==='approved'?'Enter the scheduled effective date. Carrier confirmation is recorded separately.':'Enter the actual effective date; future coverage should stay Approved.';
   q('#dealSummaryName').textContent=f.client_name.value.trim()||'Your next client';q('#dealSummaryPolicy').textContent=[f.carrier.value,f.policy_type.value].filter(Boolean).join(' · ')||'Choose a carrier and product';q('#dealSummaryPremium').textContent=money(Number(f.monthly_payment.value)||0);q('#dealSummaryStage').textContent=stages.find(s=>s[0]===stage)[1];
  };
  form.elements.carrier.addEventListener('change',()=>{const select=form.elements.policy_type,value=select.value,products=(catalog.find(c=>c.carrier===form.elements.carrier.value)?.products||[]).filter(p=>p[2]!=='annuity').map(p=>p[0]+(p[1]?' — '+p[1]:''));select.innerHTML='<option value="">Select product</option>'+(products.length?'<optgroup label="Carrier products">'+opts(products)+'</optgroup>':'')+'<optgroup label="General policy types">'+opts(types.filter(t=>!products.includes(t)))+'</optgroup>';if([...products,...types].includes(value))select.value=value;update();});
  form.addEventListener('input',update);form.addEventListener('change',update);update();
  if(!lead){
   save.disabled=true;
   api('/rest/v1/rpc/chat_deal_agents',{method:'POST',body:{p_division:division}}).then(agents=>{
    if(!current()||!box.isConnected)return;const select=form.elements.agent_id;
    select.innerHTML='<option value="">Select agent</option>'+agents.map(a=>'<option value="'+esc(a.id)+'" '+(a.id===owner.id?'selected':'')+'>'+esc(a.name)+(a.id===owner.id?' (you)':'')+'</option>').join('');select.disabled=false;agentsReady=agents.length>0;save.disabled=!agentsReady;if(!agentsReady)error.textContent='No eligible agents are available in this agency.';
   }).catch(e=>{if(current()&&box.isConnected)error.textContent=e.message+' Close and reopen this form to retry.';});
  }
  form.onsubmit=async event=>{
   event.preventDefault();if(saving||committed||!current()||!agentsReady||!form.reportValidity())return;
   const fields=Object.fromEntries(new FormData(form)),agent=lead?owner.id:fields.agent_id;delete fields.agent_id;
   if(['','client not linked','client details needed'].includes(fields.client_name.trim().toLowerCase())){error.textContent='Enter the client’s full name.';form.elements.client_name.focus();return;}
   if(fields.phone.replace(/\D/g,'').length<7){error.textContent='Enter a valid client phone number.';form.elements.phone.focus();return;}
   fields.monthly_payment=Number(fields.monthly_payment);saving=true;error.textContent='';const buttons=[...box.querySelectorAll('button')];buttons.forEach(b=>b.disabled=true);save.textContent='Saving client & deal…';
   try{
    if(beforeSave)await beforeSave();if(!current())return;
    const result=await api('/rest/v1/rpc/submit_deal_with_client',{method:'POST',body:{p_request_id:requestId,p_fields:fields,p_lead_id:lead?.id||null,p_agent_id:agent,p_division:lead?null:division}});
    committed=true;if(!current())return;if(box.isConnected)closeModal();
    try{if(afterSave)await afterSave(result);else flash('Deal submitted. Client and policy saved to the CRM.');}catch{if(current())flash('Deal and CRM saved. Refresh the page to update the display.',true);}
   }catch(e){if(current()&&box.isConnected){error.textContent=e.message;buttons.forEach(b=>b.disabled=false);save.textContent='Submit deal & update CRM';}}
   finally{saving=false;}
  };
  form.elements.client_name.focus();
 }
 return {open};
})();
