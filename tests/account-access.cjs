'use strict';
const {JSDOM}=require('jsdom'),fs=require('node:fs'),assert=require('node:assert/strict');
const dom=new JSDOM('<main id="app"></main>',{runScripts:'outside-only'}),w=dom.window,calls=[];
let fail=false,delay=false,resolvePreview;
const preview={id:'agent',name:'Agent <img>',role:'agent',division:'vivid',active:true,open_leads:12,closed_deals:3,can_reclaim:true};
Object.assign(w,{S:{profile:{id:'owner',role:'admin'}},portalSessionEpoch:1,q:s=>w.document.querySelector(s),
 esc:s=>String(s??'').replace(/[&<>"']/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c])),
 flash:(message,error)=>calls.push({message,error}),reload:async message=>calls.push({message,reload:true}),confirm:()=>true,
 api:async(path,options)=>{calls.push({path,body:options.body});if(path.endsWith('account_disable_preview'))return delay?new Promise(r=>resolvePreview=r):structuredClone(preview);if(fail)throw Error('This account changed. Review again.');return {reclaimed_leads:12}}});
const app=fs.readFileSync('portal-app.js','utf8');
for(const name of ['modal','closeModal','toggleAgent','toggleScopedAdmin'])w.eval(app.split('\n').find(line=>line.startsWith('function '+name+'(')||line.startsWith('async function '+name+'(')));
w.eval(fs.readFileSync('account-access.js','utf8')+';window.accountDisableModal=accountDisableModal;');
const submit=()=>w.q('#accountDisableForm').onsubmit({preventDefault(){}});
(async()=>{
 w.S.profile.role='agent';await w.accountDisableModal('agent');assert.equal(calls.length,0);w.S.profile.role='admin';
 await w.accountDisableModal('owner');assert.equal(calls.length,0);
 w.modal('<h2>Previous dialog</h2>');await w.toggleAgent('agent',true);assert.equal(w.document.querySelectorAll('#modal').length,1);assert(!w.q('img'));assert.match(w.document.body.textContent,/Agent <img>/);
 assert.equal(w.q('input:checked').value,'keep');assert.match(w.q('#accountDisableSave').textContent,/keep everything/);
 w.q('#accountDisableCancel').click();assert(!w.q('#modal'));assert(!calls.some(x=>x.path?.endsWith('/disable_portal_account')));
 await w.toggleAgent('agent',true);await submit();let sent=calls.filter(x=>x.path?.endsWith('/disable_portal_account')).at(-1);assert.equal(sent.body.p_reclaim_open_leads,false);assert.equal(sent.body.p_expected_role,'agent');assert.equal(sent.body.p_expected_division,'vivid');assert(!w.q('#modal'));
 await w.accountDisableModal('agent');w.q('input[value="reclaim"]').click();assert.match(w.q('#accountDisableSave').textContent,/take back/);await submit();assert(calls.some(x=>x.body?.p_reclaim_open_leads===true));assert(calls.some(x=>x.reload&&/12 open leads/.test(x.message)));
 fail=true;await w.accountDisableModal('agent');await submit();assert.match(w.q('#accountDisableError').textContent,/account changed/);assert(!w.q('#accountDisableSave').disabled);w.q('#accountDisableCancel').click();assert(!w.q('#modal'));fail=false;
 preview.role='admin';preview.can_reclaim=false;await w.toggleScopedAdmin('admin',true);assert.match(w.document.body.textContent,/Only this admin’s personal leads/);assert(w.q('input[value="reclaim"]').disabled);assert.equal(w.q('input:checked').value,'keep');await submit();assert.equal(calls.filter(x=>x.path?.endsWith('/disable_portal_account')).at(-1).body.p_expected_role,'admin');
 await w.toggleAgent('agent',false);assert(calls.some(x=>x.path?.endsWith('/enable_agent')));await w.toggleScopedAdmin('admin',false);assert(calls.some(x=>x.path?.endsWith('/set_scoped_admin_access')&&x.body.p_active===true));
 delay=true;const pending=w.accountDisableModal('agent');w.q('#accountDisableCancel').click();resolvePreview(preview);await pending;assert(!w.q('#modal'));
 delay=false;preview.active=false;await w.accountDisableModal('agent');assert(!w.q('#modal'));assert(calls.some(x=>/already disabled/.test(x.message)));
 console.log('PASS: real agent/admin entry points, keep default, both modes, escaped names, Cancel, no stacked dialogs, stale preview recovery, scope-limited choice, enable, and canceled/disabled preview.');dom.window.close();
})().catch(e=>{console.error(e);process.exitCode=1});
