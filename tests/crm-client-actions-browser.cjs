'use strict';
const {chromium}=require('playwright'),fs=require('node:fs'),path=require('node:path'),assert=require('node:assert/strict');
const {fixture,baseStyle}=require('./crm-workspace-browser.cjs');
const root=path.join(__dirname,'..'),out=process.env.CRM_QA_DIR||'/tmp/vivid-client-actions-qa';fs.mkdirSync(out,{recursive:true});
(async()=>{
 const browser=await chromium.launch({headless:true,args:['--no-sandbox']});
 try{
  const page=await browser.newPage({viewport:{width:1600,height:1050},timezoneId:'America/Detroit'}),errors=[];page.on('pageerror',e=>errors.push(e.message));
  await page.route('https://crm.test/**',route=>route.fulfill({contentType:'text/html',body:'<!doctype html><meta name="viewport" content="width=device-width,initial-scale=1"><style>'+baseStyle+'</style><main id="app" style="padding:20px"></main>'}));await page.goto('https://crm.test/');await page.evaluate(fixture);
  await page.evaluate(()=>{
   const original=api;
   window.api=async(url,opt)=>{
    const name=url.split('/').pop(),p=opt.body;
    if(name==='book_crm_profile_delete'){
     fixture.calls.push({name,p:structuredClone(p)});if(fixture.delayDelete)await new Promise(r=>fixture.resolveDelete=r);
     if(fixture.failDelete)throw Error('Client or policies changed. Reopen the client before deleting it.');
     const ids=fixture.rows.filter(r=>r.profile_id===p.p_id).map(r=>r.id);fixture.rows=fixture.rows.filter(r=>!ids.includes(r.id));fixture.tasks=fixture.tasks.filter(t=>!ids.includes(t.client_id));return {ok:true};
    }
    const result=await original(url,opt);
    if(name==='book_crm_profile_detail')result.can_delete_profile=!fixture.readOnly;
    if(name==='book_crm_carrier_status_save'){
     fixture.tasks=fixture.tasks.filter(t=>t.id!=='carrier-task');
     fixture.tasks.push({id:'carrier-task',client_id:p.p_policy,source:'carrier_status',priority:'high',carrier_status:p.p_status,title:'Carrier follow-up: '+p.p_status.replaceAll('_',' '),due_at:new Date().toISOString(),updated_at:new Date().toISOString()});
    }
    return result;
   };
  });
  for(const f of ['crm-products.js','carrier-logos.js','client-phone.js','book-of-business.js'])await page.addScriptTag({path:path.join(root,f)});
  await page.evaluate(async()=>{await bobLoad();render();});await page.locator('.bob-select-client[data-id="client-0"]').first().click();await page.locator('#bobDeleteClient').waitFor();
  for(const [status,label] of [['initial_premium_failed','Initial premium failed'],['grace_period','Grace period'],['late_offer_period','Late offer period'],['lapsed','Lapsed'],['cancelled','Cancelled'],['declined','Declined'],['chargeback','Chargeback']]){
   await page.locator('[data-bob-carrier-status="client-0"]').click();await page.locator('#bobCarrierForm [name=status]').selectOption(status);await page.locator('#bobCarrierForm [name=source]').selectOption('carrier_portal');await page.locator('#bobCarrierForm [name=confirmed_on]').fill('2026-10-21');await page.locator('#bobCarrierForm [name=reference]').fill('Carrier follow-up test');await page.locator('#bobSaveCarrier').click();
   await page.locator('.bob-detail .bob-carrier-badge.action-required').getByText('Carrier: '+label,{exact:true}).waitFor();await page.locator('.bob-detail .bob-task-urgent').waitFor();assert.match(await page.locator('.bob-detail .bob-task-priority').innerText(),new RegExp(label));
  }
  await page.locator('.bob-tabs [data-bob-tab=tasks]').click();await page.locator('.bob-tasks .bob-task-urgent').waitFor();assert.match(await page.locator('.bob-task-priority').innerText(),/Chargeback/);await page.screenshot({path:path.join(out,'red-agent-task-desktop.png'),fullPage:false});
  await page.locator('.bob-task-row .bob-select-client').click();await page.locator('#bobDeleteClient').waitFor();await page.locator('.bob-detail [data-bob-task="carrier-task"]').click();await page.waitForFunction(()=>fixture.tasks[0].completed_at);assert.equal(await page.locator('.bob-task-urgent').count(),0);
  await page.locator('.bob-tabs [data-bob-tab=clients]').click();await page.locator('.bob-select-client[data-id="client-0"]').first().click();await page.locator('#bobDeleteClient').click();
  await page.getByRole('heading',{name:'Delete Olivia Bennett?'}).waitFor();assert.match(await page.locator('.bob-delete-warning').innerText(),/Recorded closed deals and commission history stay/);assert.equal(await page.evaluate(()=>fixture.calls.filter(c=>c.name==='book_crm_profile_delete').length),0);await page.locator('#bobCancel').click();assert.equal(await page.locator('#bobDeleteClient').count(),1);
  // Multi-policy confirmation, failure preservation, double-click suppression, and exact version payload.
  await page.evaluate(async()=>{fixture.rows.push({...fixture.rows[0],id:'sibling',carrier:'Ethos',policy_type:'Term'});await bobLoad();render();});await page.locator('#bobDeleteClient').click();assert.match(await page.locator('.bob-delete-warning').innerText(),/2 policies/);assert.equal(await page.locator('.bob-delete-policies li').count(),2);
  await page.evaluate(()=>fixture.failDelete=true);await page.locator('#bobConfirmDelete').click();await page.locator('#bobDeleteError').getByText(/Reopen/).waitFor();assert.equal(await page.evaluate(()=>fixture.rows.length),6);
  await page.setViewportSize({width:390,height:844});await page.screenshot({path:path.join(out,'delete-client-mobile.png'),fullPage:true});assert(await page.evaluate(()=>document.documentElement.scrollWidth<=innerWidth+1));
  await page.evaluate(()=>{fixture.failDelete=false;fixture.delayDelete=true;document.querySelector('#bobConfirmDelete').click();document.querySelector('#bobConfirmDelete').click();});await page.waitForFunction(()=>fixture.resolveDelete);assert.equal(await page.evaluate(()=>fixture.calls.filter(c=>c.name==='book_crm_profile_delete').length),2);
  const payload=await page.evaluate(()=>fixture.calls.filter(c=>c.name==='book_crm_profile_delete').at(-1).p);assert.equal(payload.p_id,'client-0');assert.equal(payload.p_expected_policies.length,2);assert(payload.p_expected_policies.every(p=>p.updated_at&&'deal_version'in p));
  await page.evaluate(()=>{fixture.delayDelete=false;fixture.resolveDelete();});await page.waitForFunction(()=>!document.querySelector('#bobConfirmDelete'));assert.equal(await page.locator('.bob-detail').count(),0);assert.equal(await page.evaluate(()=>fixture.rows.length),4);assert.equal(await page.locator('.bob-select-client[data-id="client-0"]').count(),0);
  await page.evaluate(()=>fixture.readOnly=true);await page.locator('.bob-select-client[data-id="client-1"]').first().click();await page.locator('#bobAddNote').waitFor();assert.equal(await page.locator('#bobDeleteClient').count(),0);
  // A late deletion response must not overwrite another account's view.
  await page.evaluate(async()=>{fixture.readOnly=false;await bobLoad();render();});await page.locator('#bobDeleteClient').click();await page.evaluate(()=>fixture.delayDelete=true);await page.locator('#bobConfirmDelete').click();await page.waitForFunction(()=>fixture.resolveDelete);await page.evaluate(()=>{S.profile={id:'other',role:'agent'};bobReset();fixture.resolveDelete();render();});await page.waitForTimeout(50);assert.equal(await page.locator('#bobConfirmDelete,.bob-detail').count(),0);
  assert.deepEqual(errors,[]);console.log('PASS: seven red carrier/task labels, task-to-client link, completion styling, delete confirmation/cancel, two-policy versions, failed deletion, duplicate-submit guard, successful removal, read-only scope, mobile overflow and account-change safety. Screenshots: '+out);
 }finally{await browser.close();}
})().catch(e=>{console.error(e);process.exitCode=1;});
