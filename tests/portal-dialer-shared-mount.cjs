'use strict';
const fs=require('node:fs'),assert=require('node:assert/strict'),vm=require('node:vm'),{JSDOM}=require('jsdom');
const dom=new JSDOM('<main id="portalDialerMount"></main>',{url:'https://portal.test',runScripts:'outside-only'}),ctx=dom.getInternalVMContext(),run=s=>vm.runInContext(s,ctx);
run(`const S={session:{},profile:{id:'a',active:true},tab:'power-dialer'};const ONBOARDING={userId:'a',complete:true};let verified=true,portalSessionEpoch=1,creates=0,disposed=0;const portalVerified=()=>verified,q=s=>document.querySelector(s);window.Twilio={Device:function(){}};window.VividCallHealth={};window.createPortalDialer=root=>{creates++;root.innerHTML='<a class="script-link"></a>';return {root,dispose(){disposed++},setVisible(){}};};async function navigatePortalTab(){}`);
const source=fs.readFileSync('portal-app.js','utf8');run(source.slice(source.indexOf('let portalDialerInstance='),source.indexOf('let portalNavigationBusy=')));
(async()=>{try{
 const pair=await run('Promise.all([ensurePortalDialer(),ensurePortalDialer()])');assert.equal(pair[0],pair[1]);assert.equal(run('creates'),1);
 await run('mountPortalDialer()');assert(dom.window.document.querySelector('#portalDialerMount #portalDialer'));
 run("const mini=document.createElement('div');mini.id='mini';document.body.append(mini);mini.append(portalDialerInstance.root)");await run('mountPortalDialer()');assert(dom.window.document.querySelector('#portalDialerMount #portalDialer'));assert.equal(run('creates'),1);assert.equal(run('disposed'),0);
 run('resetPortalDialer();verified=false');await assert.rejects(()=>run('ensurePortalDialer()'),/Sign in/);assert.equal(run('creates'),1);
 run('verified=true;ONBOARDING.complete=false');await assert.rejects(()=>run('ensurePortalDialer()'),/requirements/);
 run('ONBOARDING.complete=true;let release;portalDialerLoad=new Promise(r=>release=r)');const stale=run('ensurePortalDialer()');run("portalSessionEpoch++;S.profile={id:'b',active:true};ONBOARDING.userId='b';release()");await assert.rejects(()=>stale,/session changed/);assert.equal(run('creates'),1);
 await run('ensurePortalDialer()');assert.equal(run('creates'),2);assert.equal(run('portalDialerOwner'),'b');
 console.log('PASS: mini/full dialer share one instance, concurrent creation deduplicates, moving views preserves the session, MFA/onboarding gates hold, and stale account loads are rejected.');
}finally{run('resetPortalDialer()');dom.window.close();}})().catch(e=>{console.error(e);process.exitCode=1;});
