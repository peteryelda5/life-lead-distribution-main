'use strict';
const {chromium}=require('playwright'),fs=require('node:fs'),path=require('node:path'),assert=require('node:assert/strict');
const root=path.join(__dirname,'..'),out=process.env.CRM_QA_DIR||'/tmp/vivid-comp-grid-qa';fs.mkdirSync(out,{recursive:true});
const index=fs.readFileSync(path.join(root,'index.html'),'utf8'),styles=[...index.matchAll(/<style>([\s\S]*?)<\/style>|<link[^>]*rel="stylesheet"[^>]*href="([^"]+)"[^>]*>/g)].map(m=>m[1]||fs.readFileSync(path.join(root,m[2].split('?')[0]),'utf8')).join('\n');
(async()=>{
 const browser=await chromium.launch({headless:true,args:['--no-sandbox']});
 try{
  const page=await browser.newPage({viewport:{width:1600,height:1100},timezoneId:'America/Detroit'}),errors=[];page.on('pageerror',e=>errors.push(e.message));
  await page.route('https://comp.test/**',route=>route.fulfill({contentType:'text/html',body:'<!doctype html><meta name="viewport" content="width=device-width,initial-scale=1"><style>'+styles+'</style><main id="app" style="padding:24px"></main>'}));await page.goto('https://comp.test/');
  await page.evaluate(()=>{
   window.q=s=>document.querySelector(s);window.qa=s=>[...document.querySelectorAll(s)];window.esc=x=>String(x??'').replace(/[&<>"']/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));window.money=n=>'$'+Number(n||0).toFixed(2);window.sidebarIcon=()=>'';
   window.S={profile:{id:'master',full_name:'Peter Yelda',role:'admin',is_super_admin:true,division:'demo'},tab:'book-business'};
   window.fixture={rows:[],calls:[],failSave:false,delaySave:false};window.flash=x=>window.lastFlash=x;
   window.modal=html=>document.body.insertAdjacentHTML('beforeend','<div id="modal" class="modal"><div class="modalbox">'+html+'</div></div>');window.closeModal=()=>q('#modal')?.remove();
   window.api=async(url,{body:p})=>{const n=url.split('/').pop();fixture.calls.push({n,p:structuredClone(p)});
    if(n==='agency_branding_context')return {agency:{id:'demo',name:'Vivid Life'},manageable:[]};
    if(n==='book_access')return {has_pin:true,unlocked:true,expires_at:new Date(Date.now()+900000).toISOString()};
    if(n==='book_crm_profiles_list')return {rows:[],count:0,policy_count:0,stage_counts:{},monthly_payment:0,estimated_advance:0};
    if(n==='book_grid'){
     if(p.p_action==='save'){
      if(fixture.delaySave)await new Promise(r=>fixture.resolveSave=r);if(fixture.failSave)throw Error('Rate could not be saved. Try again.');
      const value={agent_id:p.p_agent,carrier:p.p_carrier.toLowerCase().trim(),policy_type:p.p_policy_type.toLowerCase().trim(),comp_percent:p.p_comp,advance_percent:p.p_advance,effective_date:p.p_effective};
      const old=fixture.rows.find(r=>r.agent_id===value.agent_id&&r.carrier===value.carrier&&r.policy_type===value.policy_type&&r.effective_date===value.effective_date);if(old)Object.assign(old,value);else fixture.rows.push(value);
     }
     return {agents:S.profile.is_super_admin?[{id:'master',full_name:'Peter Yelda'},{id:'agent',full_name:'Test Agent'}]:[{id:S.profile.id,full_name:S.profile.full_name}],rows:structuredClone(fixture.rows.filter(r=>S.profile.is_super_admin||r.agent_id===S.profile.id))};
    }
    throw Error('Unexpected RPC '+n);
   };window.render=()=>{q('#app').innerHTML=bobPage();bobBind();};
  });
  for(const file of ['crm-products.js','carrier-logos.js','client-phone.js','book-of-business.js'])await page.addScriptTag({path:path.join(root,file)});
  await page.evaluate(async()=>{await bobLoad();render();});await page.locator('[data-bob-tab=grid]').click();await page.locator('#bobCompResults').waitFor();
  const catalog=await page.evaluate(()=>PORTAL_CRM_PRODUCTS);assert.equal(catalog.length,15);assert(catalog.flatMap(c=>c.products).every(p=>p.every(v=>typeof v==='string')),'product catalog contains labels, never commission values');
  for(const c of catalog){assert(new Set(c.products.map(p=>p[0]+(p[1]?' — '+p[1]:''))).size===c.products.length);assert(c.products.every(p=>(p[0]+(p[1]?' — '+p[1]:'')).length<=100),'product name fits save RPC');}
  assert.equal(await page.locator('#bobCompConfiguredCount').innerText(),'0');assert.equal(await page.locator('.bob-comp-percent:not(.is-unset)').count(),0);
  // Every built-in carrier has a bundled, decoded logo; a failed image must not hide its fallback.
  assert.equal(await page.locator('#bobCompResults [data-bob-carrier-logo]').count(),18);
  await page.waitForFunction(()=>[...document.querySelectorAll('#bobCompResults [data-bob-carrier-logo]')].every(box=>{const img=box.querySelector('img');return img?.complete&&img.naturalWidth>0&&!img.hidden&&box.querySelector('span').hidden;}));
  const addedCarriers=['United Home Life','American Amicable','Mutual of Omaha','Royal Neighbors','Banner Life (LGA)'];
  for(const carrier of addedCarriers){
   const box=page.locator('[data-bob-carrier-logo]').filter({has:page.getByRole('img',{name:carrier+' logo',exact:true})});
   assert.equal(await box.count(),1);assert.match(await box.locator('img').getAttribute('src'),/^data:image\/(?:png|svg\+xml);base64,/);
  }
  await page.screenshot({path:path.join(out,'comp-grid-desktop.png'),fullPage:false});
  await page.locator('#bobCompSearch').fill('Ethos');assert.equal(await page.locator('.bob-comp-carrier').count(),1);assert.equal(await page.locator('.bob-comp-table tbody tr').count(),6);
  await page.getByRole('button',{name:'Set rate for Ethos TruStage Advantage Whole Life',exact:true}).click();assert.equal(await page.locator('#bobGridForm [name=comp]').inputValue(),'');assert.equal(await page.locator('#bobGridForm [name=advance]').inputValue(),'');
  await page.screenshot({path:path.join(out,'comp-rate-editor.png'),fullPage:true});
  await page.locator('#bobGridForm [name=comp]').fill('92.5');await page.locator('#bobGridForm [name=advance]').fill('70');await page.locator('#bobGridForm [name=effective]').fill('2026-01-01');
  await page.evaluate(()=>fixture.failSave=true);await page.locator('#bobSaveComp').click();await page.locator('#bobGridError').getByText(/could not be saved/).waitFor();assert.equal(await page.locator('#bobGridForm [name=comp]').inputValue(),'92.5');
  await page.evaluate(()=>{fixture.failSave=false;fixture.delaySave=true;});await page.evaluate(()=>{q('#bobGridForm').requestSubmit();q('#bobGridForm').requestSubmit();});await page.waitForFunction(()=>fixture.resolveSave);assert.equal(await page.evaluate(()=>fixture.calls.filter(c=>c.n==='book_grid'&&c.p.p_action==='save').length),2,'double submit makes just one additional save');await page.evaluate(()=>{fixture.delaySave=false;fixture.resolveSave();});await page.waitForFunction(()=>!q('#bobGridForm'));
  assert.equal(await page.locator('.bob-comp-percent:not(.is-unset)').innerText(),'92.5%');assert.equal(await page.locator('#bobCompConfiguredCount').innerText(),'1');
  for(const [rate,date] of [['95.25','2026-06-01'],['105','2027-01-01']]){await page.getByRole('button',{name:'Set rate for Ethos TruStage Advantage Whole Life',exact:true}).click();await page.locator('#bobGridForm [name=comp]').fill(rate);await page.locator('#bobGridForm [name=effective]').fill(date);await page.locator('#bobSaveComp').click();await page.waitForFunction(()=>!q('#bobGridForm'));}
  assert.equal(await page.locator('.bob-comp-percent:not(.is-unset)').innerText(),'95.25%');assert.match(await page.locator('.bob-comp-effective').first().innerText(),/scheduled/);await page.locator('.bob-comp-history summary').click();assert.equal(await page.locator('.bob-comp-history li').count(),3);
  // Changing an edit target must never carry another agent/product's saved rate.
  await page.getByRole('button',{name:'Set rate for Ethos TruStage Advantage Whole Life',exact:true}).click();
  assert.equal(await page.locator('#bobGridForm [name=comp]').inputValue(),'95.25');
  await page.locator('#bobGridForm [name=agent]').selectOption('agent');assert.equal(await page.locator('#bobGridForm [name=comp]').inputValue(),'');
  await page.locator('#bobGridForm [name=agent]').selectOption('master');assert.equal(await page.locator('#bobGridForm [name=comp]').inputValue(),'95.25');
  await page.locator('#bobGridForm [name=type]').selectOption('Ethos Term Life – Prime');assert.equal(await page.locator('#bobGridForm [name=comp]').inputValue(),'');assert.equal(await page.locator('#bobGridForm [name=advance]').inputValue(),'');
  await page.locator('#bobCancel').click();
  await page.locator('#bobCompOnlySet').check();assert.equal(await page.locator('.bob-comp-table tbody tr').count(),1);await page.locator('#bobCompSearch').fill('Nothing matches');await page.getByText('No matching products').waitFor();await page.locator('#bobCompSearch').fill('');
  await page.locator('#bobCompAgent').selectOption('agent');await page.getByText('No matching products').waitFor();assert.equal(await page.locator('#bobCompConfiguredCount').innerText(),'0');await page.locator('#bobCompOnlySet').uncheck();
  await page.locator('#bobCompSearch').fill('F&G');assert.equal(await page.locator('.bob-comp-table tbody tr').count(),7);assert.equal(await page.locator('.bob-comp-annuity-label').count(),4);
  // Legacy/general and unfamiliar saved products remain visible and are never mapped to a new product.
  await page.evaluate(async()=>{fixture.rows.push({agent_id:'agent',carrier:'ethos',policy_type:'term',comp_percent:0,advance_percent:0,effective_date:'2026-01-01'},{agent_id:'agent',carrier:'<custom carrier>',policy_type:'<custom product>',comp_percent:83,advance_percent:75,effective_date:'2027-01-01'});await bobLoad();render();});
  await page.locator('#bobCompSearch').fill('ethos');assert.equal(await page.locator('.bob-comp-table tbody tr').count(),7);assert.equal(await page.locator('.bob-comp-percent:not(.is-unset)').innerText(),'0%');
  await page.locator('#bobCompSearch').fill('custom carrier');assert.equal(await page.locator('.bob-comp-table script').count(),0);assert.equal(await page.locator('[data-bob-carrier-logo] img').count(),0);assert(await page.locator('[data-bob-carrier-logo] span').isVisible());assert.match(await page.locator('.bob-comp-carrier').innerText(),/<custom product>/);assert.equal(await page.locator('.bob-comp-percent').innerText(),'—');assert.match(await page.locator('.bob-comp-effective').innerText(),/Scheduled/);
  await page.locator('#bobAddRate').click();await page.locator('#bobGridForm [name=carrier]').fill('Aetna');await page.locator('#bobGridForm [name=carrier]').press('Tab');await page.locator('#bobGridForm [name=type]').selectOption('__custom__');await page.locator('#bobGridForm [name=customProduct]').fill('Agency product');await page.locator('#bobGridForm [name=comp]').fill('87');await page.locator('#bobGridForm [name=advance]').fill('75');await page.locator('#bobSaveComp').click();await page.waitForFunction(()=>!q('#bobGridForm'));assert(await page.evaluate(()=>fixture.rows.some(r=>r.agent_id==='agent'&&r.policy_type==='agency product'&&r.comp_percent===87)));
  // Product names in policy entry match the grid; life premiums do not price annuity products.
  await page.locator('#bobAddClient').click();await page.locator('#bobClientForm [name=carrier]').selectOption('Ethos');await page.locator('#bobClientForm [name=policy_type]').selectOption('TruStage Advantage Whole Life');await page.locator('#bobClientForm [name=carrier]').selectOption('Transamerica');assert.equal(await page.locator('#bobClientForm [name=policy_type]').inputValue(),'');await page.locator('#bobClientForm [name=policy_type]').selectOption('FE Express Solution Level');await page.locator('#bobClientForm [name=carrier]').selectOption('F&G');assert(!await page.locator('#bobClientForm [name=policy_type]').innerText().then(t=>t.includes('Annuity')));await page.locator('#bobCancel').click();
  await page.setViewportSize({width:390,height:844});
  for(const carrier of addedCarriers){await page.locator('#bobCompSearch').fill(carrier);await page.waitForFunction(()=>{const img=document.querySelector('#bobCompResults .bob-policy-logo img');return img?.complete&&img.naturalWidth>0&&!img.hidden;});assert(await page.evaluate(()=>document.documentElement.scrollWidth<=innerWidth+1));await page.screenshot({path:path.join(out,'logo-'+carrier.toLowerCase().replace(/[^a-z]+/g,'-')+'.png'),fullPage:true});}
  await page.locator('#bobCompSearch').fill('Ethos');await page.setViewportSize({width:390,height:844});await page.screenshot({path:path.join(out,'comp-grid-mobile.png'),fullPage:true});assert(await page.evaluate(()=>document.documentElement.scrollWidth<=innerWidth+1));
  await page.getByRole('button',{name:'Set rate for Ethos TruStage Advantage Whole Life',exact:true}).click();await page.screenshot({path:path.join(out,'comp-editor-mobile.png'),fullPage:true});assert(await page.evaluate(()=>document.documentElement.scrollWidth<=innerWidth+1));await page.locator('#bobCancel').click();
  // Agent/agency-admin viewers have no write or PIN-reset controls.
  await page.evaluate(async()=>{S.profile={id:'agent',full_name:'Test Agent',role:'agent',is_super_admin:false,division:'demo'};bobReset();await bobLoad();render();});await page.locator('[data-bob-tab=grid]').click();await page.locator('#bobCompResults').waitFor();assert.equal(await page.locator('#bobAddRate,#bobResetPin,[data-comp-carrier]').count(),0);assert.equal(await page.locator('#bobCompConfiguredCount').innerText(),'3');
  await page.evaluate(async()=>{S.profile.role='admin';await bobLoad();render();});assert.equal(await page.locator('#bobAddRate,#bobResetPin,[data-comp-carrier]').count(),0);
  assert.deepEqual(errors,[]);console.log('PASS: all 18 carrier logos, five added official logos on mobile, custom carrier fallback, 15 carrier catalogs, blank rates, exact manual save, duplicate-submit protection, failure/retry, effective-date history, scheduled rates, zero rates, agent scope, custom/legacy products, escaping, matching life product selectors, read-only roles, and desktop/mobile layout. Screenshots: '+out);
 }finally{await browser.close();}
})().catch(e=>{console.error(e);process.exitCode=1;});
