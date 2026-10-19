'use strict';
const fs=require('node:fs'),assert=require('node:assert/strict'),{JSDOM}=require('jsdom');
(async()=>{
 const dom=new JSDOM('<body><button id="launcher">Open</button></body>',{url:'https://www.lldportal.com',runScripts:'outside-only'}),w=dom.window;
 try{
  w.S={profile:{id:'self',role:'admin',is_team_leader:false},tab:'my-leads',myCount:2,mySearch:'test',myFolder:{type:'Folder'},myPage:2,myStates:['MI']};w.portalSessionEpoch=1;
  w.q=s=>w.document.querySelector(s);w.esc=s=>String(s??'').replace(/[&<>"']/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));w.divisionLabel=id=>id==='owner'?'Owner / Master':'Vivid Life';
  w.modal=html=>w.document.body.insertAdjacentHTML('beforeend','<div id="modal"><div class="modalbox">'+html+'</div></div>');w.closeModal=()=>w.q('#modal')?.remove();
  let flushOK=true,hasPending=false,review=0,fail=false,stale=false,commitWait=null,previewWait=null,reloadMessage='',notice='';
  w.PortalCallNotes={flushAll:async()=>flushOK,hasPending:()=>hasPending,openReview:()=>review++};w.flash=message=>notice=message;w.reload=async message=>reloadMessage=message;
  const calls=[],leads=[{id:'a',assigned_to:'self',status:'assigned',updated_at:'2026-10-19T10:00:00Z',first_name:'<script>alert(1)</script>',phone:'2025550101',state:'MI',division:'vivid_life',lead_type:'Folder'},{id:'b',assigned_to:'self',status:'assigned',updated_at:'2026-10-19T10:00:00Z',first_name:'Portable',division:'owner'}];
  w.api=async(url,opt)=>{
   calls.push({url,body:JSON.parse(JSON.stringify(opt.body))});
   if(url.endsWith('my_assigned_leads_filtered')){if(previewWait)await previewWait;return {data:leads,count:2};}
   if(commitWait)await commitWait;if(stale)throw Object.assign(Error('Lead changed'),{code:'40001'});if(fail)throw Error('Network error');return opt.body.p_leads.length;
  };
  w.eval(fs.readFileSync(__dirname+'/../lead-return.js','utf8'));
  assert.match(w.PortalLeadReturn.button(),/Return to agency pool/);w.S.profile.role='agent';assert.equal(w.PortalLeadReturn.button(),'');await w.PortalLeadReturn.open();assert.equal(calls.length,0);w.S.profile.is_team_leader=true;assert.match(w.PortalLeadReturn.button(),/Return to agency pool/);
  flushOK=false;await w.PortalLeadReturn.open();assert.equal(review,1);assert.equal(calls.length,0);assert.match(notice,/call notes/);flushOK=true;
  await w.PortalLeadReturn.open();assert.deepEqual(calls[0].body,{p_search:'test',p_lead_type:'Folder',p_folder:true,p_page:2,p_limit:500,p_states:['MI']});assert.equal(w.q('#leadReturnPreview script'),null);assert.match(w.q('#leadReturnPreview').textContent,/Owner \/ Master pool/);assert.equal(calls.length,1,'Preview must not mutate');
  w.q('#leadReturnAll').checked=false;w.q('#leadReturnAll').onchange();assert.equal(w.q('#leadReturnConfirm').disabled,true);
  const first=w.q('.leadReturnCheck');first.checked=true;first.onchange();assert.equal(w.q('#leadReturnAll').indeterminate,true);assert.equal(w.q('#leadReturnConfirm').disabled,false);
  fail=true;await w.q('#leadReturnConfirm').onclick();const payload=calls.at(-1).body;assert.deepEqual(payload.p_leads,[{id:'a',updated_at:'2026-10-19T10:00:00Z'}]);assert.equal(w.q('#leadReturnAll').disabled,true,'Uncertain commit must freeze selection');
  fail=false;let release;commitWait=new Promise(resolve=>release=resolve);const pending=w.q('#leadReturnConfirm').onclick();await Promise.resolve();assert.equal(w.q('#leadReturnCancel').disabled,true);w.q('#modal').onclick({target:w.q('#modal')});assert(w.q('#modal'));await w.q('#leadReturnConfirm').onclick();release();await pending;commitWait=null;
  assert.deepEqual(calls.at(-1).body,payload,'Retries use identical IDs, revisions and request ID');assert.equal(calls.filter(c=>c.url.endsWith('return_my_leads_to_pool')).length,2);assert.equal(w.q('#modal'),null);assert.match(reloadMessage,/1 lead returned/);
  await w.PortalLeadReturn.open();stale=true;await w.q('#leadReturnConfirm').onclick();assert.equal(w.q('#leadReturnConfirm').disabled,true);stale=false;w.q('#leadReturnCancel').click();
  await w.PortalLeadReturn.open();hasPending=true;const before=calls.length;await w.q('#leadReturnConfirm').onclick();assert.equal(calls.length,before);assert.match(w.q('#leadReturnMessage').textContent,/unsaved call notes/);hasPending=false;w.q('#leadReturnCancel').click();
  let releasePreview;previewWait=new Promise(resolve=>releasePreview=resolve);const old=w.PortalLeadReturn.open();await new Promise(resolve=>setImmediate(resolve));w.S.profile.id='other';w.portalSessionEpoch++;releasePreview();await old;assert.equal(w.q('#leadReturnPreview').hidden,true);
  console.log('PASS: admin/team-leader gate, inherited page filters, note-save gate, explicit selection, destination pools, escaped data, stable retries, stale/duplicate/account guards.');
 }finally{dom.window.close();}
})().catch(error=>{console.error(error);process.exitCode=1;});
