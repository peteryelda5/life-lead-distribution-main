'use strict';
// Browser regression for the page-scroll/sidebar interaction and contact editing.
// Uses fictional local RPC data; never writes production clients.
const {chromium}=require('playwright');
const fs=require('node:fs'),path=require('node:path'),assert=require('node:assert/strict');
const {fixture}=require('./crm-workspace-browser.cjs');
const root=path.join(__dirname,'..'),out=process.env.CRM_QA_DIR||'/tmp/vivid-crm-sidebar-phone-qa';
fs.mkdirSync(out,{recursive:true});
const index=fs.readFileSync(path.join(root,'index.html'),'utf8');
const styles=[...index.matchAll(/<style(?:\s[^>]*)?>([\s\S]*?)<\/style>|<link[^>]*rel="stylesheet"[^>]*href="([^"]+)"[^>]*>/g)].map(m=>m[1]||fs.readFileSync(path.join(root,m[2].split('?')[0]),'utf8')).join('\n');
(async()=>{
 const browser=await chromium.launch({headless:true,executablePath:process.env.CHROMIUM_EXECUTABLE_PATH||undefined,args:['--no-sandbox','--disable-dev-shm-usage']});
 try{
  const page=await browser.newPage({viewport:{width:1600,height:900}}),errors=[];
  page.on('pageerror',e=>errors.push(e.message));
  const html='<!doctype html><html><head><meta name="viewport" content="width=device-width,initial-scale=1"><style>'+styles+'</style></head><body><header class="top portal-topnav" style="height:76px;position:sticky;top:0;z-index:50;background:white"><div class="topin">Vivid Life Portal · Book of business</div></header><main class="wrap" id="app"></main></body></html>';
  await page.route('https://crm.test/**',async route=>{
   const pathname=new URL(route.request().url()).pathname;
   if(pathname.startsWith('/assets/'))return route.fulfill({body:fs.readFileSync(path.join(root,pathname)),contentType:pathname.endsWith('.svg')?'image/svg+xml':'image/png'});
   return route.fulfill({contentType:'text/html',body:html});
  });
  await page.goto('https://crm.test/');await page.evaluate(fixture);
  await page.evaluate(()=>{
   const original=fixture.rows.slice();
   fixture.rows=Array.from({length:60},(_,i)=>({...original[i%5],id:'client-'+i,profile_id:'client-'+i,client_name:i<5?original[i].client_name:'Sample client '+i}));
   fixture.activity=Array.from({length:12},(_,i)=>({id:'activity-'+i,client_id:'client-0',body:'Sample follow-up note '+i,actor_name:'Test agent',created_at:'2026-10-24T12:00:00Z'}));
  });
  await page.addScriptTag({path:path.join(root,'crm-products.js')});
  await page.addScriptTag({path:path.join(root,'carrier-logos.js')});
  await page.addScriptTag({path:path.join(root,'client-phone.js')});await page.addScriptTag({path:path.join(root,'book-of-business.js')});
  await page.evaluate(async()=>{await bobLoad();render();});
  await page.locator('.bob-select-client[data-id="client-0"]').first().click();
  await page.locator('#bobAddPolicy').waitFor();
  const checkSticky=async label=>{
   await page.waitForFunction(()=>Math.abs(document.querySelector('.bob-detail').getBoundingClientRect().top-document.querySelector('.portal-topnav').getBoundingClientRect().bottom-16)<2);
   const box=await page.locator('.bob-detail').boundingBox();
   assert(box.y+box.height<=page.viewportSize().height-15,label+': sidebar fits viewport');
   assert.equal(await page.locator('.bob-detail').evaluate(el=>getComputedStyle(el).position),'sticky');
  };
  await page.evaluate(()=>window.scrollTo(0,1100));await checkSticky('desktop scroll');
  const pageScroll=await page.evaluate(()=>window.scrollY);
  await page.locator('.bob-detail').evaluate(el=>el.scrollTop=el.scrollHeight);
  assert(await page.locator('.bob-detail').evaluate(el=>el.scrollTop>100),'profile details scroll independently');
  assert.equal(await page.evaluate(()=>window.scrollY),pageScroll);
  await page.locator('.bob-detail').evaluate(el=>el.scrollTop=0);
  await page.screenshot({path:path.join(out,'desktop-scrolled.png')});
  await page.locator('.bob-select-client[data-id="client-15"]').first().click();
  await page.waitForFunction(()=>document.querySelector('.bob-detail-person h3')?.textContent==='Sample client 15');
  await checkSticky('selecting a lower client');
  await page.setViewportSize({width:1150,height:800});
  await page.locator('.portal-topnav').evaluate(el=>el.style.height='128px');
  await checkSticky('wrapped header');
  await page.screenshot({path:path.join(out,'wrapped-header-scrolled.png')});
  await page.setViewportSize({width:1600,height:900});
  await page.locator('.portal-topnav').evaluate(el=>el.style.height='76px');

  // Existing contact numbers, typing, paste, caret edits and saving both fields.
  await page.locator('.bob-detail-group summary').first().click();
  await page.locator('#bobEditContact').click();
  const phone=page.locator('#bobContactForm [name=phone]'),alternate=page.locator('#bobContactForm [name=alternate_phone]');
  assert.equal(await phone.inputValue(),'202-555-0100');
  await phone.fill('');await phone.pressSequentially('1231231234');assert.equal(await phone.inputValue(),'123-123-1234');
  await phone.fill('(202) 555-0199');assert.equal(await phone.inputValue(),'202-555-0199');
  await phone.evaluate(el=>el.setSelectionRange(4,4));await phone.press('Backspace');assert.equal(await phone.inputValue(),'205-550-199');assert.equal(await phone.evaluate(el=>el.selectionStart),2);
  await phone.fill('2025550199');await phone.evaluate(el=>el.setSelectionRange(3,3));await phone.press('Delete');assert.equal(await phone.inputValue(),'202-550-199');
  await phone.fill('2025550199');await phone.evaluate(el=>el.setSelectionRange(4,7));await phone.pressSequentially('777');assert.equal(await phone.inputValue(),'202-777-0199');
  await phone.fill('+1 (202) 555-0199');assert.equal(await phone.inputValue(),'+1-202-555-0199');
  await phone.fill('12025550199');assert.equal(await phone.inputValue(),'1-202-555-0199');
  for(const value of ['+44 20 7946 0958','2025550199 ext 45','202555019912']){await phone.fill(value);await phone.blur();assert.equal(await phone.inputValue(),value,'preserve '+value);}
  await phone.fill('');assert.equal(await phone.inputValue(),'');
  await phone.fill('2025550199');await alternate.fill('2125550123');assert.equal(await alternate.inputValue(),'212-555-0123');
  await page.locator('#bobSaveContact').click();await page.waitForFunction(()=>!document.querySelector('#bobContactForm'));
  const saved=await page.evaluate(()=>fixture.calls.filter(c=>c.name==='book_crm_profile_save').at(-1).p.p_fields);
  assert.equal(saved.phone,'202-555-0199');assert.equal(saved.alternate_phone,'212-555-0123');
  await page.locator('.bob-detail-group summary').first().click();
  assert.match(await page.locator('.bob-detail-group').first().innerText(),/202-555-0199/);
  assert.match(await page.locator('.bob-detail-group').first().innerText(),/212-555-0123/);
  assert.equal(await page.locator('.bob-detail-actions a').getAttribute('href'),'tel:2025550199');

  // New-client form also formats both phone fields and submits the displayed values.
  await page.locator('#bobAddClient').click();
  const form=page.locator('#bobClientForm');
  await form.locator('[name=client_name]').fill('Formatting Test');
  await form.locator('[name=phone]').pressSequentially('3135550123');assert.equal(await form.locator('[name=phone]').inputValue(),'313-555-0123');
  await form.locator('[name=carrier]').selectOption('Aetna');
  await form.locator('[name=policy_type]').selectOption({index:1});
  await form.locator('[name=monthly_payment]').fill('50');
  await form.locator('[name=application_date]').fill('2026-10-24');
  await form.locator('[name=effective_date]').fill('2026-11-01');
  await form.locator('.bob-extra summary').click();
  await form.locator('[name=alternate_phone]').fill('(212) 555-0145');
  await page.locator('#bobSaveClient').click();await page.waitForFunction(()=>!document.querySelector('#bobClientForm'));
  const created=await page.evaluate(()=>fixture.calls.filter(c=>c.name==='book_crm_save_v2').at(-1).p.p_fields);
  assert.equal(created.phone,'313-555-0123');assert.equal(created.alternate_phone,'212-555-0145');

  // The desktop stickiness must not change the existing mobile single-column flow.
  await page.setViewportSize({width:390,height:844});
  await page.locator('#bobCloseDetail').click();
  await page.locator('.bob-select-client[data-id="client-0"]').first().click();
  await page.locator('#bobAddPolicy').waitFor();
  await page.waitForFunction(()=>Math.abs(document.querySelector('.bob-detail').getBoundingClientRect().top-document.querySelector('.portal-topnav').getBoundingClientRect().bottom-16)<3);
  assert.notEqual(await page.locator('.bob-detail').evaluate(el=>getComputedStyle(el).position),'sticky');
  assert(await page.evaluate(()=>document.documentElement.scrollWidth<=window.innerWidth),'no mobile page overflow');
  await page.screenshot({path:path.join(out,'mobile-profile.png')});
  assert.deepEqual(errors,[]);console.log('PASS: sticky sidebar, header resize, independent profile scroll, mobile layout, phone typing/paste/caret/deletion, international preservation, new and existing contact saves.');
 }finally{await browser.close();}
})().catch(error=>{console.error(error);process.exitCode=1;});
