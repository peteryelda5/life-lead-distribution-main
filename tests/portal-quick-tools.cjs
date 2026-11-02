'use strict';
const fs=require('node:fs'),assert=require('node:assert/strict'),vm=require('node:vm');
const {JSDOM}=require('jsdom');
const dom=new JSDOM('<main id="app"></main>',{url:'https://portal.test',runScripts:'outside-only'}),w=dom.window,doc=w.document,ctx=dom.getInternalVMContext(),run=s=>vm.runInContext(s,ctx),flush=()=>new Promise(r=>setImmediate(r));
run(`
 const S={session:{user:{id:'a'}},profile:{id:'a',role:'agent',active:true,division:'vivid_life'},tab:'dashboard'};
 const ONBOARDING={userId:'a',complete:true};let verified=true,calls=[],instanceCount=0,disposed=0,active=false,hold=false,resolveOld,fail=false;
 const portalVerified=()=>verified,adminDivisionList=()=>['vivid_life','legacy_life'],divisionLabel=d=>d==='vivid_life'?'Vivid Life':'Legacy Life';
 let portalDialerInstance=null;
 let apiPage=async url=>{calls.push({url});return {data:[{id:'script-a',title:'Opening <img src=x onerror=alert(1)>'}],count:1};};
 let api=async(url,options={})=>{calls.push({url,options});if(hold&&url.includes('id=eq.script-a')){hold=false;await new Promise(r=>resolveOld=r);}if(fail)throw Error('Network unavailable');if(options.method)return [{id:'sheet-a',...options.body}];if(url.includes('id=eq.script-a'))return [{title:'Opening',body:'Hello <script>bad()</script>\\nAgency call script.'}];return [];};
 async function ensurePortalDialer(){if(!portalDialerInstance){instanceCount++;const root=document.createElement('div');root.id='portalDialer';root.innerHTML='<input id="manual-destination"><button id="manual-hangup">Hang up</button>';root.querySelector('button').onclick=()=>active=false;portalDialerInstance={root,showQuickDialer:()=>true,quickCallActive:()=>active,setVisible(){},dispose(){disposed++;}};}return portalDialerInstance;}
 async function navigatePortalTab(tab){S.tab=tab;document.querySelector('#app').innerHTML='<section id="portalDialerMount"></section>';if(tab==='power-dialer'){const instance=await ensurePortalDialer();document.querySelector('#portalDialerMount').append(instance.root);}window.PortalQuickTools.sync();}
`);
run(fs.readFileSync('portal-quick-tools.js','utf8'));
(async()=>{try{
 run('window.PortalQuickTools.sync()');assert(doc.querySelector('#qtLauncher'));assert(doc.querySelector('#qtPanel').hidden);assert.equal(run('calls.length'),0,'Collapsed tools must not preload scripts or calling services.');
 doc.querySelector('#qtLauncher').click();await flush();await flush();
 assert.equal(doc.querySelectorAll('[role=tab]').length,3);assert(!doc.querySelector('#qtPanel').hidden);assert(doc.querySelector('#qtScriptBody').textContent.includes('<script>'));assert(!doc.querySelector('#qtScriptBody script'));assert(!doc.querySelector('#qtScript img'));
 assert(run("calls.every(c=>new URL(c.url,'https://portal.test').searchParams.get('division')==='eq.vivid_life')"));
 doc.querySelector('#qtTab-process').click();assert(doc.querySelector('#qtEditSheet').hidden);assert(doc.querySelector('#qtSheetStatus').textContent.includes('once your admin adds it'));
 doc.querySelector('#qtTab-dialer').click();await flush();assert.equal(run('instanceCount'),1);
 doc.querySelector('#manual-destination').value='2485550100';run('active=true');doc.querySelector('#qtMinimize').click();assert.equal(run('disposed'),0);assert(run('active'));assert.equal(doc.querySelector('#manual-destination').value,'2485550100');
 run("document.querySelector('#app').innerHTML='<h1>My leads</h1>';window.PortalQuickTools.sync()");assert(doc.querySelector('#manual-hangup'),'An ordinary portal render keeps the mini dialer mounted.');
 doc.querySelector('#qtLauncher').click();await flush();assert.equal(run('instanceCount'),1);assert.equal(doc.querySelector('#manual-destination').value,'2485550100');
 doc.querySelector('#qtTab-scripts').click();assert(run('active'),'Reading scripts must not end a call.');doc.querySelector('#qtTab-dialer').click();await flush();doc.querySelector('#manual-hangup').click();assert(!run('active'));
 await doc.querySelector('#qtFullDialer').onclick();assert.equal(run('S.tab'),'power-dialer');assert(doc.querySelector('#portalDialerMount #portalDialer'));assert.equal(run('instanceCount'),1);
 run("S.tab='dashboard';window.PortalQuickTools.sync()");doc.querySelector('#qtLauncher').click();await flush();assert(doc.querySelector('#qtDialerMount #portalDialer'));assert.equal(run('instanceCount'),1);
 // Keyboard tab navigation and minimize restore focus without trapping the page.
 doc.querySelector('#qtTab-dialer').dispatchEvent(new w.KeyboardEvent('keydown',{key:'ArrowRight',bubbles:true}));assert.equal(doc.activeElement.id,'qtTab-process');doc.activeElement.dispatchEvent(new w.KeyboardEvent('keydown',{key:'Escape',bubbles:true}));assert(doc.querySelector('#qtPanel').hidden);assert.equal(doc.activeElement.id,'qtLauncher');
 // A delayed read from a previous account must not populate a new account’s panel.
 run('hold=true');doc.querySelector('#qtLauncher').click();doc.querySelector('#qtTab-scripts').click();const pending=doc.querySelector('#qtRefreshScripts').onclick();await flush();
 run("S.profile={id:'b',role:'admin',active:true,division:'legacy_life'};S.session={user:{id:'b'}};ONBOARDING.userId='b';window.PortalQuickTools.sync()");run('resolveOld()');await pending;await flush();assert.equal(doc.querySelector('#qtScriptBody').textContent,'');
 doc.querySelector('#qtLauncher').click();await flush();await flush();doc.querySelector('#qtTab-process').click();assert(!doc.querySelector('#qtEditSheet').hidden);doc.querySelector('#qtEditSheet').click();doc.querySelector('#qtSheetDraft').value='Our agency sales process\nObjection response';
 await doc.querySelector('#qtSheetForm').onsubmit({preventDefault(){}});assert.equal(doc.querySelector('#qtSheetBody').textContent,'Our agency sales process\nObjection response');
 assert.equal(run("calls.filter(c=>c.options?.method).at(-1).options.body.division"),'legacy_life');assert.equal(run("calls.filter(c=>c.options?.method).at(-1).options.body.lead_type"),'Sales Process / Objection Sheet');
 // Failed saves retain the draft for retry.
 doc.querySelector('#qtEditSheet').click();doc.querySelector('#qtSheetDraft').value='Retain this draft';run('fail=true');await doc.querySelector('#qtSheetForm').onsubmit({preventDefault(){}});assert.equal(doc.querySelector('#qtSheetDraft').value,'Retain this draft');assert(doc.querySelector('#qtSheetError').textContent.includes('Network'));assert(!doc.querySelector('#qtSheetSave').disabled);
 run('verified=false;window.PortalQuickTools.sync()');assert(!doc.querySelector('#portalQuickTools'));
 run('verified=true;ONBOARDING.complete=false;window.PortalQuickTools.sync()');assert(!doc.querySelector('#portalQuickTools'));
 run('ONBOARDING.complete=true;S.profile.active=false;window.PortalQuickTools.sync()');assert(!doc.querySelector('#portalQuickTools'));
 run('S.profile.active=true;S.session=null;window.PortalQuickTools.sync()');assert(!doc.querySelector('#portalQuickTools'));
 console.log('PASS: exactly three tools, minimized lazy loading, scoped and escaped scripts, admin sheet editing, retry preservation, shared dialer and call continuity, keyboard controls, stale account rejection and access gates.');
}finally{run('window.PortalQuickTools.reset()');dom.window.close();}})().catch(e=>{console.error(e);process.exitCode=1;});
