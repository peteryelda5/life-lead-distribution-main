'use strict';
const fs=require('node:fs'),assert=require('node:assert/strict'),{JSDOM}=require('jsdom');
(async()=>{
 const dom=new JSDOM('<body><button id="open">Open</button></body>',{url:'https://www.lldportal.com',runScripts:'outside-only'}),w=dom.window;
 try{
  w.S={profile:{id:'master',role:'admin',is_super_admin:true},divisionDirectory:[{id:'vivid_life',name:'Vivid <Life>',admins:[]}],selected:new Set(['old'])};w.portalSessionEpoch=1;
  w.q=s=>w.document.querySelector(s);w.qa=s=>Array.from(w.document.querySelectorAll(s));w.esc=s=>String(s??'').replace(/[&<>"']/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
  w.closeModal=()=>w.q('#modal')?.remove();w.modal=html=>w.document.body.insertAdjacentHTML('beforeend','<div id="modal"><div class="modalbox">'+html+'</div></div>');
  const calls=[];let previewWait,commitWait,failCommit=false,stale=false,reloaded='';
  w.flash=()=>{};w.reload=async text=>{reloaded=text;};
  w.api=async(url,opt)=>{calls.push({url,body:JSON.parse(JSON.stringify(opt.body))});
   if(url.endsWith('_agencies'))return [{id:'vivid_life',name:'Vivid Life',archived:false},{id:'legacy_life',name:'Legacy Life',archived:true}];
   if(url.endsWith('_options'))return [{type:'<Folder>',count:2}];
   if(url.endsWith('_preview')){if(previewWait)await previewWait;return {available:2,leads:[{id:'one',updated_at:'2026-10-14T12:00:00Z',first_name:'<img src=x onerror=alert(1)>',phone:'2025550101',lead_type:'<Folder>',assignee:'Agency lead pool'},{id:'two',updated_at:'2026-10-14T12:00:00Z',first_name:'Assigned',assigned_to:'agent',assignee:'Agent Name'}]};}
   if(commitWait)await commitWait;if(stale)throw Object.assign(Error('Some leads changed'),{code:'40001'});if(failCommit)throw Error('Network error');return 2;
  };
  w.eval(fs.readFileSync(__dirname+'/../agency-recall.js','utf8'));w.eval(fs.readFileSync(__dirname+'/../divisions.js','utf8'));
  assert.match(w.divisionsPage(),/data-division-reclaim="vivid_life"/);
  assert.match(w.divisionsPage(),/id="takeAgencyLeads"/);
  w.S.profile.is_super_admin=false;await w.openAgencyRecall('vivid_life');assert.equal(calls.length,0);assert.doesNotMatch(w.divisionsPage(),/data-division-reclaim/);w.S.profile.is_super_admin=true;
  await w.openAgencyRecall('vivid_life');assert.equal(w.q('#recallConfirm').hidden,true);assert.equal(calls.length,1);
  w.q('#recallType').value='0';w.q('#recallScope').value='assigned';w.q('#recallCount').value='3';
  await w.q('#agencyRecallForm').onsubmit({preventDefault(){}});
  assert.deepEqual(calls.at(-1).body,{p_source:'vivid_life',p_type:'<Folder>',p_scope:'assigned',p_count:3});assert.match(w.q('#recallMessage').textContent,/fewer than requested/);assert.equal(w.q('#recallPreview img'),null);assert.match(w.q('#recallPreview').textContent,/Agent Name/);assert.equal(calls.filter(c=>c.url.endsWith('_commit')).length,0);
  w.q('#recallCount').value='1';w.q('#recallCount').oninput();assert.equal(w.q('#recallConfirm').hidden,true);
  w.q('#recallCount').value='1001';await w.q('#agencyRecallForm').onsubmit({preventDefault(){}});assert.match(w.q('#recallMessage').textContent,/1,000/);
  w.q('#recallCount').value='2';await w.q('#agencyRecallForm').onsubmit({preventDefault(){}});
  failCommit=true;await w.q('#recallConfirm').onclick();const first=calls.at(-1).body;assert.equal(w.q('#recallConfirm').hidden,false);
  failCommit=false;let release;commitWait=new Promise(resolve=>release=resolve);const pending=w.q('#recallConfirm').onclick();await Promise.resolve();assert.equal(w.q('#recallCancel').disabled,true);w.q('#modal').onclick({target:w.q('#modal')});assert(w.q('#modal'));await w.q('#recallConfirm').onclick();release();await pending;commitWait=null;
  assert.deepEqual(calls.at(-1).body,first,'Retry must preserve request ID and exact lead versions');assert.equal(calls.filter(c=>c.url.endsWith('_commit')).length,2,'Busy click must not duplicate');assert.match(reloaded,/2 leads taken back/);assert.equal(w.S.selected.size,0);assert.equal(w.q('#modal'),null);
  await w.openAgencyRecall('vivid_life');await w.q('#agencyRecallForm').onsubmit({preventDefault(){}});stale=true;await w.q('#recallConfirm').onclick();assert.equal(w.q('#recallConfirm').hidden,true);assert.match(w.q('#recallMessage').textContent,/Some leads changed/);stale=false;
  await w.chooseAgencyRecall();assert.match(w.q('#recallAgency').textContent,/Legacy Life \(archived\)/);w.q('#recallAgency').value='1';w.q('#recallAgencyForm').onsubmit({preventDefault(){}});await new Promise(resolve=>setImmediate(resolve));assert.match(w.q('#agencyRecallTitle').parentElement.textContent,/Legacy Life/);assert.equal(calls.at(-1).body.p_source,'legacy_life');
  let releasePreview;previewWait=new Promise(resolve=>releasePreview=resolve);const pendingPreview=w.q('#agencyRecallForm').onsubmit({preventDefault(){}});w.S.profile.id='another-user';w.portalSessionEpoch++;releasePreview();await pendingPreview;assert.equal(w.q('#recallConfirm').hidden,true,'Old account preview must not appear');
  console.log('PASS: Master button, folder/scope/quantity preview, escaped content, explicit commit, invalidation, exact retry, busy guards, stale/account changes.');
 }finally{dom.window.close();}
})().catch(e=>{console.error(e);process.exitCode=1;});
