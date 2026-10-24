'use strict';
const assert=require('node:assert/strict'),fs=require('node:fs'),vm=require('node:vm');
const {JSDOM}=require('jsdom');
const source=fs.readFileSync('portal-app.js','utf8'),onboarding=fs.readFileSync('onboarding.js','utf8');
const slice=(a,b)=>source.slice(source.indexOf(a),source.indexOf(b,source.indexOf(a)));
async function ui(){
 const dom=new JSDOM('<div id="app"></div>',{url:'https://portal.example/#my-leads'}),w=dom.window;
 let record={},resources={},signed=false,unavailable=false,portalLoads=0,signingRequests=0;const writes=[];
 const status=()=>{const licensed=record.is_licensed===true;const steps=[!!record.welcome_read_at,!!record.compliance_acknowledged_at&&signed,licensed||!!resources.xcel,licensed||!!resources.study,licensed||!!resources.exam,record.is_licensed===false||(licensed&&!!record.npn&&!!record.licensed_states?.length)];return {steps,complete:steps.every(Boolean),allowed:steps.every(Boolean),required:true,agreementComplete:signed};};
 const c={console,document:w.document,window:w,FormData:w.FormData,app:w.document.getElementById('app'),S:{profile:{id:'fixture',full_name:'Fictional Agent',role:'agent',active:true},session:{access_token:'fake'},tab:'my-leads'},q:s=>w.document.querySelector(s),qa:s=>[...w.document.querySelectorAll(s)],esc:v=>String(v??'').replace(/&/g,'&amp;').replace(/</g,'&lt;').replace(/"/g,'&quot;'),resetChatSocial(){},stopChat(){},stopLeaderboard(){},stopRequestBadge(){},logout(){},alertHtml:()=>'',sessionExpiresWithin:()=>false,setInterval:()=>1,queueMicrotask,location:w.location,flash(){},loadCore:async()=>{portalLoads++;},api:async(path,opts={})=>{
  if(unavailable)throw Error('Temporary outage');
  if(path.includes('portal_onboarding_status'))return status();
  if(path.includes('save_portal_licensing')){writes.push(opts.body);record={...record,is_licensed:opts.body.p_licensed,npn:opts.body.p_npn,licensed_states:opts.body.p_states};return;}
  if(path.includes('save_portal_onboarding_checklist')){record={...record,welcome_read_at:opts.body.p_welcome?'now':null,compliance_acknowledged_at:opts.body.p_compliance?'now':null};return;}
  if(path.includes('portal_onboarding_checklists'))return Object.keys(record).length?[record]:[];
  if(path.includes('portal_onboarding_receipts'))return [];
  throw Error('Unexpected portal data request '+path);
 },fetch:async(url,opts)=>{const b=JSON.parse(opts.body);if(b.action==='sign')signingRequests++;if(b.action==='resource')resources[b.key]=b.complete;return {ok:true,json:async()=>({environment:'live',signingReady:true,provider:'SignWell',agreement:signed?{status:'completed'}:{status:'signed',waiting_on:'agency',envelope_id:'test'},resources})};}};
 c.render=()=>{if(c.test?.state().complete)c.app.textContent='Portal';else c.onboardingView();};vm.createContext(c);vm.runInContext(slice('const ONBOARDING_VERSION=', 'function renderContent()')+onboarding+';globalThis.test={setStep:s=>onboardStep=s,state:()=>ONBOARDING};',c);
 assert.equal(await c.loadOnboarding(),false);c.render();assert.equal(c.S.tab,'onboarding');assert(!w.document.querySelector('.portal-topnav'));assert(w.document.querySelector('#onboardWelcome'));assert.equal(signingRequests,0);
 w.document.querySelector('#onboardWelcome').checked=true;await w.document.querySelector('#onboardSaveLetter').onclick();
 assert(w.document.querySelector('#onboardingChecklistForm'),'welcome directs agents to licensing question');
 const choice=value=>{const el=w.document.querySelector('[name="isLicensed"][value="'+value+'"]');el.checked=true;el.onchange();};
 choice('yes');assert(!w.document.querySelector('#onboardLicensedFields').hidden);assert(w.document.querySelector('[name="npn"]').required);
 w.document.querySelector('[name="npn"]').value='12345';let form=w.document.querySelector('form');await form.onsubmit({preventDefault(){}});assert.equal(writes.length,0);assert.match(w.document.querySelector('#onboardingSaveStatus').textContent,/at least one/);
 w.document.querySelector('[name="licensedState"][value="MI"]').checked=true;await form.onsubmit({preventDefault(){}});assert.equal(writes[0].p_licensed,true);assert.deepEqual(Array.from(writes[0].p_states),['MI']);
 assert.match(w.document.body.textContent,/Waiting on Peter Yelda/);assert.equal(c.test.state().complete,false);
 c.test.setStep(3);c.render();assert.match(w.document.body.textContent,/Not required for agents who are already licensed/);
 c.test.setStep(6);c.render();choice('no');assert(w.document.querySelector('#onboardLicensedFields').hidden);assert(w.document.querySelector('[name="npn"]').disabled);form=w.document.querySelector('form');await form.onsubmit({preventDefault(){}});assert.equal(writes[1].p_licensed,false);assert.equal(writes[1].p_npn,null);
 for(const [step,key] of [[3,'xcel'],[4,'study'],[5,'exam']]){c.test.setStep(step);c.render();w.document.querySelector('#onboardResourceCheck').checked=true;await w.document.querySelector('[data-onboard-resource="'+key+'"]').onclick();}
 record.compliance_acknowledged_at='now';assert.equal(await c.loadOnboarding(),false,'countersignature still missing');signed=true;await c.loadOnboardingChecklist();c.render();assert.equal(w.document.querySelector('#onboardEnter').textContent,'Enter portal');await w.document.querySelector('#onboardEnter').onclick({target:{}});assert.equal(portalLoads,1);assert.equal(c.test.state().complete,true);assert.equal(c.S.tab,'dashboard');
 unavailable=true;await assert.rejects(c.loadOnboarding(),/Temporary outage/);assert.equal(c.test.state().complete,false,'outage must fail closed');c.render();assert(!w.document.querySelector('.portal-topnav'));assert.equal(signingRequests,0,'tests never email an agreement');
 // Direct navigation remains blocked even if someone changes the URL/tab value.
 c.portalSessionEpoch=0;c.S.selected=new Set();c.loadTabData=async()=>{throw Error('Protected data loaded');};vm.runInContext(slice('let portalNavigationBusy=false;','function bindShell()'),c);await c.navigatePortalTab('my-leads');assert.equal(c.S.tab,'onboarding');
 dom.window.close();
}
async function apiGate(){
 const {requirePortalOnboarding}=require('../lib/portal-verification');let response=true,status=200;
 global.fetch=async(url,opts)=>{assert(url.endsWith('/require_portal_onboarding'));assert.equal(opts.headers.Authorization,'Bearer fixture');return {ok:status===200,status,json:async()=>response};};
 await requirePortalOnboarding('Bearer fixture');response=false;await assert.rejects(requirePortalOnboarding('Bearer fixture'),{status:503});
 status=403;response={details:'ONBOARDING_REQUIRED'};await assert.rejects(requirePortalOnboarding('Bearer fixture'),{status:403,code:'ONBOARDING_REQUIRED'});
 status=503;await assert.rejects(requirePortalOnboarding('Bearer fixture'),{status:503});
 // Server authentication cannot trust a client-supplied completion flag.
 const id='11111111-1111-4111-8111-111111111111',session='22222222-2222-4222-8222-222222222222';
 process.env.STRIPE_SECRET_KEY='sk_test_fixture';let checks=0;
 const module={exports:{}};const context={module,process,Buffer,AbortSignal,console,fetch:async url=>({ok:true,json:async()=>url.includes('/auth/')?{id}:[{id,role:'agent',active:true,archived:false}]}),require:n=>n==='./portal-verification'?{requireVerification:async()=>{},requirePortalOnboarding:async()=>{checks++;throw Object.assign(Error('Blocked'),{status:403,code:'ONBOARDING_REQUIRED'});}}:n==='./dialer'?{config:()=>({}),failure:(status,message)=>Object.assign(Error(message),{status}),MASTER:'master'}:n==='./lead-calling'?{UUID:/^[a-f0-9-]{36}$/,rpc:async()=>true}:require(n)};
 vm.runInNewContext(fs.readFileSync('lib/dialer-full.js','utf8'),context);
 const req={headers:{authorization:'Bearer e30.'+Buffer.from(JSON.stringify({sub:id,session_id:session,exp:Date.now()/1000+3600})).toString('base64url')+'.fixture',origin:'https://www.lldportal.com'},method:'POST',body:{action:'prepare',onboardingComplete:true,allowOnboardingCleanup:true}};
 await assert.rejects(module.exports.authenticate(req),{code:'ONBOARDING_REQUIRED'});
 let invoked=0;const handler=module.exports.endpoint(async(req,u)=>{invoked++;return {restricted:u.onboardingRestricted};},{onboardingCleanupActions:['stop']});const res={setHeader(){},status(code){this.code=code;return this;},json(data){this.data=data;return this;}};
 await handler(req,res);assert.equal(res.code,403);assert.equal(invoked,0);
 req.body.action='stop';await handler(req,res);assert.equal(res.code,200);assert.equal(res.data.restricted,true);assert.equal(invoked,1);assert.equal(checks,3);
}
(async()=>{await ui();await apiGate();console.log('PASS: full onboarding screen, both licensing paths, required states, training applicability, signature gate, fail-closed errors, direct navigation and authenticated dialer enforcement. No real calls or emails.');})().catch(e=>{console.error(e);process.exitCode=1;});
