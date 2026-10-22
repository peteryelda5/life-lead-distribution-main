'use strict';
const fs=require('node:fs'),vm=require('node:vm'),assert=require('node:assert/strict');
const html=require('./portal-document.cjs')();
const line=name=>html.split('\n').find(x=>x.startsWith('async function '+name+'('));
const core=html.slice(html.indexOf('async function loadCore()'),html.indexOf('async function loadPoolPage()'));
const ticks=()=>new Promise(resolve=>setImmediate(resolve));
function setup(role='admin',tab='dashboard'){
 const calls=[],pending=[];
 const S={profile:{id:'user',role,division:'vivid_life',is_super_admin:true},session:{},tab,adminDivisions:[],divisionFilter:'owner',agents:[],admins:[]};
 const response=path=>path.includes('my_admin_divisions')?['owner','vivid_life']:path.includes('admin_agent_stats')?[{agent_id:'a',open_leads:3,annual_premium:1234}]:[];
 const context={S,portalSessionEpoch:0,currentAal:()=> 'aal2',loadOnboarding:async()=>{calls.push('onboarding');return true},
  api:async path=>{calls.push(path);return response(path)},
  loadDivisionRegistry:async()=>{calls.push('registry')},loadPortalAnnouncements:async()=>{calls.push('announcements')},
  loadTabData:async()=>{calls.push('tab:'+S.tab)},console};
 context.portalVerified=()=>context.currentAal()==='aal2';vm.createContext(context);vm.runInContext(core,context);return{context,calls,S,pending};
}
(async()=>{
 const {context:c,calls,S}=setup();await c.loadCore();
 assert(calls.includes('tab:dashboard'));assert(!calls.some(x=>/admin_dashboard_stats|admin_agent_stats|filter_counts|my_closed_stats/.test(x)));
 assert.deepEqual(Array.from(S.adminDivisions),['owner','vivid_life']);assert.equal(S.divisionFilter,'owner');
 // All independent startup requests begin without waiting for one another.
 const gate=setup();let resolve;gate.context.api=async path=>{gate.calls.push(path);return new Promise(r=>{gate.pending.push(()=>r(path.includes('my_admin_divisions')?['vivid_life']:[]));resolve=r})};
 const loading=gate.context.loadCore();await ticks();assert.equal(gate.pending.length,5);assert(gate.calls.includes('registry')&&gate.calls.includes('announcements'));assert(!gate.calls.includes('tab:dashboard'));gate.pending.forEach(f=>f());await loading;assert(gate.calls.includes('tab:dashboard'));
 // Results from a previous account cannot overwrite the new account's scoped lists.
 const stale=setup();stale.context.api=()=>new Promise(r=>stale.pending.push(()=>r(['old'])));const task=stale.context.loadCore();await ticks();stale.context.portalSessionEpoch++;stale.S.profile={id:'new',role:'admin'};stale.pending.forEach(f=>f());await task;assert.equal(stale.S.adminDivisions.length,0);assert(!stale.calls.some(x=>x.startsWith('tab:')));
 const agent=setup('agent','my-leads');await agent.context.loadCore();assert(!agent.calls.some(x=>/my_closed_stats|admin_/.test(x)));assert(agent.calls.some(x=>x.includes('my_team_info')));
 const blocked=setup();blocked.context.currentAal=()=> 'aal1';await assert.rejects(blocked.context.loadCore(),/Two-step/);assert.equal(blocked.calls.length,0);
 // Navigating into the relevant screen always loads fresh stats and pool counts.
 let route=[];Object.assign(c,{loadDashboard:async()=>route.push('dashboard'),loadPoolPage:async()=>route.push('pool'),refreshLeadFilterCounts:async()=>route.push('filters'),loadLeadRequests:async()=>route.push('requests'),loadMyFolders:async()=>route.push('folders'),loadMyLeadsPage:async()=>route.push('my-leads')});
 vm.runInContext(line('loadTabData'),c);S.tab='leads';await c.loadTabData();assert.deepEqual(route.sort(),['filters','pool']);
 route=[];S.tab='lead-requests';await c.loadTabData();assert.deepEqual(route,['requests']);
 S.tab='agents';await c.loadTabData();assert.equal(S.agentStats.a.open_leads,3);
 route=[];S.tab='my-leads';await c.loadTabData();assert.deepEqual(route.sort(),['folders','my-leads']);
 const team=fs.readFileSync('team-leaders.js','utf8');let pageLoads=0,renders=0,badges=0,cleared=0;
 Object.assign(c,{loadLeadRequests:async()=>pageLoads++,render:()=>renders++,refreshRequestBadge:async()=>badges++,scheduleFeedbackClear:()=>cleared++});
 vm.runInContext(team.split('\n').find(x=>x.startsWith('async function reloadLeadRequests')),c);
 await c.reloadLeadRequests('Sent');assert.equal(pageLoads,1);assert.equal(renders,1);assert.equal(badges,1);assert.equal(cleared,1);assert.equal(S.msg,'Sent');
 let intervals=0,refreshes=0;Object.assign(c,{requestBadgeTimer:null,paintRequestBadge(){},refreshRequestBadge:()=>refreshes++,setInterval:()=>++intervals});
 vm.runInContext(team.split('\n').find(x=>x.startsWith('function startRequestBadge')),c);c.startRequestBadge();c.startRequestBadge();c.startRequestBadge();assert.equal(intervals,1);assert.equal(refreshes,1);
 console.log('PASS: parallel startup, page-specific counts, lightweight request refresh, no duplicate badge polling, MFA guard and stale-account isolation.');
})().catch(e=>{console.error(e);process.exitCode=1});
