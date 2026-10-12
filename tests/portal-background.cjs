'use strict';
const fs=require('node:fs'),vm=require('node:vm'),assert=require('node:assert/strict');
const source=fs.readFileSync('portal-collaboration.js','utf8');
const defer=()=>{let resolve,reject;const promise=new Promise((a,b)=>{resolve=a;reject=b});return {promise,resolve,reject};};
function setup(){
 const calls=[],pending=[],events={},intervals=[];let clock=100000;
 const c={S:{profile:{id:'a',active:true,is_super_admin:true},tab:'agents'},SOCIAL:{unread:[]},CHAT:{rows:[]},dashboardBusy:false,
  currentAal:()=> 'aal2',Date:class extends Date{static now(){return clock;}},console,
  api:async(p,{body})=>{calls.push(body.p_action);const wait=defer();pending.push(wait);return wait.promise;},
  document:{hidden:false,querySelector:()=>null,addEventListener:(n,fn)=>events[n]=fn,activeElement:null,createElement:()=>({content:{querySelector:()=>null}})},
  q:()=>null,qa:()=>[],setInterval:(fn,ms)=>intervals.push({fn,ms}),setTimeout(){},window:{},
 };
 for(const name of ['loadChat','chatPage','bindChat','refreshChat','chatMessagesHtml','chatKey','changeChatRoom','chatMediaPrepare','loadDashboard','loadAgentDashboard','dash','agentDashboardPage','bindDashboard','bindAgentDashboard','resetChat','paintChatBadges'])c[name]=async()=>{};
 vm.createContext(c);vm.runInContext(source,c);vm.runInContext('pcAlert=pcChannelAlerts=paintChatBadges=pcPaintSidebar=()=>{};',c);
 return{c,calls,pending,events,intervals,run:s=>vm.runInContext(s,c),advance:n=>clock+=n};
}
(async()=>{
 const t=setup();t.c.document.hidden=true;t.c.pcPoll();assert.equal(t.calls.length,0);
 t.c.document.hidden=false;t.c.currentAal=()=> 'aal1';t.c.pcPoll();assert.equal(t.calls.length,0);t.c.currentAal=()=> 'aal2';
 t.c.pcPoll();t.c.pcPoll();assert.deepEqual(t.calls,['list'],'Overlapping background polls share one request.');t.pending[0].resolve({chats:[],channels:[]});await t.run('PC.listFlight');
 t.c.pcPoll();assert.equal(t.calls.length,1);t.advance(30000);t.c.pcPoll();assert.equal(t.calls.length,2);t.pending[1].resolve({chats:[],channels:[]});await t.run('PC.listFlight');
 // An explicit refresh after a mutation must supersede an older read.
 const old=t.c.pcList(false),fresh=t.c.pcList();assert.equal(t.calls.length,4);t.pending[3].resolve({chats:[{id:'new'}]});await fresh;t.pending[2].resolve({chats:[{id:'stale'}]});await old;assert.equal(t.run('PC.chats[0].id'),'new');
 const stale=t.c.pcList();t.c.pcReset();t.pending[4].resolve({chats:[{id:'old-session'}]});await stale;assert.equal(t.run('PC.chats.length'),0,'Same-account resets also reject stale results.');
 t.c.S.profile={id:'b',active:true};t.events.visibilitychange();assert.equal(t.calls.length,6);t.pending[5].resolve({chats:[]});await t.run('PC.listFlight');assert.equal(t.run('PC.owner'),'b');
 // Chat metadata loads alongside channel history, rather than after it.
 const chat=setup(),gate=defer();chat.c.history=gate.promise;chat.run('pcBase.loadChat=()=>history;');const load=chat.c.loadChat();assert.deepEqual(chat.calls,['list']);chat.pending[0].resolve({chats:[]});gate.resolve();await load;
 // Dashboard polls start independent reads together, and never overlap.
 const d=setup(),goal=defer(),overview=defer(),goalNode={outerHTML:''};d.c.S.tab='dashboard';d.c.q=s=>s==='.pc-goal'?goalNode:null;d.c.gateGoal=goal.promise;d.c.gateOverview=overview.promise;d.c.started=[];
 d.run("pcReset();pcLoadGoal=()=>{started.push('goal');return gateGoal};pcBase.loadDashboard=()=>{started.push('overview');return gateOverview};pcGoalHtml=()=>'<section>goal</section>';pcBindGoal=()=>{};pcBase.dash=()=>'';");
 const poll=d.c.pcRefreshDashboardGoal();await d.c.pcRefreshDashboardGoal();assert.deepEqual(d.c.started,['goal','overview']);goal.resolve();overview.resolve();await poll;assert.equal(goalNode.outerHTML,'<section>goal</section>');
 d.c.dashboardBusy=true;await d.c.pcRefreshDashboardGoal();assert.equal(d.c.started.length,2);d.c.dashboardBusy=false;d.c.document.hidden=true;await d.c.pcRefreshDashboardGoal();assert.equal(d.c.started.length,2);
 console.log('PASS: hidden/MFA polling guards, request sharing, fresh mutation reads, reset/account isolation, wake refresh, parallel chat/dashboard reads and no overlapping dashboard polls.');
})().catch(e=>{console.error(e);process.exitCode=1;});
