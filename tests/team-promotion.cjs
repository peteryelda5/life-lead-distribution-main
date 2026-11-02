'use strict';
const {JSDOM}=require('jsdom'),fs=require('node:fs'),assert=require('node:assert/strict');
const dom=new JSDOM('<div id="modal"></div>',{runScripts:'outside-only'}),w=dom.window,calls=[];
let fail=false,delayPreview=false,resolvePreview;
const preview={leader:{id:'leader',name:'Leader <script>',division:'old'},members:[{id:'member',name:'Member <img>',active:true,archived:false},{id:'disabled',name:'Disabled Member',active:false,archived:false}],agencies:[{id:'new',name:'New Agency'},{id:'other',name:'Other Agency'}],open_leads:12,closed_deals:2};
Object.assign(w,{S:{profile:{id:'owner',role:'admin',is_super_admin:true,active:true},agents:[{id:'leader',is_team_leader:true,active:true}],tab:'organization'},ORG:{view:'hierarchy',expanded:new Set()},portalSessionEpoch:1,
 q:s=>w.document.querySelector(s),esc:s=>String(s??'').replace(/[&<>"']/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c])),modal:s=>w.document.querySelector('#modal').innerHTML=s,closeModal:()=>w.document.querySelector('#modal').innerHTML='',flash:s=>calls.push({message:s}),loadCore:async()=>calls.push({reload:true}),
 api:async(path,options)=>{calls.push({path,body:options.body});if(path.endsWith('team_admin_promotion_preview'))return delayPreview?new Promise(r=>resolvePreview=r):structuredClone(preview);if(fail)throw Error('The team changed. Review again.');return {division:'new',agency_name:'New Agency',members_moved:2};}});
w.eval(fs.readFileSync('team-promotion.js','utf8'));
const submit=async()=>{w.q('#promotionReviewed').checked=true;await w.q('#promotionForm').onsubmit({preventDefault(){}});};
(async()=>{
 w.S.profile.is_super_admin=false;await w.promoteTeamModal('leader');assert.equal(calls.length,0);
 w.S.profile.is_super_admin=true;await w.promoteTeamModal('leader');assert(!w.q('script'));assert(!w.q('img'));assert.match(w.document.body.textContent,/Leader <script>/);assert.match(w.document.body.textContent,/Disabled Member/);
 assert(w.q('#promotionName').required);w.q('#promotionName').value='New Agency';w.q('#promotionReviewed').checked=true;w.q('#promotionAgency').value='new';w.q('#promotionAgency').dispatchEvent(new w.Event('change'));assert(!w.q('#promotionReviewed').checked);assert(w.q('#promotionName').disabled);assert.match(w.q('#promotionAccess').textContent,/all agents and records/);
 await submit();const sent=calls.find(x=>x.path?.endsWith('/promote_team_leader_with_agency'));assert.deepEqual(JSON.parse(JSON.stringify(sent.body)),{p_leader:'leader',p_expected_division:'old',p_expected_members:['member','disabled'],p_division:'new',p_agency_name:null});assert(w.ORG.expanded.has('new'));assert(calls.some(x=>x.reload));assert.equal(w.q('#promotionForm'),null);
 await w.promoteTeamModal('leader');w.q('#promotionName').value='Brand New';fail=true;await submit();assert.match(w.q('#promotionError').textContent,/team changed/);assert(!w.q('#promotionSave').disabled);assert(!w.q('#promotionReviewed').checked);assert(calls.some(x=>x.body?.p_agency_name==='Brand New'&&x.body.p_division===null));
 delayPreview=true;const pending=w.promoteTeamModal('leader');w.closeModal();resolvePreview(preview);await pending;assert.equal(w.q('#promotionForm'),null,'A closed preview cannot reopen itself');
 console.log('PASS: owner-only UI, escaped names, roster review, destination access warning, exact roster submission, new/existing agency, failure recovery, refresh and canceled preview.');dom.window.close();
})().catch(e=>{console.error(e);process.exitCode=1;});
