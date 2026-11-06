const fs=require('node:fs'),assert=require('node:assert/strict'),{JSDOM}=require('jsdom');
const source=fs.readFileSync('portal-app.js','utf8'),dom=new JSDOM('<main></main>',{url:'https://example.test',runScripts:'outside-only'}),w=dom.window;
w.S={profile:{id:'owner',role:'admin',active:true,is_super_admin:true},agents:[{id:'agent1',full_name:'Demo <Agent>',email:'demo@example.test',division:'vivid',active:true},{id:'agent2',full_name:'Disabled Agent',email:'off@example.test',division:'vivid',active:false},{id:'other',full_name:'Other Agency',division:'other',active:true}],agentStats:{agent1:{open_leads:5,annual_premium:1200}}};
w.q=s=>w.document.querySelector(s);w.qa=s=>[...w.document.querySelectorAll(s)];w.esc=x=>String(x??'').replaceAll('&','&amp;').replaceAll('<','&lt;').replaceAll('"','&quot;');w.money=x=>'$'+x;w.organizationInitials=()=> 'DA';w.operatingDivision=()=> 'vivid';w.divisionLabel=x=>x;w.hasMultipleAdminDivisions=()=>false;w.canManageTeam=a=>a.division==='vivid'&&w.S.profile.role==='admin';
w.modal=html=>w.document.body.insertAdjacentHTML('beforeend','<div id="modal"><div class="modalbox">'+html+'</div></div>');w.closeModal=()=>w.q('#modal')?.remove();
w.portalSessionEpoch=1;w.onboardingServer=async()=>({rows:[]});
let calls=[];for(const name of ['moveAccountAgentModal','toggleAgent','openAgentSupport','resetAgentMfa','teamSettingsModal','reclaimAgentLeads','editAgentModal','archiveAgent'])w[name]=(...args)=>{assert.equal(w.q('#modal'),null,'profile closes before original action');calls.push([name,...args])};
w.eval(source.slice(source.indexOf('function agentPage()'),source.indexOf('\nfunction adminsPage()')));
w.q('main').innerHTML=w.agentPage();w.bindAgentDirectory();assert.equal(w.qa('[data-agent-row]').length,2);assert.equal(w.q('main .toggle'),null);assert.equal(w.q('main agent'),null);
w.q('#agentDirectorySearch').value='disabled';w.q('#agentDirectorySearch').oninput();assert.equal(w.qa('[data-agent-row]:not([hidden])').length,1);
w.openAgentProfile('other');assert.equal(w.q('#modal'),null);
for(const [selector,expected] of [['.editAgent','editAgentModal'],['.editTeam','teamSettingsModal'],['.moveAccountAgent','moveAccountAgentModal'],['.viewAgent','openAgentSupport'],['.reclaimAgentLeads','reclaimAgentLeads'],['.resetMfa','resetAgentMfa'],['.toggle','toggleAgent'],['.archiveAgent','archiveAgent']]){w.openAgentProfile('agent1');assert.equal(w.q('#agentProfileTitle').textContent,'Demo <Agent>');w.q(selector).click();assert.equal(calls.at(-1)[0],expected);assert.equal(calls.at(-1)[1],'agent1')}
w.openAgentProfile('agent2');assert.ok(w.q('.viewAgent').disabled);assert.ok(w.q('.reclaimAgentLeads').disabled);assert.equal(w.q('.toggle').textContent,'Enable account');w.q('#agentProfileClose').click();assert.equal(w.q('#modal'),null);
w.S.profile.is_super_admin=false;w.openAgentProfile('agent1');assert.equal(w.q('.moveAccountAgent'),null);assert.equal(w.q('.viewAgent'),null);w.q('#modal').dispatchEvent(new w.KeyboardEvent('keydown',{key:'Escape',bubbles:true}));assert.equal(w.q('#modal'),null);
console.log('PASS: scoped directory and profiles, search, escaped names, all eight existing action handlers, disabled states, restricted controls, close and Escape');

(async()=>{
 w.S.profile.is_super_admin=true;let resolve;
 w.onboardingServer=()=>new Promise(r=>{resolve=r});
 w.openAgentProfile('agent1');resolve({rows:[{id:'agent1',licensing:{isLicensed:true,npn:'123456',states:['MI','FL','MI']}}]});await new Promise(setImmediate);
 assert.match(w.q('#agentProfileLicensing').textContent,/Licensed states \(2\)/);assert.match(w.q('#agentProfileLicensing').textContent,/123456/);assert.match(w.q('#agentProfileLicensing').textContent,/Self-reported/);
 const html=w.agentProfileLicensingHtml({isLicensed:false});assert.match(html,/Not licensed yet/);assert.match(html,/No licensed states provided/);assert.match(w.agentProfileLicensingHtml(),/Not provided/);
 w.q('#agentLicenseRefresh').click();const old=w.q('#agentProfileLicensing');w.portalSessionEpoch++;resolve({rows:[{id:'agent1',licensing:{npn:'SHOULD_NOT_RENDER'}}]});await new Promise(setImmediate);assert.ok(!old.textContent.includes('SHOULD_NOT_RENDER'));
 w.onboardingServer=async()=>{throw Error('offline')};w.openAgentProfile('agent1');await new Promise(setImmediate);assert.match(w.q('#agentProfileLicensing').textContent,/Unable to load/);assert.ok(w.q('#agentLicenseRefresh'));
 console.log('PASS: licensing status, NPN, deduplicated states, missing data, self-report label, account-switch guard and retry');
})().catch(e=>{console.error(e);process.exitCode=1});
