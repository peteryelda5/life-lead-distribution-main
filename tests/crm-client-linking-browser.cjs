'use strict';
const {chromium}=require('playwright'),fs=require('node:fs'),path=require('node:path'),assert=require('node:assert/strict');
const {fixture,baseStyle}=require('./crm-workspace-browser.cjs');
const root=path.join(__dirname,'..'),out=process.env.CRM_QA_DIR||'/tmp/vivid-client-linking-qa';fs.mkdirSync(out,{recursive:true});
(async()=>{
 const browser=await chromium.launch({headless:true,args:['--no-sandbox']});
 try{
  const page=await browser.newPage({viewport:{width:1600,height:1050},timezoneId:'America/Detroit'}),errors=[];page.on('pageerror',e=>errors.push(e.message));
  await page.route('https://crm.test/**',route=>route.fulfill({contentType:'text/html',body:'<!doctype html><meta name="viewport" content="width=device-width,initial-scale=1"><style>'+baseStyle+'</style><main id="app" style="padding:20px"></main>'}));await page.goto('https://crm.test/');await page.evaluate(fixture);
  await page.evaluate(()=>{fixture.rows[0].client_name='Client not linked';fixture.rows[0].phone='';fixture.rows[0].email='';});
  for(const f of ['crm-products.js','carrier-logos.js','client-phone.js','book-of-business.js'])await page.addScriptTag({path:path.join(root,f)});
  await page.evaluate(async()=>{await bobLoad();render();});await page.locator('.bob-select-client[data-id=client-0]').first().click();await page.locator('#bobCompleteContact').waitFor();assert.match(await page.locator('.bob-contact-missing').innerText(),/no recorded client name/);await page.screenshot({path:path.join(out,'missing-contact-desktop.png'),fullPage:false});
  await page.locator('#bobCompleteContact').click();assert.equal(await page.locator('#bobContactForm [name=client_name]').inputValue(),'');await page.locator('#bobSaveContact').click();assert.equal(await page.evaluate(()=>fixture.calls.filter(c=>c.name==='book_crm_profile_save').length),0);
  await page.locator('#bobContactForm [name=client_name]').fill('Recovered Client');await page.locator('#bobContactForm [name=phone]').fill('2025550110');await page.evaluate(()=>fixture.failSave=true);await page.locator('#bobSaveContact').click();await page.locator('#bobContactError').getByText(/changed/).waitFor();assert.equal(await page.locator('#bobContactForm [name=client_name]').inputValue(),'Recovered Client');
  await page.setViewportSize({width:390,height:844});await page.screenshot({path:path.join(out,'complete-contact-mobile.png'),fullPage:true});assert(await page.evaluate(()=>document.documentElement.scrollWidth<=innerWidth+1));await page.evaluate(()=>fixture.failSave=false);await page.locator('#bobSaveContact').click();await page.locator('.bob-detail h3').getByText('Recovered Client',{exact:true}).waitFor();assert.equal(await page.locator('#bobCompleteContact').count(),0);assert.equal(await page.evaluate(()=>fixture.rows[0].pipeline_stage),'in_force');
  await page.locator('#bobRefresh').click();await page.locator('.bob-detail h3').getByText('Recovered Client',{exact:true}).waitFor();
  // Exercise the actual chat deal form, including required input and retry request ID.
  await page.evaluate(()=>{
   window.portalCarrierSelectHtml=id=>'<select id="'+id+'" name="p_carrier" required><option value="Ethos">Ethos</option></select>';
   window.portalFillDealCarriers=()=>{};window.adminDivisionList=()=>['vivid_life'];window.divisionLabel=()=> 'Vivid Life';S.profile.division='vivid_life';
   const original=api;window.api=async(url,opt)=>{
    if(url.endsWith('/chat_deal_agents'))return [{id:S.profile.id,name:'Test agent'}];
    if(url.endsWith('/submit_deal_with_client')){fixture.calls.push({name:'submit_deal_with_client',p:structuredClone(opt.body)});if(fixture.failChat)throw Error('Temporary save failure');return 'deal-1';}
    return original(url,opt);
   };
  });
  await page.addScriptTag({path:path.join(root,'deal-intake.js')});await page.addScriptTag({path:path.join(root,'live-chat.js')});await page.evaluate(()=>chatDealModal());await page.waitForFunction(()=>document.querySelector('#dealIntakeForm [name=agent_id]')?.value===S.profile.id);await page.locator('#dealIntakeForm [name=carrier]').selectOption('Ethos');await page.locator('#dealIntakeForm [name=monthly_payment]').fill('100');await page.locator('#dealIntakeForm [name=policy_type]').selectOption('Term');await page.locator('#dealIntakeSave').click();assert.equal(await page.evaluate(()=>fixture.calls.filter(c=>c.name==='submit_deal_with_client').length),0);
  await page.locator('#dealIntakeForm [name=client_name]').fill('New Chat Client');await page.locator('#dealIntakeForm [name=phone]').fill('202-555-0112');await page.locator('#dealIntakeForm .bob-extra summary').click();await page.locator('#dealIntakeForm [name=email]').fill('new@example.invalid');await page.evaluate(()=>fixture.failChat=true);await page.locator('#dealIntakeSave').click();await page.locator('#dealIntakeError').getByText('Temporary save failure').waitFor();await page.screenshot({path:path.join(out,'chat-client-fields-mobile.png'),fullPage:true});assert(await page.evaluate(()=>document.documentElement.scrollWidth<=innerWidth+1));
  await page.evaluate(()=>fixture.failChat=false);await page.locator('#dealIntakeSave').click();await page.waitForFunction(()=>!document.querySelector('#dealIntakeForm'));
  const writes=await page.evaluate(()=>fixture.calls.filter(c=>c.name==='submit_deal_with_client'));assert.equal(writes.length,2);assert.equal(writes[0].p.p_request_id,writes[1].p.p_request_id);assert.equal(writes[1].p.p_fields.client_name,'New Chat Client');assert.equal(writes[1].p.p_fields.phone,'202-555-0112');assert.equal(writes[1].p.p_fields.email,'new@example.invalid');
  assert.deepEqual(errors,[]);console.log('PASS: missing-contact guidance, empty required name, error preservation, contact save/reload, unchanged stage, desktop/mobile layout, chat required client fields and idempotent retry payload. Screenshots: '+out);
 }finally{await browser.close();}
})().catch(e=>{console.error(e);process.exitCode=1;});
