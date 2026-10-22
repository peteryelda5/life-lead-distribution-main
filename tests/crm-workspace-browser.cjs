'use strict';
// Actual Chromium rendering and UI interactions, with a local RPC fixture.
// Database persistence/authorization are exercised separately by crm-workspace.sql.
const {chromium}=require('playwright'),fs=require('node:fs'),path=require('node:path'),assert=require('node:assert/strict');
const root=path.join(__dirname,'..'),out=process.env.CRM_QA_DIR||'/tmp/vivid-crm-qa';fs.mkdirSync(out,{recursive:true});
const index=fs.readFileSync(path.join(root,'index.html'),'utf8'),baseStyle=[...index.matchAll(/<style>([\s\S]*?)<\/style>|<link[^>]*rel="stylesheet"[^>]*href="([^"]+)"[^>]*>/g)].map(m=>m[1]||fs.readFileSync(path.join(root,m[2].split('?')[0]),'utf8')).join('\n');
const fixture=()=>{
 window.q=s=>document.querySelector(s);window.qa=s=>[...document.querySelectorAll(s)];
 window.esc=x=>String(x??'').replace(/[&<>"']/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
 window.money=n=>new Intl.NumberFormat('en-US',{style:'currency',currency:'USD'}).format(n||0);window.sidebarIcon=()=>'';
 window.S={profile:{id:'owner',full_name:'Peter Yelda',role:'admin',is_super_admin:true},tab:'book-business'};
 window.flash=()=>{};window.modal=html=>document.body.insertAdjacentHTML('beforeend','<div id="modal" class="modal"><div class="modalbox">'+html+'</div></div>');window.closeModal=()=>q('#modal')?.remove();
 const names=['Olivia Bennett','Marcus Reed','Sophia Hayes','Daniel Brooks','Emma Collins'];const stages=['in_force','approved','submitted','contacted','new'];
 window.fixture={calls:[],tasks:[],activity:[],unlocked:true,failSave:false,failLoad:false,delayDetail:false,resolvers:[],clock:0,rows:names.map((name,i)=>({id:'client-'+i,agent_id:'owner',agent_name:'Peter Yelda',client_name:name,phone:'2025550100',email:'demo@example.invalid',policy_type:['Final Expense','Term','IUL','Whole Life','Final Expense'][i],carrier:['Aetna','SBLI','Transamerica','Foresters Financial','Americo'][i],monthly_payment:125,application_date:'2026-10-10',effective_date:i<2?'2026-10-15':null,pipeline_stage:stages[i],status:i===0?'active':i===1?'issued':i===2?'submitted':'draft',notes:'',updated_at:'2026-10-22T12:00:00.000Z',created_at:'2026-10-22T12:00:00.000Z',deal_version:null}))};
 const f=window.fixture,copy=x=>JSON.parse(JSON.stringify(x)),version=()=>new Date(Date.UTC(2026,9,22,16,0,++f.clock)).toISOString();
 window.api=async(url,opt)=>{
  const name=url.split('/').pop(),p=opt.body||{};f.calls.push({name,p:copy(p)});
  if(name==='book_access'){if(p.p_action==='lock')f.unlocked=false;return {has_pin:true,unlocked:f.unlocked,expires_at:new Date(Date.now()+900000).toISOString()};}
  if(name==='book_grid')return {agents:[{id:'owner',full_name:'Peter Yelda'},{id:'agent',full_name:'Test agent'}],rows:[]};
  if(name==='book_crm_workspace'){
   if(f.failLoad)throw Error('Temporarily unavailable');
   const searched=f.rows.filter(r=>[r.client_name,r.carrier,r.policy_type].join(' ').toLowerCase().includes((p.p_search||'').toLowerCase())&&(!p.p_agent||r.agent_id===p.p_agent));
   const filtered=searched.filter(r=>!p.p_stage||r.pipeline_stage===p.p_stage),counts={};searched.forEach(r=>counts[r.pipeline_stage]=(counts[r.pipeline_stage]||0)+1);
   const tasks=f.tasks.filter(t=>filtered.some(r=>r.id===t.client_id)&&((p.p_task_status==='completed')===Boolean(t.completed_at))).map(t=>({...t,client_name:f.rows.find(r=>r.id===t.client_id).client_name,agent_name:'Peter Yelda'}));
   return copy({rows:p.p_view==='clients'?filtered.slice((p.p_page-1)*p.p_limit,p.p_page*p.p_limit):[],pipeline:p.p_view==='pipeline'?filtered:[],tasks:p.p_view==='tasks'?tasks:[],count:filtered.length,task_count:tasks.length,stage_counts:counts,monthly_payment:250,estimated_advance:1000,followups_due:0});
  }
  if(name==='book_crm_detail'){
   if(f.delayDetail)await new Promise(resolve=>f.resolvers.push(resolve));
   const r=f.rows.find(r=>r.id===p.p_id);if(!r)throw Error('Client not available');return copy({client:r,tasks:f.tasks.filter(t=>t.client_id===r.id),activity:f.activity.filter(a=>a.client_id===r.id)});
  }
  if(name==='book_crm_save_v2'){
   if(f.failSave)throw Error('Client changed. Reopen the client and try again.');
   let r=f.rows.find(r=>r.id===p.p_id);if(r&&r.updated_at!==p.p_expected_updated_at)throw Error('Stale update');if(!r){r={id:p.p_id,created_at:version(),deal_version:null};f.rows.unshift(r);}Object.assign(r,p.p_fields,{updated_at:version(),agent_name:r.agent_id==='agent'?'Test agent':'Peter Yelda'});return {ok:true,id:r.id};
  }
  if(name==='book_crm_action'){
   if(p.p_action==='note')f.activity.unshift({id:p.p_id,client_id:p.p_client,body:p.p_body,actor_name:'Peter Yelda',created_at:version()});
   if(p.p_action==='task')f.tasks.push({id:p.p_id,client_id:p.p_client,title:p.p_title,due_at:p.p_due_at,updated_at:version()});
   if(['complete','reopen'].includes(p.p_action)){const t=f.tasks.find(t=>t.id===p.p_id);t.completed_at=p.p_action==='complete'?version():null;t.updated_at=version();}
   return {ok:true};
  }
  throw Error('Unexpected RPC '+name);
 };
 window.render=()=>{q('#app').innerHTML=bobPage();bobBind();};
};
(async()=>{
 const browser=await chromium.launch({headless:true,args:['--no-sandbox']});
 try{
  const context=await browser.newContext({viewport:{width:1600,height:1000},timezoneId:'America/Detroit'}),page=await context.newPage(),errors=[];page.on('pageerror',e=>errors.push(e.message));
  const testHtml='<!doctype html><html><head><meta name="viewport" content="width=device-width,initial-scale=1"><style>'+baseStyle+'</style></head><body style="background:#f2f5fa"><main id="app" style="padding:24px;max-width:1800px;margin:auto"></main></body></html>';
  await page.route('https://crm.test/**',route=>route.fulfill({contentType:'text/html',body:testHtml}));await page.goto('https://crm.test/');
  await page.evaluate(fixture);await page.addScriptTag({path:path.join(root,'book-of-business.js')});await page.evaluate(async()=>{await bobLoad();render();});
  assert.equal(await page.locator('.bob-client-table tbody tr').count(),5);
  await page.locator('.bob-select-client[data-id="client-0"]').click();await page.locator('#bobEditClient').waitFor();assert.match(await page.locator('.bob-detail').innerText(),/Policy details/);
  await page.screenshot({path:path.join(out,'clients-desktop.png'),fullPage:true});
  await page.locator('#bobAddNote').click();await page.locator('[name=body]').fill('<script>unsafe</script> Real client note');await page.locator('#bobActivitySave').click();await page.locator('#bobAddNote').waitFor();assert.match(await page.locator('.bob-timeline').innerText(),/Real client note/);assert.equal(await page.locator('.bob-timeline script').count(),0);
  await page.locator('#bobAddTask').click();await page.locator('[name=title]').fill('Welcome call');await page.locator('[name=due]').fill('2026-11-02T10:30');await page.locator('#bobActivitySave').click();await page.locator('.bob-task-row').waitFor();assert.match(await page.locator('.bob-task-row').innerText(),/Welcome call/);
  assert.equal(await page.evaluate(()=>fixture.calls.filter(c=>c.name==='book_crm_action').at(-1).p.p_due_at),'2026-11-02T15:30:00.000Z','local time converted across DST');
  await page.locator('.bob-task-check').click();await page.waitForFunction(()=>fixture.tasks[0].completed_at);await page.locator('.bob-tabs [data-bob-tab=tasks]').click();await page.locator('[name=taskStatus]').waitFor();await page.locator('[name=taskStatus]').selectOption('completed');await page.locator('#bobSearch button[type=submit], #bobSearch button:not([type])').first().click();await page.locator('.bob-task-check.done').waitFor();await page.locator('.bob-task-check.done').click();await page.waitForFunction(()=>!fixture.tasks[0].completed_at);
  await page.locator('.bob-tabs [data-bob-tab=pipeline]').click();await page.locator('.bob-pipeline-card').first().waitFor();assert.equal(await page.locator('.bob-pipeline-column').count(),5);await page.screenshot({path:path.join(out,'pipeline-desktop.png'),fullPage:true});
  await page.locator('[data-bob-move="client-4"]').selectOption('contacted');await page.waitForFunction(()=>fixture.rows.find(r=>r.id==='client-4').pipeline_stage==='contacted');await page.locator('[data-drop-stage=contacted] [data-drag-client=client-4]').waitFor();
  await page.locator('[data-drag-client=client-4]').dragTo(page.locator('[data-drop-stage=submitted]'));await page.waitForFunction(()=>fixture.rows.find(r=>r.id==='client-4').pipeline_stage==='submitted');
  await page.locator('[data-bob-move="client-2"]').selectOption('in_force');await page.locator('#bobClientForm').waitFor();assert.equal(await page.locator('[name=pipeline_stage]').inputValue(),'in_force');assert(await page.locator('[name=effective_date]').evaluate(e=>e.required));await page.locator('#bobCancel').click();
  await page.locator('#bobAddClient').click();await page.screenshot({path:path.join(out,'add-client-desktop.png'),fullPage:true});
  for(const [key,value] of Object.entries({client_name:'Taylor Morgan',phone:'2025550199',monthly_payment:'125',application_date:'2026-10-22',effective_date:'2026-11-01'}))await page.locator('[name='+key+']').fill(value);
  await page.locator('[name=agent_id]').selectOption('agent');await page.locator('[name=carrier]').selectOption('Americo');await page.locator('[name=policy_type]').selectOption('Final Expense');await page.locator('.bob-extra summary').click();await page.locator('[name=alternate_phone]').fill('2025550198');await page.locator('[name=date_of_birth]').fill('1980-04-15');await page.locator('[name=mortgage_balance]').fill('150000');
  await page.evaluate(()=>fixture.failSave=true);await page.locator('#bobSaveClient').click();await page.locator('#bobClientError').getByText(/Client changed/).waitFor();assert.equal(await page.locator('[name=client_name]').inputValue(),'Taylor Morgan');await page.evaluate(()=>fixture.failSave=false);await page.locator('#bobSaveClient').click();await page.locator('.bob-detail h3').getByText('Taylor Morgan',{exact:true}).waitFor();
  const saved=await page.evaluate(()=>fixture.rows.find(r=>r.client_name==='Taylor Morgan'));assert.equal(saved.agent_id,'agent');assert.equal(saved.application_date,'2026-10-22');assert.equal(saved.effective_date,'2026-11-01');assert.equal(saved.alternate_phone,'2025550198');assert.equal(saved.mortgage_balance,'150000');
  await page.evaluate(async()=>{await bobLoad();render();});assert.match(await page.locator('.bob-detail').innerText(),/Taylor Morgan/);
  await page.locator('#bobCloseDetail').click();await page.locator('[name=search]').fill('Americo');await page.locator('#bobSearch button:not([type])').click();await page.waitForFunction(()=>document.querySelectorAll('.bob-client-table tbody tr').length===2);assert.match(await page.locator('.bob-client-table').innerText(),/Taylor Morgan/);
  await page.locator('#bobClearFilters').click();await page.waitForFunction(()=>document.querySelectorAll('.bob-client-table tbody tr').length===6);
  await page.setViewportSize({width:390,height:844});await page.locator('#bobAddClient').click();await page.locator('.bob-extra summary').click();await page.screenshot({path:path.join(out,'add-client-mobile.png'),fullPage:true});assert.equal(await page.locator('.bob-client-fields').first().evaluate(e=>getComputedStyle(e).gridTemplateColumns.split(' ').length),1);assert(await page.evaluate(()=>document.documentElement.scrollWidth<=innerWidth+1),'no page-wide overflow on mobile');
  await page.locator('#bobCancel').click();await page.screenshot({path:path.join(out,'clients-mobile.png'),fullPage:true});assert(await page.evaluate(()=>document.documentElement.scrollWidth<=innerWidth+1),'table scroll contained');
  await page.evaluate(()=>{fixture.delayDetail=true;document.querySelector('.bob-select-client[data-id="client-0"]').click();});await page.waitForFunction(()=>fixture.resolvers.length===1);await page.evaluate(()=>{S.profile={id:'different',role:'agent',full_name:'Other agent'};bobReset();fixture.resolvers[0]();});await page.waitForTimeout(40);await page.evaluate(()=>render());assert.equal(await page.locator('.bob-detail').count(),0,'old account response discarded');
  assert.deepEqual(errors,[]);await context.close();console.log('PASS: Chromium desktop/mobile, sidebar, all Add client fields, agency owner, separate dates, stages, missing-date guard, note escaping, follow-ups/DST/completion/reopen, search, reload, failure recovery and account-race safety. Screenshots: '+out);
 }finally{await browser.close();}
})().catch(e=>{console.error(e);process.exitCode=1;});
