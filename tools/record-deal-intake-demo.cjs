'use strict';
// A real screen recording of the new UI with fictional local RPC fixtures.
// Run with Playwright available in NODE_PATH; output is not a production claim.
const {chromium}=require('playwright'),fs=require('node:fs'),path=require('node:path'),{spawnSync}=require('node:child_process');
const {setup}=require('../tests/deal-intake-browser.cjs');
const out=process.env.DEAL_DEMO_DIR||'/tmp/vivid-deal-demo';fs.mkdirSync(out,{recursive:true});
(async()=>{
 const browser=await chromium.launch({headless:true,executablePath:process.env.CHROMIUM_EXECUTABLE_PATH||undefined,args:['--no-sandbox','--disable-dev-shm-usage']});
 const context=await browser.newContext({viewport:{width:1440,height:1000},recordVideo:{dir:path.join(out,'raw'),size:{width:1440,height:1000}}});
 const page=await context.newPage();await setup(page);
 await page.evaluate(()=>{
  document.body.insertAdjacentHTML('beforeend','<div id="demoLabel" style="position:fixed;top:8px;left:50%;transform:translateX(-50%);z-index:99999;border-radius:24px;background:#0f2545;color:white;padding:10px 20px;font:600 13px system-ui;letter-spacing:.03em">VIVID LIFE PORTAL · FICTIONAL TRAINING DEMO</div><div id="demoCaption" style="position:fixed;bottom:8px;left:50%;transform:translateX(-50%);z-index:99999;border-radius:10px;background:#102749;color:white;padding:13px 24px;font:500 17px system-ui;text-align:center;width:max-content;max-width:88vw"></div><div id="demoPointer" style="position:fixed;z-index:100000;pointer-events:none;width:20px;height:20px;border:3px solid #3979f4;background:#3979f433;border-radius:50%;left:-100px;top:-100px;transform:translate(-50%,-50%)"></div>');
  document.addEventListener('mousemove',e=>{const p=document.querySelector('#demoPointer');p.style.left=e.clientX+'px';p.style.top=e.clientY+'px';});
 });
 const wait=ms=>page.waitForTimeout(ms);
 const caption=async text=>{await page.locator('#demoCaption').evaluate((el,t)=>el.textContent=t,text);};
 const card=async(title,subtitle)=>{await page.evaluate(({title,subtitle})=>{const el=document.createElement('div');el.id='demoCard';el.style='position:fixed;inset:0;z-index:99998;background:linear-gradient(135deg,#f5f9ff,#e8f1fc);display:grid;place-items:center;text-align:center;color:#12335e;font-family:system-ui';const inner=document.createElement('div'),h=document.createElement('h1'),p=document.createElement('p');h.style='font-size:44px;letter-spacing:-1.5px;margin:0 0 18px';h.textContent=title;p.style='font-size:20px;color:#567292';p.textContent=subtitle;inner.append(h,p);el.append(inner);document.body.append(el);},{title,subtitle});await wait(2800);await page.locator('#demoCard').evaluate(el=>el.remove());};
 const move=async locator=>{const box=await locator.boundingBox();if(box)await page.mouse.move(box.x+box.width*.5,box.y+box.height*.5,{steps:12});};
 const click=async selector=>{const el=page.locator(selector).first();await el.scrollIntoViewIfNeeded();await move(el);await wait(300);await el.click();await wait(400);};
 const fill=async(name,value)=>{const el=page.locator('#dealIntakeForm [name="'+name+'"]');await el.scrollIntoViewIfNeeded();await move(el);await el.fill('');await el.pressSequentially(value,{delay:75});await wait(350);};
 const select=async(name,value)=>{const el=page.locator('#dealIntakeForm [name="'+name+'"]');await el.scrollIntoViewIfNeeded();await move(el);await el.selectOption(value);await wait(700);};
 await caption('Preview of the proposed update — not connected to production data.');
 await card('One deal. A complete CRM record.','Two examples: an existing lead and a manually entered client');
 await page.evaluate(()=>demoOpenLead());await caption('1 · Existing lead: the client’s name, phone and saved contact details are prefilled.');await wait(3300);
 await caption('Choose the carrier and product, then enter the premium and policy details.');
 await select('carrier','Ethos');await select('policy_type','Term');await fill('monthly_payment','100');await fill('policy_number','DEMO-001');
 await select('pipeline_stage','in_force');await page.locator('#dealIntakeForm [name=effective_date]').fill(await page.locator('#dealIntakeForm [name=application_date]').inputValue());
 await caption('In force requires an effective date. The live summary updates as you fill the form.');await wait(3500);
 await click('#dealIntakeSave');await page.waitForFunction(()=>!document.querySelector('#dealIntakeForm'));
 await caption('One submission creates the client and policy, and records production.');await click('.bob-select-client[data-id="deal-1"]');await wait(3000);
 await page.locator('.bob-detail').evaluate(el=>el.scrollTop=520);await caption('The CRM shows comp and estimated advance from saved rates. Carrier status stays separate.');await wait(4200);
 await card('2 · A manually entered client','The same required form works for a deal entered through chat');
 await page.evaluate(()=>{document.querySelector('.bob-detail').scrollTop=0;demoOpenManual();});await page.waitForFunction(()=>!document.querySelector('#dealIntakeSave').disabled);
 await caption('Enter the client once — no separate CRM entry to remember.');await fill('client_name','Jordan Blake');await fill('phone','3135550199');await wait(1200);
 await caption('Enter the policy. Pending applications can leave the effective date blank.');await select('carrier','Aetna');await select('policy_type','Final Expense');await fill('monthly_payment','80');await wait(2700);
 await click('#dealIntakeSave');await page.waitForFunction(()=>!document.querySelector('#dealIntakeForm'));
 await click('.bob-select-client[data-id="deal-2"]');await caption('Jordan’s new client record and submitted policy now appear in the CRM automatically.');await wait(3800);
 await caption('Simulation with fictional data. Deployment is awaiting database approval.');await card('Fill it once. Keep the CRM complete.','Required client details · One save · Automatic CRM update');await wait(1800);
 const video=page.video();await context.close();const raw=await video.path();await browser.close();
 const target=path.join(out,'vivid-deal-to-crm-demo.mp4');
 const ff=spawnSync('ffmpeg',['-y','-i',raw,'-vf','fps=24','-c:v','libx264','-preset','fast','-crf','20','-pix_fmt','yuv420p','-movflags','+faststart',target],{encoding:'utf8'});if(ff.status)throw Error(ff.stderr);
 console.log(target);
})().catch(e=>{console.error(e);process.exitCode=1;});
