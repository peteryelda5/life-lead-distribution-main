function requestDeliveryBatches(inventory,source){
  const batches=[];
  for(const row of inventory.filter(x=>x.source===source)){
    let batch=batches.find(x=>x.lead_type===row.lead_type);
    if(!batch){batch={lead_type:row.lead_type,count:0,states:[]};batches.push(batch)}
    batch.count+=Number(row.lead_count);batch.states.push({state:row.state,count:Number(row.lead_count)});
  }
  return batches.sort((a,b)=>(a.lead_type??'Unlabeled').localeCompare(b.lead_type??'Unlabeled'));
}
async function fulfillLeadRequestModal(id){
  if(S.profile?.role!=='admin'||q('#modal'))return;
  const user=S.profile.id;
  modal('<h2>Add leads</h2><p role="status">Loading available leads…</p><button id="deliveryCancel" class="btn secondary">Cancel</button>');
  const panel=q('#modal');q('#deliveryCancel').onclick=closeModal;
  try{
    const data=await api('/rest/v1/rpc/lead_request_delivery_options',{method:'POST',body:{p_request_id:id}});
    if(!panel.isConnected||S.profile?.id!==user)return;
    const r=data.request,inventory=data.inventory||[],remaining=Number(r.quantity)-Number(r.fulfilled_quantity||0);
    const sources=[...new Map(inventory.map(x=>[x.source,{id:x.source,name:x.source_name}])).values()];
    const matching=inventory.filter(x=>String(x.lead_type??'').trim().toLowerCase()===r.lead_type.trim().toLowerCase());
    const initialSource=matching.find(x=>x.source===r.division)?.source||matching.find(x=>x.source==='owner')?.source||matching[0]?.source||sources.find(x=>x.id===r.division)?.id||sources[0]?.id||'';
    panel.querySelector('.modalbox').innerHTML='<h2>Add leads to '+esc(r.agent_name)+'</h2><div class="request-delivery-summary"><p><strong>'+Number(r.quantity).toLocaleString()+' '+esc(r.lead_type)+' leads requested</strong></p><p>'+esc(divisionLabel(r.division))+' · '+Number(r.fulfilled_quantity||0).toLocaleString()+' sent · '+remaining.toLocaleString()+' remaining</p>'+(r.note?'<p><strong>Agent’s note:</strong> '+esc(r.note)+'</p>':'')+'</div><form id="deliveryForm" class="stack request-delivery-form"><div class="request-delivery-fields"><div class="field"><label for="deliverySource">Send from</label><select id="deliverySource" required>'+sources.map(x=>'<option value="'+esc(x.id)+'">'+esc(x.name)+'</option>').join('')+'</select></div><div class="field"><label for="deliveryBatch">Lead type / batch</label><select id="deliveryBatch" required></select></div></div><fieldset><legend>States</legend><div id="deliveryStates" class="request-delivery-states"></div></fieldset><div class="field"><label for="deliveryQuantity">Leads to send now</label><input id="deliveryQuantity" type="number" required min="1" max="'+Math.min(1000,remaining)+'" step="1" value="'+Math.min(1000,remaining)+'"></div><div id="deliveryAvailability" class="request-delivery-availability" role="status"></div><p class="muted">Leads go directly into this agent’s My Leads. Send up to 1,000 at a time. The request is marked handled when the full quantity is sent.</p><div id="deliveryError" role="alert"></div><div class="row"><button type="button" id="deliveryCancel" class="btn secondary">Cancel</button><button type="submit" id="deliverySend" class="btn primary" disabled>Send leads</button></div></form>';
    const source=q('#deliverySource'),batchSelect=q('#deliveryBatch'),quantity=q('#deliveryQuantity'),send=q('#deliverySend'),availability=q('#deliveryAvailability'),error=q('#deliveryError');
    let batches=[],busy=false,needsRefresh=false;
    const batch=()=>batchSelect.value===''?null:batches[Number(batchSelect.value)];
    const selectedStates=()=>qa('.deliveryState:checked').map(x=>x.value);
    const update=()=>{
      const chosen=batch(),states=selectedStates(),available=chosen?chosen.states.filter(x=>!states.length||states.includes(x.state)).reduce((n,x)=>n+x.count,0):0;
      const n=Number(quantity.value),valid=!!chosen&&Number.isInteger(n)&&n>0&&n<=Math.min(1000,remaining)&&n<=available;
      send.disabled=busy||needsRefresh||!valid;send.textContent=busy?'Sending…':'Send '+(Number.isInteger(n)&&n>0?n.toLocaleString():'')+' leads';
      availability.className='request-delivery-availability'+(chosen&&n>available?' error':'');
      availability.textContent=!sources.length?'No unassigned leads are available in an agency you can use.':!chosen?'Choose the batch you want to send.':available.toLocaleString()+' leads available'+(n>available?' — lower the quantity or choose another batch/state.':'.');
    };
    const drawStates=()=>{
      const states=batch()?.states||[];
      q('#deliveryStates').innerHTML='<label><input id="deliveryAllStates" type="checkbox" checked>All states</label>'+states.map(x=>'<label><input class="deliveryState" type="checkbox" value="'+esc(x.state)+'">'+esc(x.state||'Unknown')+' <small>('+x.count.toLocaleString()+')</small></label>').join('');
      q('#deliveryAllStates').onchange=()=>{qa('.deliveryState').forEach(x=>x.checked=false);q('#deliveryAllStates').checked=true;update()};
      qa('.deliveryState').forEach(x=>x.onchange=()=>{q('#deliveryAllStates').checked=selectedStates().length===0;update()});update();
    };
    const drawBatches=()=>{
      batches=requestDeliveryBatches(inventory,source.value);
      batchSelect.innerHTML='<option value="">Choose a batch</option>'+batches.map((x,i)=>'<option value="'+i+'">'+esc(x.lead_type??'Unlabeled')+' ('+x.count.toLocaleString()+')</option>').join('');
      const match=batches.findIndex(x=>String(x.lead_type??'').trim().toLowerCase()===r.lead_type.trim().toLowerCase());
      batchSelect.value=match<0?'':String(match);drawStates();
    };
    source.value=initialSource;source.onchange=drawBatches;batchSelect.onchange=drawStates;quantity.oninput=update;
    q('#deliveryCancel').onclick=()=>{if(!busy)closeModal()};
    panel.onclick=e=>{if(e.target===panel&&!busy)closeModal()};
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
        q('#deliveryCancel').disabled=false;q('#deliveryCancel').textContent='Close';update();return;
      }
      closeModal();
      const message=Number(result.sent).toLocaleString()+' leads sent to '+result.agent_name+'. '+(result.status==='completed'?'Request handled.':Number(result.remaining).toLocaleString()+' still requested.');
      try{await reload(message);void refreshRequestBadge()}catch{flash(message+' Refresh requests to see the updated list.')}
    };
    drawBatches();
  }catch(x){if(panel.isConnected){closeModal();flash(x.message,true)}}
}
