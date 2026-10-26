'use strict';
const {chromium}=require('playwright'),assert=require('node:assert/strict'),path=require('node:path');
const {fixture,baseStyle}=require('./crm-workspace-browser.cjs');
(async()=>{const browser=await chromium.launch({headless:true,executablePath:process.env.CHROMIUM_EXECUTABLE,args:['--no-sandbox']});try{
 const page=await browser.newPage();await page.route('https://crm.test/**',r=>r.fulfill({contentType:'text/html',body:'<style>'+baseStyle+'</style><main id="app"></main>'}));await page.goto('https://crm.test/');await page.evaluate(fixture);
 await page.evaluate(()=>{fixture.rows[0].monthly_payment='81.12';fixture.rows[0].status='submitted';fixture.rows[0].pipeline_stage='approved';});
 for(const f of ['crm-products.js','carrier-logos.js','client-phone.js','book-of-business.js'])await page.addScriptTag({path:path.join(__dirname,'..',f)});
 await page.evaluate(async()=>{await bobLoad();render();});
 const row=page.locator('.bob-profiles-table tbody tr').filter({has:page.locator('[data-id="client-0"]')});assert.equal(await row.locator('td').nth(2).innerText(),'$81.12/mo');
 await row.locator('.bob-select-client').first().click();await page.locator('.bob-profile-meta').waitFor();assert.match(await page.locator('.bob-profile-meta').innerText(),/81.12\/mo across all policies/);
 await page.evaluate(()=>{fixture.rows.push({...fixture.rows[0],id:'second-policy',monthly_payment:'19.99',status:'cancelled',pipeline_stage:'cancelled'});});
 await page.evaluate(async()=>{await bobLoad();render();});assert.equal(await row.locator('td').nth(2).innerText(),'$101.11/mo');
 await row.locator('.bob-select-client').first().click();await page.waitForFunction(()=>document.querySelector('.bob-profile-meta')?.textContent.includes('101.11'));assert.match(await page.locator('.bob-totals').innerText(),/active \/ issued premium/);
 console.log('PASS: approved premium, decimal multi-policy totals, historical policy inclusion, profile/list consistency, active total label');
}finally{await browser.close();}})().catch(e=>{console.error(e);process.exit(1);});
