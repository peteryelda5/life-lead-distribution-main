const REQUEST_AVAILABILITY={owner:null,epoch:null,sequence:0,status:'idle',rows:{}};
const requestAvailabilityEpoch=()=>typeof portalSessionEpoch==='undefined'?0:portalSessionEpoch;
async function loadLeadRequestAvailability(){
  const state=REQUEST_AVAILABILITY,owner=S.profile?.id,epoch=requestAvailabilityEpoch(),sequence=++state.sequence;
  Object.assign(state,{owner,epoch,status:'loading',rows:{}});
  const ids=S.profile?.role==='admin'?S.requests.filter(r=>r.status==='pending').map(r=>r.id):[];
  if(!ids.length){state.status='ready';return;}
  const current=()=>state.sequence===sequence&&S.profile?.id===owner&&requestAvailabilityEpoch()===epoch;
  try{
    const rows=await api('/rest/v1/rpc/lead_request_availability',{method:'POST',body:{p_request_ids:ids}});
    if(!current())return;
    state.rows=Object.fromEntries((rows||[]).map(r=>[r.request_id,r]));state.status='ready';
  }catch{if(!current())return;state.status='error';}
  if(S.tab==='lead-requests')qa('[data-request-availability]').forEach(cell=>{const r=S.requests.find(r=>r.id===cell.dataset.requestAvailability);if(r)cell.innerHTML=requestAvailabilityHtml(r);});
}
function requestAvailabilityHtml(r){
  if(r.status!=='pending')return '<span class="muted">—</span>';
  const state=REQUEST_AVAILABILITY,current=state.owner===S.profile?.id&&state.epoch===requestAvailabilityEpoch();
  if(!current||state.status==='loading'||state.status==='idle')return '<span class="request-stock-checking">Checking stock…</span>';
  const match=state.rows[r.id];
  if(state.status==='error'||!match)return '<span class="request-stock-checking">Check in Add leads</span>';
  if(!match.can_deliver)return '<div class="request-stock warn"><strong>Review agent</strong><span>Inactive or moved agencies</span></div>';
  const available=Number(match.available),remaining=Number(match.remaining),shortage=Math.max(0,remaining-available),sources=match.sources||[];
  const title=available===0?'No batch match':shortage?'Short by '+shortage.toLocaleString():'Available';
  return '<div class="request-stock '+(shortage?'warn':'ready')+'"><strong>'+title+'</strong><span>'+available.toLocaleString()+' matching · '+remaining.toLocaleString()+' needed</span>'+(sources.length?'<small>'+esc(sources.length===1?sources[0].source_name:sources.length+' source agencies')+'</small>':'')+'</div>';
}
function requestDeliveryBatches(inventory,source){
  const batches=[];
  for(const row of inventory.filter(x=>x.source===source)){
    let batch=batches.find(x=>x.lead_type===row.lead_type);
    if(!batch){batch={lead_type:row.lead_type,count:0,states:[]};batches.push(batch)}
    batch.count+=Number(row.lead_count);batch.states.push({state:row.state,count:Number(row.lead_count)});
  }
  return batches.sort((a,b)=>(a.lead_type??'Unlabeled').localeCompare(b.lead_type??'Unlabeled'));
}
function requestDeliveryRecommendation(inventory,request,needed){
  const key=request.lead_type.trim().toLowerCase(),priority=source=>source===request.division?0:source==='owner'?1:2;
  const matches=[...new Set(inventory.map(r=>r.source))].flatMap(source=>requestDeliveryBatches(inventory,source).filter(b=>String(b.lead_type??'').trim().toLowerCase()===key).map(b=>({...b,source})));
  matches.sort((a,b)=>Number(b.count>=needed)-Number(a.count>=needed)||(a.count<needed&&b.count<needed?b.count-a.count:0)||priority(a.source)-priority(b.source)||b.count-a.count||a.source.localeCompare(b.source));
  return matches[0]||null;
}
async function fulfillLeadRequestModal(id){
  if(S.profile?.role!=='admin'||q('#modal'))return;
  const user=S.profile.id,returnFocus=document.activeElement;
  modal('<h2>Add leads</h2><p role="status">Loading available leads…</p><button id="deliveryCancel" class="btn secondary">Cancel</button>');
  const panel=q('#modal');panel.classList.add('request-delivery-modal');panel.setAttribute('role','dialog');panel.setAttribute('aria-modal','true');panel.setAttribute('aria-label','Add leads');q('#deliveryCancel').onclick=closeModal;
  try{
    const data=await api('/rest/v1/rpc/lead_request_delivery_options',{method:'POST',body:{p_request_id:id}});
    if(!panel.isConnected||S.profile?.id!==user)return;
    const r=data.request,inventory=data.inventory||[],remaining=Number(r.quantity)-Number(r.fulfilled_quantity||0);
    const sources=[...new Map(inventory.map(x=>[x.source,{id:x.source,name:x.source_name}])).values()];
    const recommendation=requestDeliveryRecommendation(inventory,r,Math.min(1000,remaining));
    const initialSource=recommendation?.source||sources.find(x=>x.id===r.division)?.id||sources[0]?.id||'';
    const initials=r.agent_name.trim().split(/\s+/).slice(0,2).map(x=>x[0]).join('');
    panel.querySelector('.modalbox').innerHTML=`
      <header class="request-delivery-header"><div><h2 id="deliveryTitle">Add leads</h2><p>Review and send this request.</p></div><button type="button" id="deliveryClose" class="request-delivery-close" aria-label="Close">×</button></header>
      <form id="deliveryForm" class="request-delivery-form">
        <div class="request-delivery-body">
          <section class="request-delivery-recipient" aria-label="Recipient"><span class="request-delivery-avatar" aria-hidden="true">${esc(initials)}</span><div class="request-delivery-person"><strong>${esc(r.agent_name)}</strong><span>${esc(divisionLabel(r.division))}</span></div><div class="request-delivery-requested"><strong>${Number(r.quantity).toLocaleString()}</strong><span>${esc(r.lead_type)} requested</span></div></section>
          ${Number(r.fulfilled_quantity)>0?'<p class="request-delivery-progress">'+Number(r.fulfilled_quantity).toLocaleString()+' already sent · '+remaining.toLocaleString()+' remaining</p>':''}
          ${r.note?'<p class="request-delivery-note"><strong>Agent’s note</strong>'+esc(r.note)+'</p>':''}
          <div class="request-delivery-fields"><div class="field"><label for="deliverySource">Send from</label><select id="deliverySource" required>${sources.map(x=>'<option value="'+esc(x.id)+'">'+esc(x.name)+'</option>').join('')}</select></div><div class="field"><label for="deliveryBatch">Lead type / batch</label><select id="deliveryBatch" required></select></div></div>
          <fieldset><legend>States <span>Choose one or more</span></legend><div id="deliveryStates" class="request-delivery-states"></div></fieldset>
          <div id="deliveryStock" class="request-delivery-stock" role="status"></div>
          <div class="request-delivery-quantity-row"><div class="field"><label for="deliveryQuantity">Quantity to send</label><input id="deliveryQuantity" type="number" required min="1" max="${Math.min(1000,remaining)}" step="1" value="${Math.min(1000,remaining)}" aria-describedby="deliveryAvailability deliveryStock"></div><div><div id="deliveryAvailability" class="request-delivery-availability" role="status"></div><button type="button" id="deliveryUseAvailable" class="request-use-available" hidden></button></div></div>
          <div class="request-delivery-destination"><svg viewBox="0 0 24 24" aria-hidden="true" fill="none" stroke="currentColor" stroke-width="1.8"><path d="M4 6h6l2 2h8v11H4z"/><path d="M9 13h6m-3-3 3 3-3 3"/></svg><span>Delivered directly to <strong>${esc(r.agent_name.split(' ')[0])}’s My Leads</strong>.<small>${remaining>1000?'Send up to 1,000 at a time. ':''}Full delivery automatically marks this request handled.</small></span></div>
          <div id="deliveryError" role="alert"></div>
        </div><footer class="request-delivery-footer"><button type="button" id="deliveryCancel" class="btn secondary">Cancel</button><button type="submit" id="deliverySend" class="btn primary" disabled>Send leads</button></footer>
      </form>`;
    panel.setAttribute('aria-labelledby','deliveryTitle');panel.removeAttribute('aria-label');
    const source=q('#deliverySource'),batchSelect=q('#deliveryBatch'),quantity=q('#deliveryQuantity'),send=q('#deliverySend'),availability=q('#deliveryAvailability'),error=q('#deliveryError'),stock=q('#deliveryStock'),useAvailable=q('#deliveryUseAvailable');
    let batches=[],busy=false,needsRefresh=false;
    const batch=()=>batchSelect.value===''?null:batches[Number(batchSelect.value)];
    const selectedStates=()=>qa('.deliveryState:checked').map(x=>x.value);
    const update=()=>{
      const chosen=batch(),states=selectedStates(),available=chosen?chosen.states.filter(x=>!states.length||states.includes(x.state)).reduce((n,x)=>n+x.count,0):0;
      const n=Number(quantity.value),valid=!!chosen&&Number.isInteger(n)&&n>0&&n<=Math.min(1000,remaining)&&n<=available;
      send.disabled=busy||needsRefresh||!valid;send.textContent=busy?'Sending…':'Send '+(Number.isInteger(n)&&n>0?n.toLocaleString():'')+' leads';
      availability.className='request-delivery-availability'+(chosen&&n>available?' error':'');
      availability.textContent=!sources.length?'No unassigned leads are available in an agency you can use.':!chosen?'Choose the batch you want to send.':available.toLocaleString()+' leads available'+(n>available?' — '+(n-available).toLocaleString()+' short for this send.':'.');
      const different=chosen&&String(chosen.lead_type??'').trim().toLowerCase()!==r.lead_type.trim().toLowerCase(),shortage=Math.max(0,remaining-available);
      stock.className='request-delivery-stock '+(different||shortage?'warn':'ready');
      const title=!chosen?'Choose a batch to check stock':different?'Different batch selected':shortage?'Short by '+shortage.toLocaleString():'Enough available';
      const detail=!chosen?'Requested: '+r.lead_type+'.':available.toLocaleString()+' available for this batch and states · '+remaining.toLocaleString()+' still requested.'+(different?' The request is for '+r.lead_type+'. Confirm the replacement batch with the agent.':'')+(chosen&&shortage?' A partial delivery keeps the remainder pending.':'');
      stock.innerHTML='<strong>'+esc(title)+'</strong><span>'+esc(detail)+'</span>';
      const usable=Math.min(available,remaining,1000);useAvailable.hidden=!chosen||usable<=0||n<=available;useAvailable.disabled=busy||needsRefresh;useAvailable.textContent='Use '+usable.toLocaleString()+' available';
      useAvailable.onclick=()=>{if(busy||needsRefresh)return;quantity.value=String(usable);update();quantity.focus();};
    };
    const drawStates=()=>{
      const states=batch()?.states||[];
      q('#deliveryStates').innerHTML='<label><input id="deliveryAllStates" type="checkbox" checked><span>All states</span></label>'+states.map(x=>'<label><input class="deliveryState" type="checkbox" value="'+esc(x.state)+'"><span>'+esc(x.state||'Unknown')+'</span><small>'+x.count.toLocaleString()+'</small></label>').join('');
      q('#deliveryAllStates').onchange=()=>{qa('.deliveryState').forEach(x=>x.checked=false);q('#deliveryAllStates').checked=true;update()};
      qa('.deliveryState').forEach(x=>x.onchange=()=>{q('#deliveryAllStates').checked=selectedStates().length===0;update()});update();
    };
    const drawBatches=()=>{
      batches=requestDeliveryBatches(inventory,source.value);
      batchSelect.innerHTML='<option value="">Choose a batch</option>'+batches.map((x,i)=>'<option value="'+i+'">'+esc(x.lead_type??'Unlabeled')+' ('+x.count.toLocaleString()+')</option>').join('');
      const recommended=requestDeliveryRecommendation(inventory.filter(x=>x.source===source.value),r,Math.min(1000,remaining));
      const match=recommended?batches.findIndex(x=>x.lead_type===recommended.lead_type):-1;
      batchSelect.value=match<0?'':String(match);drawStates();
    };
    source.value=initialSource;source.onchange=drawBatches;batchSelect.onchange=drawStates;quantity.oninput=update;
    const dismiss=()=>{if(!busy){closeModal();if(returnFocus?.isConnected)returnFocus.focus()}};
    q('#deliveryCancel').onclick=dismiss;q('#deliveryClose').onclick=dismiss;
    panel.onclick=e=>{if(e.target===panel)dismiss()};
    panel.onkeydown=e=>{
      if(e.key==='Escape'){e.preventDefault();dismiss();return}
      if(e.key!=='Tab')return;
      const controls=Array.from(panel.querySelectorAll('button:not(:disabled),input:not(:disabled),select:not(:disabled)'));
      if(!controls.length){e.preventDefault();return}
      const first=controls[0],last=controls[controls.length-1];
      if(e.shiftKey&&document.activeElement===first){e.preventDefault();last.focus()}
      else if(!e.shiftKey&&document.activeElement===last){e.preventDefault();first.focus()}
    };
    q('#deliveryForm').onsubmit=async e=>{
      e.preventDefault();if(busy||needsRefresh)return;update();if(send.disabled)return;
      const body={p_request_id:r.id,p_source:source.value,p_lead_type:batch().lead_type,p_states:selectedStates(),p_quantity:Number(quantity.value),p_expected_fulfilled:Number(r.fulfilled_quantity||0)};
      busy=true;error.textContent='';update();
      panel.querySelectorAll('input,select,button').forEach(x=>x.disabled=true);
      let result;
      try{result=await api('/rest/v1/rpc/fulfill_lead_request',{method:'POST',body})}
      catch(x){
        // A lost response may still have committed. Require a fresh request before another send.
        busy=false;needsRefresh=true;error.className='error';error.textContent=x.message+' Close this window and reopen Add leads to refresh the request before trying again.';
        q('#deliveryCancel').disabled=false;q('#deliveryClose').disabled=false;q('#deliveryCancel').textContent='Close';update();return;
      }
      closeModal();
      const message=Number(result.sent).toLocaleString()+' leads sent to '+result.agent_name+'. '+(result.status==='completed'?'Request handled.':Number(result.remaining).toLocaleString()+' still requested.');
      try{await reloadLeadRequests(message)}catch{flash(message+' Refresh requests to see the updated list.')}
    };
    drawBatches();quantity.focus();quantity.select();
  }catch(x){if(panel.isConnected){closeModal();flash(x.message,true)}}
}
