'use strict';
const {chromium}=require('playwright'),assert=require('node:assert/strict'),fs=require('node:fs'),path=require('node:path'),http=require('node:http');
const base=path.resolve(__dirname,'..');
const server=http.createServer((req,res)=>{if(req.url==='/'){res.setHeader('Content-Type','text/html');res.end('<!doctype html><html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1"><link rel="stylesheet" href="/portal-dialer.css"><link rel="stylesheet" href="/dialer-parallel.css"><link rel="stylesheet" href="/dialer-operations.css"><style>body{margin:0;font-family:Arial,sans-serif;background:#f2f7fd}.test-header{background:#122c4c;color:white;padding:20px 30px;display:flex;gap:50px;align-items:center}.test-header b{font-size:22px;letter-spacing:1px}.test-header span{font-size:14px}#portalDialer{max-width:1320px;margin:auto}@media(max-width:600px){.test-header{padding:16px;gap:20px}.test-header span{display:none}}</style></head><body><header class="test-header"><b>VIVID LIFE</b><span>Home</span><span>Leads</span><span>Clients</span><span>Power Dialer</span></header><div id="portalDialer"></div></body></html>');return;}const file=path.join(base,decodeURIComponent(req.url.split('?')[0]));if(!file.startsWith(base+path.sep)||!fs.existsSync(file)){res.writeHead(404);res.end();return;}res.setHeader('Content-Type',file.endsWith('.css')?'text/css; charset=utf-8':'text/javascript; charset=utf-8');fs.createReadStream(file).pipe(res);});
(async()=>{await new Promise(r=>server.listen(0,'127.0.0.1',r));let testPage;const browser=await chromium.launch({headless:true,...(process.env.CHROMIUM_EXECUTABLE_PATH?{executablePath:process.env.CHROMIUM_EXECUTABLE_PATH,args:['--no-sandbox','--disable-dev-shm-usage','--disable-gpu']}: {})});try{
 const page=await browser.newPage({viewport:{width:1440,height:1000}}),errors=[];testPage=page;page.on('pageerror',e=>errors.push(e.message));
 const leads=['John Miller','Sarah Adams','Michael Brown','Emily Carter','David Wilson','Lisa Parker'].map((name,i)=>({id:'lead-'+i,first_name:name.split(' ')[0],last_name:name.split(' ')[1],phone:'248555014'+i,state:'MI',lead_type:'New leads',call_notes:'',agent_status:null}));
 let batch=null,launches=0,saves=0,failSave=false;
 await page.route('**/api/**',async route=>{const b=route.request().postDataJSON(),url=route.request().url();let d={};
 if(url.endsWith('/operations')){d=b.action==='presence'?{mode:'ready',supervisor:false}:b.action==='priority'?{due:0,total:0,tasks:[]}:{saved:true};}
 else if(url.endsWith('/parallel')){
  if(b.action==='options')d={canCall:true,numbers:['+12485550100'],sessions:[]};
  if(b.action==='prepareLeads'){batch={id:b.id,state:'prepared',kind:'leads',legs:b.leadIds.map((leadId,i)=>({id:'leg-'+i,leadId,position:i+1,phone:leads.find(l=>l.id===leadId).phone,state:'queued'}))};d={session:batch,leads:leads.filter(l=>b.leadIds.includes(l.id)),token:'fixture',callGrant:'fixture',deviceKey:'fixture'};}
  if(b.action==='status'){if(batch.state==='prepared')batch.state='ready';d={session:batch,leads:[]};}
  if(b.action==='launch'){launches++;batch.state='dialing';d={session:batch};}
  if(b.action==='stop'){batch.state='complete';batch.legs.forEach(l=>l.state=l.state==='in-progress'?'completed':'no-answer');d={session:batch,leads:[]};}
 }else if(url.endsWith('/account'))d={entitled:true,realCallingAllowed:true,numbers:[{state:'active',slot:1,phoneNumber:'+12485550100'}]};
 else if(b.action==='profile')d={profile:{full_name:'Peter Yelda'},scripts:[{id:'script-1',title:'New lead introduction',lead_type:'New leads',body:'Hi {{First Name}}, this is {{Your Name}}. You asked about life insurance coverage. What would you like to protect?'}]};
 else if(b.action==='folders')d={folders:[{lead_type:'New leads',lead_count:6}]};
 else if(b.action==='leads')d={leads,count:6,states:[{state:'MI',lead_count:6}]};
 else if(b.action==='save'){if(failSave){await route.fulfill({status:409,json:{error:'This lead changed. Your draft is still here.'}});return;}const lead=leads.find(l=>l.id===b.leadId);assert.equal(b.expectedNotes,lead.call_notes);lead.call_notes=b.notes;lead.agent_status=b.status;saves++;d={lead};}
 await route.fulfill({json:d});});
 await page.addInitScript(()=>{
 localStorage.setItem('lld_session',JSON.stringify({user:{id:'fixture-owner'},access_token:'fixture'}));
 window.sessionExpiresWithin=()=>false;window.__timers=[];window.__next=[];
 window.setInterval=(fn,ms)=>{__timers.push({fn,ms});return __timers.length};window.clearInterval=()=>{};
 const original=setTimeout;window.setTimeout=(fn,ms,...args)=>{if(ms===5000){__next.push({fn,canceled:false});return 100000+__next.length;}return original(fn,ms,...args)};
 const clear=clearTimeout;window.clearTimeout=id=>{if(id>100000&&__next[id-100001])__next[id-100001].canceled=true;else clear(id)};
 class E{constructor(){this.listeners={}}on(n,f){(this.listeners[n]??=[]).push(f)}emit(n){for(const f of this.listeners[n]||[])f()}}
 class Call extends E{status(){return this.ended?'closed':'open'}disconnect(){this.ended=true;this.emit('disconnect')}mute(){}}
 window.Twilio={Device:class extends E{updateToken(){}destroy(){}async connect(){return new Call()}}};
 Object.defineProperty(navigator,'mediaDevices',{value:{getUserMedia:async()=>({getTracks:()=>[{stop(){}}]})}});
 });
 await page.goto('http://127.0.0.1:'+server.address().port);
 for(const file of ['dialer-parallel.js','dialer-operations.js','portal-dialer.js'])await page.addScriptTag({url:'/'+file});
 await page.evaluate(()=>window.__instance=createPortalDialer(document.querySelector('#portalDialer')));
 await page.locator('#powerRows tr').first().waitFor({state:'attached'});await page.locator('#powerChooseTitle').click();await page.locator('#powerSelect').click();await page.locator('#powerStart').click();await page.waitForFunction(()=>document.querySelector('#powerConnection').textContent==='Calling');
 assert.equal(launches,1);assert.equal(await page.locator('#powerPause').isVisible(),true);
 batch.state='connected';batch.winnerId=batch.legs[0].id;batch.legs[0].state='in-progress';batch.legs[0].outcome='connected';batch.legs[1].state='no-answer';batch.legs[2].state='busy';
 await page.evaluate(()=>__timers.find(t=>t.ms===1200).fn());await page.locator('#powerName').getByText('John Miller').waitFor();
 await page.locator('#powerNotes').fill('Asked about coverage for his family.');
 await page.locator('#powerScriptTab').click();assert.match(await page.locator('#powerScriptBody').textContent(),/Hi John, this is Peter Yelda/);await page.locator('#powerNotesTab').click();assert.equal(await page.locator('#powerNotes').inputValue(),'Asked about coverage for his family.');
 batch.state='complete';batch.legs[0].state='completed';await page.evaluate(()=>__timers.find(t=>t.ms===1200).fn());
 await page.locator('[data-power-outcome="not_interested"]').waitFor();assert.equal(await page.locator('#powerConnectedDialog').isVisible(),false);
 await page.screenshot({path:'/tmp/vivid-dialer-desktop.png',fullPage:true});
 await page.setViewportSize({width:390,height:844});await page.screenshot({path:'/tmp/vivid-dialer-mobile.png',fullPage:true});
 assert.equal(await page.evaluate(()=>document.documentElement.scrollWidth<=innerWidth),true,'Mobile layout overflows');
 // A failed save must keep the note and pause automatic dialing.
 failSave=true;await page.locator('[data-power-outcome="not_interested"]').click();await page.waitForFunction(()=>document.querySelector('#powerSaveMessage').textContent.includes('changed'));
 assert.equal(launches,1);assert.equal(await page.locator('#powerNotes').inputValue(),'Asked about coverage for his family.');assert.equal(await page.locator('#powerPause').isVisible(),false);
 failSave=false;await page.locator('[data-power-outcome="not_interested"]').click();await page.waitForFunction(()=>document.querySelector('#powerOutcome').value==='');assert.equal(saves,1);assert.equal(launches,1,'Saving must respect pause');
 await page.locator('#powerStart').click();await page.waitForFunction(()=>document.querySelector('#powerConnection').textContent==='Calling');assert.equal(launches,2);
 await page.locator('#powerEndSession').click();await page.waitForFunction(()=>!document.querySelector('#powerContinuous').checked);// Verify an ordinary saved outcome advances automatically to fresh leads.
 await page.reload();for(const file of ['dialer-parallel.js','dialer-operations.js','portal-dialer.js'])await page.addScriptTag({url:'/'+file});
 await page.evaluate(()=>window.__instance=createPortalDialer(document.querySelector('#portalDialer')));
 await page.locator('#powerRows tr').first().waitFor({state:'attached'});await page.locator('#powerChooseTitle').click();await page.locator('#powerSelect').click();await page.locator('#powerStart').click();await page.waitForFunction(()=>document.querySelector('#powerConnection').textContent==='Calling');
 const beforeAuto=launches;batch.state='connected';batch.winnerId=batch.legs[0].id;batch.legs[0].state='in-progress';batch.legs[0].outcome='connected';await page.evaluate(()=>__timers.find(t=>t.ms===1200).fn());
 batch.state='complete';batch.legs[0].state='completed';batch.legs[1].state='no-answer';batch.legs[2].state='busy';await page.evaluate(()=>__timers.find(t=>t.ms===1200).fn());
 await page.locator('[data-power-outcome="not_interested"]').click();await page.waitForFunction(()=>__next.length>0&&!__next.at(-1).canceled);
 await page.evaluate(()=>__next.at(-1).fn());await page.waitForFunction(()=>document.querySelector('#powerConnection').textContent==='Calling');assert.equal(launches,beforeAuto+1,'An outcome must automatically start the next fresh leads');
 await page.locator('#powerEndSession').click();assert.deepEqual(errors,[]);console.log('PASS: browser desktop/mobile layout, inline caller, real script substitutions, draft retention across tabs, continuous Start, failed-save pause, safe retry, automatic continuation after outcome, resume and end session.');
 }catch(e){if(testPage){console.log(await testPage.locator('#powerName').evaluate(el=>{const a=[];for(let p=el;p;p=p.parentElement)a.push({tag:p.tagName,id:p.id,cls:p.className,hidden:p.hidden,display:getComputedStyle(p).display});return a}));await testPage.screenshot({path:'/tmp/vivid-dialer-failure.png',fullPage:true});}throw e;}finally{await browser.close();server.close();}})().catch(e=>{console.error(e);server.close();process.exitCode=1});
