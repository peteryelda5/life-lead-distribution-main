'use strict';
const {chromium}=require('playwright'),fs=require('node:fs'),path=require('node:path'),assert=require('node:assert/strict');
const root=path.join(__dirname,'..'),out=process.env.ONBOARDING_QA_DIR||'/tmp/vivid-centered-onboarding-qa';
fs.mkdirSync(out,{recursive:true});
const source=fs.readFileSync(path.join(root,'portal-app.js'),'utf8');
const onboardingCode=source.slice(source.indexOf('const ONBOARDING_VERSION='),source.indexOf('function renderContent()'));
const styles=[...fs.readFileSync(path.join(root,'index.html'),'utf8').matchAll(/<style(?:\s[^>]*)?>([\s\S]*?)<\/style>/g)].map(m=>m[1]).join('\n')+fs.readFileSync(path.join(root,'corporate-blue.css'),'utf8')+fs.readFileSync(path.join(root,'onboarding.css'),'utf8');
function installFixture(){
 window.S={profile:{id:'fictional-agent',full_name:'Alex Morgan',email:'alex@example.com',role:'agent',active:true},session:{access_token:'FAKE'},tab:'onboarding'};
 window.app=document.querySelector('#app');window.q=s=>document.querySelector(s);window.qa=s=>[...document.querySelectorAll(s)];window.esc=v=>String(v??'').replace(/[&<>"']/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
 window.fixture={record:{},resources:{},agreement:null,writes:[],signingRequests:0,failSave:false};
 const state=()=>{const r=fixture.record,L=r.is_licensed===true,steps=[!!r.welcome_read_at,!!r.compliance_acknowledged_at&&fixture.agreement?.status==='completed',L||!!fixture.resources.xcel,L||!!fixture.resources.study,L||!!fixture.resources.exam,r.is_licensed===false||(L&&!!r.npn&&!!r.licensed_states?.length)];return {steps,complete:steps.every(Boolean),allowed:steps.every(Boolean),required:true};};
 window.api=async(route,opt={})=>{const b=opt.body||{};
  if(route.includes('portal_onboarding_status'))return state();
  if(route.includes('save_portal_licensing')){if(fixture.failSave)throw Error('Save failed. Your entries are still here.');fixture.writes.push(b);fixture.record={...fixture.record,is_licensed:b.p_licensed,...(b.p_licensed?{npn:b.p_npn,licensed_states:b.p_states}:{})};return;}
  if(route.includes('save_portal_onboarding_checklist')){fixture.record={...fixture.record,welcome_read_at:b.p_welcome?'saved':null,compliance_acknowledged_at:b.p_compliance?'saved':null};return;}
  if(route.includes('portal_onboarding_checklists'))return [fixture.record];if(route.includes('portal_onboarding_receipts'))return [];
  throw Error('Unexpected API '+route);
 };
 window.fetch=async(url,opt)=>{assertLocal(url);const b=JSON.parse(opt.body);if(b.action==='sign')fixture.signingRequests++;if(b.action==='resource')fixture.resources[b.key]=b.complete;return {ok:true,json:async()=>({provider:'SignWell',environment:'live',signingReady:true,agreement:fixture.agreement,resources:fixture.resources})};};
 function assertLocal(url){if(url!=='/api/docusign/portal')throw Error('Unexpected external request');}
 for(const name of ['resetChatSocial','stopChat','stopLeaderboard','stopRequestBadge','logout','flash'])window[name]=()=>{};
 window.alertHtml=()=>'';window.sessionExpiresWithin=()=>false;window.loadCore=async()=>{};
}
(async()=>{
 const browser=await chromium.launch({headless:true,...(process.env.CHROMIUM_EXECUTABLE_PATH?{executablePath:process.env.CHROMIUM_EXECUTABLE_PATH}:{}),args:['--no-sandbox','--disable-dev-shm-usage']});
 try{
  const page=await browser.newPage({viewport:{width:1440,height:1000}}),errors=[];page.on('pageerror',e=>errors.push(e.message));
  await page.route('**/*',route=>route.request().url()==='https://onboarding.test/'?route.fulfill({contentType:'text/html',body:'<!doctype html><meta name="viewport" content="width=device-width,initial-scale=1"><style>'+styles+'</style><div id="app"></div>'}):route.abort());
  await page.goto('https://onboarding.test/');await page.evaluate(installFixture);
  await page.addScriptTag({content:onboardingCode+fs.readFileSync(path.join(root,'onboarding.js'),'utf8')+`;window.render=()=>{if(ONBOARDING.complete)app.innerHTML='<p id="portalReady">Portal</p>';else onboardingView();};window.demo={step:async n=>{onboardStep=n;await loadOnboardingChecklist();render();},reset:async()=>{ONBOARDING.complete=false;await loadOnboarding();render();}};`});
  await page.evaluate(()=>demo.reset());assert.equal(await page.locator('.onboard-progress button').count(),6);
  const capture=async(name)=>{await page.evaluate(()=>scrollTo(0,0));assert(await page.evaluate(()=>document.documentElement.scrollWidth<=innerWidth+1),name+' must not overflow horizontally');await page.screenshot({path:path.join(out,name+'.png'),fullPage:true});};
  await capture('01-welcome-desktop');await page.locator('.onboard-welcome-letter summary').click();await page.locator('#onboardWelcome').check();await page.locator('#onboardSaveLetter').click();await page.locator('#onboardingChecklistForm').waitFor();await page.locator('[name=isLicensed][value=yes]').check();await page.locator('[name=npn]').fill('1234567');
  await page.locator('[name=licensedState][value=MI]').check();await page.locator('[name=licensedState][value=OH]').check();await page.locator('[name=licensedState][value=FL]').check();await capture('02-licensing-desktop');
  await page.locator('#onboardStateSearch').fill('new york');assert.equal(await page.locator('.onboard-state-option:visible').count(),1);await page.locator('[name=licensedState][value=NY]').check();assert.equal(await page.locator('#onboardStateCount').innerText(),'4 states selected');
  await page.locator('#onboardStateSearch').fill('xyz');assert(await page.locator('#onboardStateEmpty').isVisible());await page.locator('#onboardStateSearch').fill('');await page.locator('#onboardShowStates').click();assert.equal(await page.locator('.onboard-state-option:visible').count(),51);await page.locator('#onboardShowStates').click();assert.equal(await page.locator('.onboard-state-option:visible').count(),10,'selected non-default state stays visible');
  await page.evaluate(()=>fixture.failSave=true);await page.locator('button[type=submit]').click();await page.locator('#onboardingSaveStatus').getByText(/Save failed/).waitFor();assert.equal(await page.locator('[name=npn]').inputValue(),'1234567');assert(await page.locator('[name=licensedState][value=NY]').isChecked());
  await page.evaluate(()=>fixture.failSave=false);await page.locator('#onboardStateSearch').fill('MI');await page.locator('button[type=submit]').click();await page.locator('#onboardCompliance').waitFor();assert.deepEqual((await page.evaluate(()=>fixture.writes.at(-1).p_states)).sort(),['FL','MI','NY','OH']);
  await page.locator('#onboardCompliance').check();await page.locator('#onboardSaveLetter').click();await page.evaluate(async()=>{fixture.agreement={status:'signed',waiting_on:'agency',envelope_id:'fake',signing_method:'email'};await demo.step(2);});await capture('03-agreements-desktop');assert.match(await page.locator('.onboard-signature-list').innerText(),/Your signature\s+Complete/);assert.match(await page.locator('.onboard-signature-list').innerText(),/Peter Yelda’s signature\s+Pending/);
  await page.evaluate(()=>demo.step(3));assert.match(await page.locator('.onboard-task').innerText(),/Not required for agents who are already licensed/);
  await page.evaluate(()=>demo.step(6));await page.locator('[name=isLicensed][value=no]').check();assert(await page.locator('[name=npn]').isDisabled());await page.locator('button[type=submit]').click();await page.locator('#onboardViewLetter').waitFor();
  for(const [step,key,name] of [[3,'xcel','04-training-desktop'],[4,'study','05-study-desktop'],[5,'exam','06-exam-pending-desktop']]){await page.evaluate(n=>demo.step(n),step);await capture(name);await page.locator('#onboardResourceCheck').check();await page.locator('[data-onboard-resource="'+key+'"]').click();}
  assert.equal(await page.locator('.onboard-progress [aria-current=step]').getAttribute('data-onboard-step'),'5','exam save remains on the final checklist');assert.equal(await page.locator('#onboardEnter').innerText(),'Check progress');await page.locator('#onboardEnter').click();assert.equal(await page.locator('#portalReady').count(),0,'missing countersignature cannot unlock');
  await page.evaluate(async()=>{fixture.agreement={...fixture.agreement,status:'completed',waiting_on:null};await demo.step(5);});assert.equal(await page.locator('#onboardEnter').innerText(),'Enter portal');await capture('06-exam-complete-desktop');
  assert.equal(await page.locator('.onboard-page-actions #onboardEnter').count(),1);await page.locator('#onboardResourceCheck').uncheck();assert(await page.locator('#onboardEnter').isHidden());assert(await page.locator('[data-onboard-resource=exam]').isVisible());await page.locator('#onboardResourceCheck').check();await page.locator('[data-onboard-resource=exam]').click();assert(await page.locator('#onboardEnter').isVisible());
  for(const width of [390,320]){await page.setViewportSize({width,height:844});for(const step of [1,6,2,3,4,5]){await page.evaluate(n=>demo.step(n),step);if(step===6){await page.locator('[name=isLicensed][value=yes]').check();await page.locator('#onboardStateSearch').fill('');}await capture('mobile-'+width+'-step-'+step);}}
  // Use the real gate handler with the mock canonical status, then verify successful entry.
  await page.evaluate(()=>demo.step(5));await page.locator('#onboardEnter').click();await page.locator('#portalReady').waitFor();assert.equal(await page.evaluate(()=>fixture.signingRequests),0);assert.deepEqual(errors,[]);
  console.log('PASS: six desktop pages; 390px and 320px layouts; both license paths; full-name search; 51 states; hidden selections preserved; failed-save retry; individual signature statuses; final checklist; gate prevents unsigned entry. No real emails or account changes.');
 }finally{await browser.close();}
})().catch(e=>{console.error(e);process.exitCode=1;});
