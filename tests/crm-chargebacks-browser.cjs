'use strict';
const {chromium}=require('playwright'),fs=require('node:fs'),path=require('node:path'),assert=require('node:assert/strict');
const {fixture,baseStyle}=require('./crm-workspace-browser.cjs');
const root=path.join(__dirname,'..'),out=process.env.CRM_QA_DIR||'/tmp/vivid-chargeback-qa';fs.mkdirSync(out,{recursive:true});
(async()=>{
 const browser=await chromium.launch({headless:true,args:['--no-sandbox']});
 try{
  const page=await browser.newPage({viewport:{width:1700,height:1050},timezoneId:'America/Detroit'}),errors=[];page.on('pageerror',e=>errors.push(e.message));
  await page.route('https://crm.test/**',route=>route.fulfill({contentType:'text/html',body:'<!doctype html><meta name="viewport" content="width=device-width,initial-scale=1"><style>'+baseStyle+'</style><main id="app" style="padding:20px"></main>'}));await page.goto('https://crm.test/');await page.evaluate(fixture);
  for(const f of ['crm-products.js','carrier-logos.js','book-of-business.js'])await page.addScriptTag({path:path.join(root,f)});
  await page.evaluate(async()=>{await bobLoad();render();});
  await page.locator('.bob-tabs [data-bob-tab=pipeline]').click();await page.locator('[data-drop-stage=chargeback]').waitFor();assert.equal(await page.locator('[data-drop-stage=chargeback] .bob-pipeline-card').count(),0);
  // An empty Chargeback column is available as a real drop target.
  await page.locator('[data-drag-client=client-0] .bob-drag-handle').dragTo(page.locator('[data-drop-stage=chargeback]'),{targetPosition:{x:100,y:260}});
  await page.locator('[data-drop-stage=chargeback] [data-drag-client=client-0]').waitFor();assert.match(await page.locator('#bobMoveStatus').innerText(),/moved to Chargeback/);
  await page.waitForTimeout(350); // The existing drag handler suppresses accidental clicks for 300ms.
  assert.deepEqual(await page.evaluate(()=>fixture.calls.filter(c=>c.name==='book_crm_save_v2').at(-1).p.p_fields),{pipeline_stage:'chargeback'});
  await page.locator('#bobRefresh').click();await page.locator('[data-drop-stage=chargeback] [data-drag-client=client-0]').waitFor();await page.screenshot({path:path.join(out,'chargeback-pipeline.png'),fullPage:true});
  await page.locator('[data-bob-display=list]').click();await page.locator('#bobSearch [name=stage]').selectOption('chargeback');await page.waitForFunction(()=>document.querySelectorAll('.bob-client-table tbody tr').length===1);
  await page.locator('.bob-client-table .stage-chargeback').waitFor();assert.equal(await page.locator('.bob-client-table tbody tr').count(),1);
  await page.locator('.bob-select-client[data-id=client-0]').first().click();await page.locator('[data-bob-carrier-status=client-0]').click();
  await page.locator('#bobCarrierForm [name=status]').selectOption('chargeback');await page.locator('#bobCarrierForm [name=source]').selectOption('carrier_statement');await page.locator('#bobCarrierForm [name=confirmed_on]').fill('2026-10-21');await page.locator('#bobCarrierForm [name=reference]').fill('Synthetic statement');await page.locator('#bobSaveCarrier').click();await page.locator('.bob-detail .bob-carrier-badge.action-required').getByText('Carrier: Chargeback',{exact:true}).waitFor();
  await page.locator('.bob-detail [data-bob-move=client-0]').selectOption('approved');await page.waitForFunction(()=>fixture.rows[0].pipeline_stage==='approved');assert.equal(await page.evaluate(()=>fixture.rows[0].carrier_status),'chargeback');
  const csv=await page.evaluate(()=>PORTAL_CRM_CSV.rows([fixture.rows[0]]));assert.match(csv,/Chargeback/);assert.match(csv,/Approved/);
  await page.locator('#bobCloseDetail').click();await page.locator('#bobClearFilters').click();await page.locator('[data-bob-display=board]').click();
  await page.setViewportSize({width:390,height:844});await page.locator('[data-drag-client=client-0] .bob-card-menu summary').click();await page.locator('[data-bob-move=client-0]').selectOption('chargeback');await page.locator('[data-drop-stage=chargeback] [data-drag-client=client-0]').waitFor();await page.locator('[data-drop-stage=chargeback]').scrollIntoViewIfNeeded();await page.screenshot({path:path.join(out,'chargeback-mobile.png'),fullPage:false});assert(await page.evaluate(()=>document.documentElement.scrollWidth<=innerWidth+1));
  await page.locator('.bob-tabs [data-bob-tab=clients]').click();await page.locator('[data-bob-filter=chargeback]').click();await page.waitForFunction(()=>document.querySelectorAll('.bob-profiles-table tbody tr').length===1);assert.match(await page.locator('.bob-profiles-table').innerText(),/Olivia Bennett/);
  assert.deepEqual(errors,[]);console.log('PASS: empty Chargeback drop target, drag/save/refresh, server filter payload, list label, carrier confirmation, stage independence, CSV labels, mobile move control and client filter. Screenshots: '+out);
 }finally{await browser.close();}
})().catch(e=>{console.error(e);process.exitCode=1;});
