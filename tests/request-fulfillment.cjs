'use strict';
const assert=require('node:assert/strict'),fs=require('node:fs'),vm=require('node:vm');
const {JSDOM}=require('jsdom');
const dom=new JSDOM('<!doctype html><body></body>'),document=dom.window.document;
const q=s=>document.querySelector(s),qa=s=>Array.from(document.querySelectorAll(s));
const request={id:'request-1',agent_name:'Agent <script>unsafe</script>',division:'vivid_life',lead_type:'PRO9',quantity:100,fulfilled_quantity:0,note:'TX preferred <img src=x>',status:'pending'};
let options={request,inventory:[{source:'owner',source_name:'Owner / Master',lead_type:'PRO9',state:'TX',lead_count:80},{source:'owner',source_name:'Owner / Master',lead_type:'PRO9',state:'FL',lead_count:60},{source:'vivid_life',source_name:'Vivid Life',lead_type:'Other',state:'MI',lead_count:200}]};
let calls=[],resolveSend,sendError=null,reloadError=false,reloads=[],flashes=[],openCount=0;
const S={profile:{id:'admin',role:'admin'},requests:[request],requestPage:1,requestCount:1};
const ctx=vm.createContext({S,document,console,q,qa,URLSearchParams,Map,Set,
  esc:s=>String(s).replaceAll('&','&amp;').replaceAll('<','&lt;').replaceAll('>','&gt;').replaceAll('"','&quot;'),
  divisionLabel:s=>s,pager:()=>'',pageCount:()=>1,
  modal:html=>{openCount++;document.body.insertAdjacentHTML('beforeend','<div id="modal"><div class="modalbox">'+html+'</div></div>')},
  closeModal:()=>q('#modal')?.remove(),
  api:async(path,{body})=>{calls.push({path,body:JSON.parse(JSON.stringify(body))});if(path.endsWith('delivery_options'))return structuredClone(options);if(sendError)throw new Error(sendError);return new Promise(resolve=>resolveSend=resolve)},
  reload:async message=>{if(reloadError)throw Error('Reload failed');reloads.push(message)},
  refreshRequestBadge:async()=>{},flash:message=>flashes.push(message),
});
vm.runInContext(fs.readFileSync('team-leaders.js','utf8'),ctx);
// The badge refresh uses other portal globals; it is not part of this form test.
vm.runInContext('refreshRequestBadge=async()=>{}',ctx);
vm.runInContext(fs.readFileSync('request-fulfillment.js','utf8'),ctx);
const run=s=>vm.runInContext(s,ctx),event={preventDefault(){}};
(async()=>{
  const page=run('leadRequestsPage()');assert(page.includes('Add leads'));assert(!page.includes('Agent <script>'));
  S.profile.role='agent';S.profile.is_team_leader=true;assert(!run('leadRequestsPage()').includes('fulfillRequest'));S.profile.role='admin';
  await run("fulfillLeadRequestModal('request-1')");
  assert.equal(q('#deliverySource').value,'owner');assert.equal(q('#deliveryBatch').selectedOptions[0].textContent,'PRO9 (140)');assert.equal(q('#deliveryQuantity').value,'100');assert(!q('#deliverySend').disabled);
  assert(!q('#modal script'));assert(!q('#modal img'));assert(q('#modal').textContent.includes('TX preferred <img src=x>'));
  await run("fulfillLeadRequestModal('request-1')");assert.equal(openCount,1,'double-click must not open a second dialog');
  q('.deliveryState[value="TX"]').checked=true;q('.deliveryState[value="TX"]').onchange();
  assert(!q('#deliveryAllStates').checked);assert(q('#deliverySend').disabled);assert(q('#deliveryAvailability').textContent.includes('80 leads available'));
  q('#deliveryQuantity').value='50';q('#deliveryQuantity').oninput();assert(!q('#deliverySend').disabled);
  const sending=q('#deliveryForm').onsubmit(event);assert(q('#deliverySend').disabled);assert(q('#deliveryCancel').disabled);
  await q('#deliveryForm').onsubmit(event);assert.equal(calls.filter(x=>x.path.endsWith('fulfill_lead_request')).length,1);
  assert.deepEqual(calls.at(-1).body,{p_request_id:'request-1',p_source:'owner',p_lead_type:'PRO9',p_states:['TX'],p_quantity:50,p_expected_fulfilled:0});
  resolveSend({sent:50,agent_name:'Agent',status:'pending',remaining:50});await sending;assert(!q('#modal'));assert(reloads.at(-1).includes('50 still requested'));
  options.request.fulfilled_quantity=50;S.requests=[options.request];assert(run('leadRequestsPage()').includes('50 sent'));
  await run("fulfillLeadRequestModal('request-1')");assert.equal(q('#deliveryQuantity').value,'50');
  q('.deliveryState[value="TX"]').checked=true;q('.deliveryState[value="TX"]').onchange();
  q('#deliveryAllStates').onchange();assert.equal(qa('.deliveryState:checked').length,0);
  q('#deliverySource').value='vivid_life';q('#deliverySource').onchange();assert.equal(q('#deliveryBatch').value,'');assert(q('#deliverySend').disabled);
  q('#deliveryBatch').value='0';q('#deliveryBatch').onchange();assert(!q('#deliverySend').disabled);assert.equal(qa('.deliveryState').length,1);
  sendError='Connection lost';await q('#deliveryForm').onsubmit(event);assert(q('#deliverySend').disabled);assert(q('#deliveryError').textContent.includes('reopen Add leads'));assert(!q('#deliveryCancel').disabled);
  const n=calls.length;await q('#deliveryForm').onsubmit(event);assert.equal(calls.length,n,'lost-response retries must refresh first');q('#deliveryCancel').onclick();
  sendError=null;reloadError=true;await run("fulfillLeadRequestModal('request-1')");const success=q('#deliveryForm').onsubmit(event);resolveSend({sent:50,agent_name:'Agent',status:'completed',remaining:0});await success;
  assert(flashes.at(-1).includes('50 leads sent to Agent. Request handled.'));assert(!q('#modal'));
  options.inventory=[];await run("fulfillLeadRequestModal('request-1')");assert(q('#deliverySend').disabled);assert(q('#deliveryAvailability').textContent.includes('No unassigned leads'));q('#deliveryCancel').onclick();
  S.profile.role='agent';await run("fulfillLeadRequestModal('request-1')");assert(!q('#modal'));
  console.log('PASS: request button/permissions, escaped content, prefilled recipient/batch/quantity, state availability, explicit batch selection, partial progress, double-click protection, uncertain-send recovery and empty inventory.');
})().catch(e=>{console.error(e);process.exitCode=1});
