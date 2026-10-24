'use strict';
const {chromium}=require('playwright'),fs=require('node:fs'),path=require('node:path'),assert=require('node:assert/strict');
const {fixture}=require('./crm-workspace-browser.cjs');
const root=path.join(__dirname,'..'),out=process.env.CRM_QA_DIR||'/tmp/vivid-deal-intake-qa';fs.mkdirSync(out,{recursive:true});
const index=fs.readFileSync(path.join(root,'index.html'),'utf8'),styles=[...index.matchAll(/<style(?:\s[^>]*)?>([\s\S]*?)<\/style>|<link[^>]*rel="stylesheet"[^>]*href="([^"]+)"[^>]*>/g)].map(m=>m[1]||fs.readFileSync(path.join(root,m[2].split('?')[0]),'utf8')).join('\n');
async function setup(page){
 const html='<!doctype html><html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><style>'+styles+'</style></head><body><main id="app" style="padding:24px;max-width:1600px;margin:auto"></main></body></html>';
 await page.route('https://crm.test/**',route=>{const p=new URL(route.request().url()).pathname;return route.fulfill(p.startsWith('/assets/')?{contentType:p.endsWith('.svg')?'image/svg+xml':'image/png',body:fs.readFileSync(path.join(root,p))}:{contentType:'text/html',body:html});});
 await page.goto('https://crm.test/');await page.evaluate(fixture);
 await page.evaluate(()=>{
  fixture.rows=[];window.dealDemoLead={id:'lead-demo',first_name:'Taylor',last_name:'Morgan',phone:'2025550123',email:'taylor@example.invalid',state:'MI',lead_type:'Mortgage Protection',csv_headers:['Address','City','Zip'],csv_values:['100 Example Lane','Detroit','48000']};
  const original=api;window.api=async(url,opt)=>{
   if(url.startsWith('/rest/v1/carrier_resources'))return [{carrier:'Aetna'},{carrier:'Ethos'}];
   if(url.endsWith('/chat_deal_agents'))return [{id:S.profile.id,name:'Sample Agent'}];
   if(url.endsWith('/submit_deal_with_client')){
    fixture.calls.push({name:'submit_deal_with_client',p:structuredClone(opt.body)});
    if(fixture.failSubmit)throw Error('Temporary connection issue. Try again.');
    if(fixture.delaySubmit)await new Promise(resolve=>fixture.resolveSubmit=resolve);
    const f=opt.body.p_fields,id='deal-'+(fixture.rows.length+1),row={...f,id,profile_id:id,agent_id:S.profile.id,agent_name:'Sample Agent',status:f.pipeline_stage==='in_force'?'active':'submitted',comp_percent:100,advance_percent:75,estimated_advance:Number(f.monthly_payment)*12*.75,deal_id:'production-'+id,production_recorded:true,carrier_status:'unverified',created_at:new Date().toISOString(),updated_at:new Date().toISOString()};
    fixture.rows.unshift(row);return {ok:true,deal_id:row.deal_id,client_id:id};
   }
   return original(url,opt);
  };
  window.demoOpenLead=()=>PortalDealIntake.open({lead:dealDemoLead,afterSave:async()=>{await bobLoad();render();}});
  window.demoOpenManual=()=>PortalDealIntake.open({division:'vivid_life',afterSave:async()=>{await bobLoad();render();}});
 });
 for(const file of ['crm-products.js','client-phone.js','carrier-logos.js','book-of-business.js','deal-intake.js'])await page.addScriptTag({path:path.join(root,file)});
 await page.evaluate(async()=>{await bobLoad();render();});
}
module.exports={setup,root,out};
if(require.main===module)(async()=>{
 const browser=await chromium.launch({headless:true,executablePath:process.env.CHROMIUM_EXECUTABLE_PATH||undefined,args:['--no-sandbox','--disable-dev-shm-usage']});
 try{
  const page=await browser.newPage({viewport:{width:1440,height:1050}}),errors=[];page.on('pageerror',e=>errors.push(e.message));await setup(page);
  await page.evaluate(()=>demoOpenLead());const form=page.locator('#dealIntakeForm');
  assert.equal(await form.locator('[name=client_name]').inputValue(),'Taylor Morgan');assert.equal(await form.locator('[name=phone]').inputValue(),'202-555-0123');assert.equal(await form.locator('[name=address_line1]').inputValue(),'100 Example Lane');
  await page.locator('#dealIntakeSave').click();assert.equal(await page.evaluate(()=>fixture.calls.filter(c=>c.name==='submit_deal_with_client').length),0);
  await form.locator('[name=carrier]').selectOption('Ethos');assert(await form.locator('[name=policy_type] option').getByText('Ethos Term Life – Prime',{exact:true}).count());
  await form.locator('[name=policy_type]').selectOption('Term');await form.locator('[name=monthly_payment]').fill('100');await form.locator('[name=policy_number]').fill('DEMO-001');await form.locator('[name=pipeline_stage]').selectOption('in_force');
  await page.locator('#dealIntakeSave').click();assert.equal(await page.evaluate(()=>fixture.calls.filter(c=>c.name==='submit_deal_with_client').length),0,'in force requires date');
  await form.locator('[name=effective_date]').fill(await form.locator('[name=application_date]').inputValue());
  assert.equal(await page.locator('#dealSummaryPremium').innerText(),'$100.00');assert.equal(await page.locator('#dealSummaryStage').innerText(),'In force');
  await page.screenshot({path:path.join(out,'complete-deal-desktop.png')});
  await page.evaluate(()=>fixture.failSubmit=true);await page.locator('#dealIntakeSave').click();await page.locator('#dealIntakeError').getByText(/Temporary connection/).waitFor();assert.equal(await form.locator('[name=policy_number]').inputValue(),'DEMO-001');
  await page.evaluate(()=>{fixture.failSubmit=false;fixture.delaySubmit=true;});await page.locator('#dealIntakeSave').click();await page.waitForFunction(()=>!!fixture.resolveSubmit);
  await page.evaluate(()=>document.querySelector('#dealIntakeForm').dispatchEvent(new Event('submit',{bubbles:true,cancelable:true})));assert.equal(await page.evaluate(()=>fixture.calls.filter(c=>c.name==='submit_deal_with_client').length),2,'double click does not duplicate in-flight submit');
  await page.evaluate(()=>{fixture.delaySubmit=false;fixture.resolveSubmit();});await page.waitForFunction(()=>!document.querySelector('#dealIntakeForm'));
  const writes=await page.evaluate(()=>fixture.calls.filter(c=>c.name==='submit_deal_with_client'));assert.equal(writes[0].p.p_request_id,writes[1].p.p_request_id);assert.equal(writes[1].p.p_lead_id,'lead-demo');assert.equal(writes[1].p.p_fields.phone,'202-555-0123');
  await page.locator('.bob-select-client[data-id="deal-1"]').first().click();await page.locator('#bobAddPolicy').waitFor();assert.match(await page.locator('.bob-detail').innerText(),/Taylor Morgan/);assert.match(await page.locator('.bob-detail').innerText(),/Unverified/);assert.match(await page.locator('.bob-detail').innerText(),/\$900.00/);
  await page.evaluate(()=>demoOpenManual());await page.waitForFunction(()=>!document.querySelector('#dealIntakeSave').disabled);
  assert.equal(await form.locator('[name=client_name]').inputValue(),'');assert.equal(await form.locator('[name=phone]').inputValue(),'');
  await form.locator('[name=client_name]').fill('Jordan Blake');await form.locator('[name=phone]').pressSequentially('3135550199');await form.locator('[name=carrier]').selectOption('Aetna');await form.locator('[name=policy_type]').selectOption('Final Expense');await form.locator('[name=monthly_payment]').fill('80');
  await page.setViewportSize({width:390,height:844});await page.screenshot({path:path.join(out,'manual-deal-mobile.png')});assert(await page.evaluate(()=>document.documentElement.scrollWidth<=innerWidth));
  await page.locator('#dealIntakeSave').click();await page.waitForFunction(()=>!document.querySelector('#dealIntakeForm'));assert.equal(await page.evaluate(()=>fixture.rows.length),2);assert.equal(await page.evaluate(()=>fixture.rows[0].effective_date),'');assert.equal(await page.evaluate(()=>fixture.rows[0].pipeline_stage),'submitted');
  // A switched account must not receive a late success callback or saved data.
  await page.evaluate(()=>{fixture.delaySubmit=true;demoOpenManual();});await page.waitForFunction(()=>!document.querySelector('#dealIntakeSave').disabled);
  await form.locator('[name=client_name]').fill('Late Save');await form.locator('[name=phone]').fill('2025550123');await form.locator('[name=carrier]').selectOption('Aetna');await form.locator('[name=policy_type]').selectOption('Final Expense');await form.locator('[name=monthly_payment]').fill('50');await page.locator('#dealIntakeSave').click();
  await page.evaluate(()=>{S.profile={id:'other-user',role:'agent'};document.querySelector('#app').innerHTML='<div id="other-account">Other account</div>';fixture.resolveSubmit();});await page.locator('#other-account').waitFor();
  assert.deepEqual(errors,[]);console.log('PASS: actual shared form, lead/CSV prefill, carrier products, missing-field/date validation, phone formatting, summary, retry identity, double submit, CRM display, manual client, mobile and account isolation.');
 }finally{await browser.close();}
})().catch(e=>{console.error(e);process.exitCode=1;});
