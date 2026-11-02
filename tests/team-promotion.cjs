'use strict';
const {JSDOM}=require('jsdom'),fs=require('node:fs'),assert=require('node:assert/strict');
const dom=new JSDOM('<main id="app"></main>',{runScripts:'outside-only'}),w=dom.window,calls=[];
let fail=false,delayPreview=false,resolvePreview;
const preview={leader:{id:'leader',name:'Leader <script>',division:'old'},members:[{id:'member',name:'Member <img>',active:true,archived:false},{id:'disabled',name:'Disabled Member',active:false,archived:false}],agencies:[{id:'new',name:'New Agency'},{id:'other',name:'Other Agency'}],open_leads:12,closed_deals:2};
Object.assign(w,{S:{profile:{id:'owner',role:'admin',is_super_admin:true,active:true},agents:[{id:'leader',is_team_leader:true,active:true}],tab:'organization'},ORG:{view:'hierarchy',expanded:new Set()},portalSessionEpoch:1,
 q:s=>w.document.querySelector(s),esc:s=>String(s??'').replace(/[&<>"']/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c])),flash:s=>calls.push({message:s}),loadCore:async()=>calls.push({reload:true}),
 api:async(path,options)=>{calls.push({path,body:options.body});if(path.endsWith('team_admin_promotion_preview'))return delayPreview?new Promise(r=>resolvePreview=r):structuredClone(preview);if(fail)throw Error('The team changed. Review again.');return {division:'new',agency_name:'New Agency',members_moved:2};}});
const appSource=fs.readFileSync('portal-app.js','utf8');
for(const name of ['modal','closeModal'])w.eval(appSource.split('\n').find(line=>line.startsWith('function '+name+'(')));
w.eval(fs.readFileSync('team-promotion.js','utf8'));
const submit=async()=>{w.q('#promotionReviewed').checked=true;await w.q('#promotionForm').onsubmit({preventDefault(){}});};
(async()=>{
 w.S.profile.is_super_admin=false;await w.promoteTeamModal('leader');assert.equal(calls.length,0);
 w.S.profile.is_super_admin=true;w.modal('<h2>Existing team settings</h2>');await w.promoteTeamModal('leader');assert.equal(w.document.querySelectorAll('#modal').length,1,'Promotion must replace the previous dialog, not stack duplicate modal IDs');assert(!w.q('script'));assert(!w.q('img'));assert.match(w.document.body.textContent,/Leader <script>/);assert.match(w.document.body.textContent,/Disabled Member/);
 assert(w.q('#promotionName').required);w.q('#promotionName').value='New Agency';w.q('#promotionReviewed').checked=true;w.q('#promotionAgency').value='new';w.q('#promotionAgency').dispatchEvent(new w.Event('change'));assert(!w.q('#promotionReviewed').checked);assert(w.q('#promotionName').disabled);assert.match(w.q('#promotionAccess').textContent,/all agents and records/);
 await submit();const sent=calls.find(x=>x.path?.endsWith('/promote_team_leader_with_agency'));assert.deepEqual(JSON.parse(JSON.stringify(sent.body)),{p_leader:'leader',p_expected_division:'old',p_expected_members:['member','disabled'],p_division:'new',p_agency_name:null});assert(w.ORG.expanded.has('new'));assert(calls.some(x=>x.reload));assert.equal(w.q('#promotionForm'),null);
 await w.promoteTeamModal('leader');w.q('#promotionName').value='Brand New';fail=true;await submit();assert.match(w.q('#promotionError').textContent,/team changed/);assert(!w.q('#promotionSave').disabled);assert(!w.q('#promotionReviewed').checked);assert(calls.some(x=>x.body?.p_agency_name==='Brand New'&&x.body.p_division===null));
 fail=false;preview.agencies.unshift({id:'old',name:'Current Agency'});preview.members=[];
 await w.promoteTeamModal('leader');assert.equal(w.q('#promotionAgency').value,'old','Current agency is selected');assert(w.q('#promotionNameField').hidden);assert(w.q('#promotionName').disabled);assert.match(w.q('#promotionAgency').textContent,/Current Agency \(current agency\)/);w.q('#promotionCancel').click();assert.equal(w.q('#modal'),null,'Cancel closes the visible form with the real portal modal helper');
 await w.promoteTeamModal('leader');await w.q('#promotionRefresh').onclick();assert.equal(w.document.querySelectorAll('#modal').length,1,'Refresh replaces the same dialog');await submit();assert(calls.some(x=>x.body?.p_division==='old'&&x.body.p_expected_members.length===0));assert.equal(w.q('#modal'),null);
 delayPreview=true;const pending=w.promoteTeamModal('leader');w.q('#promotionCancel').click();resolvePreview(preview);await pending;assert.equal(w.q('#promotionForm'),null,'A closed preview cannot reopen itself');
 console.log('PASS: owner-only UI, escaped names, roster review, destination access warning, exact roster submission, new/existing agency, failure recovery, refresh, visible Cancel, no stacked dialogs, current-agency/empty-team promotion and canceled preview.');dom.window.close();
})().catch(e=>{console.error(e);process.exitCode=1;});
