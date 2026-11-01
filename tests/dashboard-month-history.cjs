'use strict';
const fs=require('node:fs'),path=require('node:path'),assert=require('node:assert/strict'),vm=require('node:vm');
const {JSDOM,ResourceLoader,VirtualConsole}=require('jsdom');
const root=path.resolve(__dirname,'..'),errors=[];
class Assets extends ResourceLoader{
 fetch(url){const u=new URL(url);if(u.hostname==='cdn.jsdelivr.net')return Promise.resolve(Buffer.from('window.supabase={createClient:()=>({auth:{},realtime:{setAuth:async()=>{}},removeChannel(){}})};'));assert.equal(u.hostname,'portal.test');return Promise.resolve(u.pathname.endsWith('.js')?fs.readFileSync(path.join(root,u.pathname)):Buffer.from(''));}
}
(async()=>{
 const vc=new VirtualConsole();vc.on('jsdomError',e=>errors.push(e.message));
 const dom=new JSDOM(fs.readFileSync(path.join(root,'index.html'),'utf8'),{url:'https://portal.test/',runScripts:'dangerously',resources:new Assets(),pretendToBeVisual:true,virtualConsole:vc});
 const w=dom.window,run=s=>vm.runInContext(s,dom.getInternalVMContext()),doc=w.document;
 try{
  await new Promise(r=>w.addEventListener('load',r,{once:true}));
  assert.equal(errors.length,0,errors.join('\n'));
  // Sign-in markup retains native validation and the existing auth handler.
  assert.equal(doc.querySelector('#portalLoginEmail').autocomplete,'username');
  assert.equal(doc.querySelector('#portalLoginPassword').autocomplete,'current-password');
  assert(!doc.querySelector('#login').checkValidity());
  assert.equal(doc.querySelector('.portal-login-forgot').getAttribute('href'),'/password-reset.html');
  doc.querySelector('.portal-login-reveal').click();assert.equal(doc.querySelector('#portalLoginPassword').type,'text');
  doc.querySelector('.portal-login-reveal').click();assert.equal(doc.querySelector('#portalLoginPassword').type,'password');
  // jsdom does not implement media; presentation cleanup is exercised separately in the browser.
  w.HTMLMediaElement.prototype.pause=function(){};w.HTMLMediaElement.prototype.load=function(){};
  run(`
   let calls=[],held={},hold=false;
   const current=dashboardCurrentMonth(),priorMonth=n=>{const d=new Date(current+'T12:00:00Z');d.setUTCMonth(d.getUTCMonth()-n);return d.toISOString().slice(0,7)+'-01';},previous=priorMonth(1),older=priorMonth(2);
   S.profile={id:'agent-a',full_name:'Test Agent',role:'agent',active:true,division:'vivid_life'};S.tab='dashboard';
   loadOnboardingChecklist=loadCarrierLogos=async()=>{};agentOnboardingCard=()=>'';carrierBrandLogo=()=>'';
   api=async function(url,opts={}){
    const body=opts.body||{};calls.push({url,body});
    const month=body.p_month||body.p_data?.month||current,ap=month===previous?12000:month===older?9000:1500;
    if(hold&&url.endsWith('/leaderboard_period'))await new Promise(r=>held[month]=r);
    if(url.endsWith('/portal_collaboration'))return {target:20000,production:ap,scope:S.profile.role==='admin'?'agency':'personal',division:S.profile.division};
    if(url.endsWith('/leaderboard_period'))return {period:{ap,mp:ap/12,deals:4},rankings:[{agent_id:'agent-a',agent_name:'Test Agent',ap,deals:4,mp:ap/12}],available_months:[previous,older]};
    if(url.endsWith('/agent_dashboard'))return {assigned:12,followups:3,recent:[],priorities:[]};
    if(url.endsWith('/dashboard_overview'))return {days:30,inventory:{total_leads:12,assigned:12},leaderboard:[],active_agents:1};
    return [];
   };
   render=function(){app.innerHTML=S.profile.role==='agent'?agentDashboardPage():dash();if(S.profile.role==='agent')bindAgentDashboard();else bindDashboard();};
  `);
  await run('loadAgentDashboard()');run('render()');
  const change=async month=>{const el=doc.querySelector('#pcGoalMonth');el.value=month.slice(0,7);await el.onchange({target:el});};
  assert(doc.querySelector('#pcGoalMonth'));assert(!doc.querySelector('#pcSetGoal'));
  await change(run('previous'));
  assert.equal(run('PC.goalMonth'),run('previous'));
  assert(doc.querySelectorAll('.ad-metric')[2].textContent.includes('12,000'));
  assert(doc.querySelector('.ad-goal').textContent.includes('12,000'));
  assert.equal(doc.querySelector('.ad-rank-number').textContent,'#1');
  assert.equal(run("calls.filter(c=>c.url.endsWith('/leaderboard_period')).at(-1).body.p_period"),'previous');
  assert.equal(run("calls.filter(c=>c.url.endsWith('/leaderboard_period')).at(-1).body.p_division"),'all');
  await run('loadAgentDashboard()');assert.equal(run('PC.goalMonth'),run('previous'),'Reload must retain the chosen month.');run('render()');
  run("navigatePortalTab=async tab=>{S.tab=tab;};");
  await doc.querySelector('.ad-rank [data-ad-go=leaderboard]').onclick();
  assert.equal(run('LB.period'),'previous');assert.equal(run('LB.month'),run('previous'));
  run("S.tab='dashboard';render()");await doc.querySelector('[data-ad-period=today]').onclick();
  assert.equal(run('PC.goalMonth'),run('current'));assert.equal(run('AD.period'),'today');
  // Invalid/future months do not issue requests or change selection.
  const count=run('calls.length');await change('2999-01-01');assert.equal(run('calls.length'),count);assert.equal(run('PC.goalMonth'),run('current'));
  // A slower request for an earlier selection cannot overwrite the new one.
  run('hold=true');const a=change(run('previous'));const b=change(run('older'));
  run('held[older]()');await b;run('held[previous]()');await a;
  assert.equal(run('PC.goalMonth'),run('older'));assert(doc.querySelectorAll('.ad-metric')[2].textContent.includes('9,000'));run('hold=false');
  // Regular administrators use the same month API within their existing agency scope.
  run("S.profile={id:'admin-a',full_name:'Admin',role:'admin',active:true,division:'legacy_life'};S.adminDivisions=['legacy_life'];resetDashboard();");
  await run('loadDashboard()');run('render()');await change(run('previous'));
  assert(doc.querySelector('#pcGoalMonth'));assert(doc.querySelector('#pcSetGoal'));
  assert.equal(run("calls.filter(c=>c.url.endsWith('/leaderboard_period')).at(-1).body.p_division"),'legacy_life');
  assert(doc.querySelector('.dash-metrics').textContent.includes('12,000'));assert(doc.querySelector('.dash-lower').textContent.includes('Test Agent'));
  assert(!doc.querySelector('#dashboardDays'),'Monthly figures must not be labeled with a rolling-day filter.');
  // Historical imported production can lack premium/deal counts: show unavailable, not zero.
  run('dashboardMonthly.period.mp=null;dashboardMonthly.period.deals=null;dashboardMonthly.rankings[0].deals=null;render()');
  assert(doc.querySelector('.dash-metrics').textContent.includes('—'));assert(doc.querySelector('.dash-lower tbody').textContent.includes('—'));
  // Account changes reset the selected period and discard the other account’s goal.
  run("S.profile={id:'agent-b',full_name:'Other Agent',role:'agent',active:true,division:'legacy_life'};");await run('loadAgentDashboard()');
  assert.equal(run('PC.goalMonth'),run('current'));assert.equal(run('PC.goalAgent'),'agent-b');
  // Detroit month rollover is based on local midnight, not UTC midnight.
  const helper=fs.readFileSync(path.join(root,'agent-dashboard.js'),'utf8').split('\n').find(s=>s.startsWith('function dashboardCurrentMonth'));
  for(const [instant,expected] of [['2026-11-01T03:59:59Z','2026-10-01'],['2026-11-01T04:00:00Z','2026-11-01']]){
   const c=vm.createContext({Intl,Date:class extends Date{constructor(){super(instant);}}});vm.runInContext(helper,c);assert.equal(vm.runInContext('dashboardCurrentMonth()',c),expected);
  }
  assert.equal(errors.length,0,errors.join('\n'));
  console.log('PASS: agent/admin month selection, scoped production, goals/rankings, reload and leaderboard continuity, stale requests, account isolation, imported counts, Detroit rollover and login validation.');
 }finally{dom.window.close();}
})().catch(e=>{console.error(e);process.exitCode=1;});
