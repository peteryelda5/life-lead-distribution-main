'use strict';
const assert=require('node:assert/strict'),fs=require('node:fs'),path=require('node:path'),vm=require('node:vm');
const {JSDOM}=require('jsdom');
const root=path.resolve(__dirname,'..'),app=fs.readFileSync(path.join(root,'portal-app.js'),'utf8'),ui=fs.readFileSync(path.join(root,'portal-verification.js'),'utf8');
const get=name=>{const start=app.indexOf('function '+name+'('),end=app.indexOf('\n',start);return app.slice(start,end);};
const formHtml=vm.runInNewContext(get('mfaCodeForm')+'\nmfaCodeForm("mfaChallengeForm","Verify code")',{esc:String});
const tick=()=>new Promise(resolve=>setImmediate(resolve));
function deferred(){let resolve,reject;const promise=new Promise((a,b)=>{resolve=a;reject=b;});return {promise,resolve,reject};}
function fixture(verify,{passkey,retry=async()=>{},reduced=true,isCurrent=()=>true}={}){
 const dom=new JSDOM('<div id="app"><section class="pv-card"><h1 class="pv-title">2-step verification</h1><p class="pv-subtitle">Enter your code</p>'+(passkey?'<button id="usePortalPasskey">Use Face ID</button>':'')+formHtml+'</section></div>',{runScripts:'outside-only',url:'https://portal.test/'}),w=dom.window,d=w.document;
 w.matchMedia=()=>({matches:reduced});if(passkey)d.querySelector('#usePortalPasskey').onclick=passkey;
 w.eval(ui);const form=d.querySelector('form');w.PortalVerification.bind(form,{verify,retry,isCurrent});
 const inputs=[...d.querySelectorAll('[data-code-digit]')];
 return {dom,w,d,form,inputs,input(i,text){inputs[i].value=text;inputs[i].dispatchEvent(new w.Event('input',{bubbles:true}));},key(i,key){inputs[i].dispatchEvent(new w.KeyboardEvent('keydown',{key,bubbles:true,cancelable:true}));},paste(text,i=0){const event=new w.Event('paste',{bubbles:true,cancelable:true});Object.defineProperty(event,'clipboardData',{value:{getData:()=>text}});inputs[i].dispatchEvent(event);},close(){dom.window.close();}};
}
async function uiTests(){
 let calls=0,received,accept;const pending=deferred();let f=fixture(async(code,onVerified)=>{calls++;received=code;await pending.promise;await onVerified();accept=true;});
 try{
  assert.equal(f.d.activeElement,f.inputs[0]);f.input(0,'a');assert.equal(f.inputs[0].value,'');assert.equal(calls,0);
  f.input(0,'0');assert.equal(f.d.activeElement,f.inputs[1]);f.key(1,'Backspace');assert.equal(f.inputs[0].value,'');assert.equal(f.d.activeElement,f.inputs[0]);
  f.key(0,'End');assert.equal(f.d.activeElement,f.inputs[5]);f.key(5,'Home');assert.equal(f.d.activeElement,f.inputs[0]);
  f.paste('012 345',2);assert.equal(calls,1);assert.equal(received,'012345');assert.equal(f.form.dataset.state,'checking');assert(f.d.querySelector('.pv-success').hidden);assert(f.inputs.every(x=>x.disabled));
  f.form.dispatchEvent(new f.w.Event('submit',{cancelable:true}));f.input(5,'5');assert.equal(calls,1,'Pending request cannot be duplicated');
  pending.resolve();await tick();assert.equal(accept,true);assert.equal(f.form.dataset.state,'success');assert(!f.d.querySelector('.pv-success').hidden);assert(f.inputs.every(x=>x.value===''));assert(f.d.querySelector('.pv-entry').hidden);
 }finally{f.close();}
 calls=0;f=fixture(async(code,onVerified)=>{calls++;if(calls===1)throw Error('Code expired. Try again.');await onVerified();});
 try{
  for(let i=0;i<6;i++)f.input(i,String(i));await tick();assert.equal(f.form.dataset.state,'error');assert.match(f.d.querySelector('.pv-status').textContent,/expired/);assert(f.inputs.every(x=>x.value===''&&!x.disabled&&x.getAttribute('aria-invalid')==='true'));assert.equal(f.d.activeElement,f.inputs[0]);assert(f.d.querySelector('.pv-success').hidden);
  f.input(0,'012345');await tick();assert.equal(calls,2,'Full-code autofill retries automatically');assert.equal(f.form.dataset.state,'success');
 }finally{f.close();}
 let retries=0;calls=0;f=fixture(async(code,onVerified)=>{calls++;await onVerified();throw Error('Offline');},{retry:async()=>{retries++;if(retries===1)throw Error('Offline');}});
 try{
  f.paste('012345');await tick();assert.equal(f.form.dataset.state,'load-error');assert(!f.d.querySelector('.pv-success').hidden);const retry=f.d.querySelector('.pv-retry');assert(!retry.hidden&&!retry.disabled);
  retry.click();await tick();assert(!retry.disabled);retry.click();await tick();assert.equal(retries,2);assert.equal(calls,1,'Workspace retry must not reuse an OTP');
 }finally{f.close();}
 const keyDone=deferred();let keys=0;calls=0;f=fixture(async()=>{calls++;},{passkey:async()=>{keys++;await keyDone.promise;}});
 try{const key=f.d.querySelector('#usePortalPasskey');key.click();assert.equal(keys,1);assert(f.inputs.every(x=>x.disabled));f.paste('012345');assert.equal(calls,0);keyDone.resolve();await tick();assert(f.inputs.every(x=>!x.disabled));assert(!key.disabled);f.paste('012345');assert.equal(calls,1);assert(key.disabled);}finally{f.close();}
 const stale=deferred();f=fixture(async(code,onVerified)=>{await stale.promise;await onVerified();});
 try{f.paste('012345');f.d.getElementById('app').textContent='Signed out';await tick();stale.resolve();await tick();assert.equal(f.d.getElementById('app').textContent,'Signed out');assert(f.inputs.every(x=>x.value===''));}finally{f.close();}
 let complete=false;f=fixture(async(code,onVerified)=>{await onVerified();complete=true;},{reduced:false});
 try{f.paste('012345');assert.equal(f.form.dataset.state,'success');assert.equal(complete,false,'Success animation finishes before continuing');await new Promise(resolve=>setTimeout(resolve,850));assert(complete);}finally{f.close();}
 console.log('PASS verification UI: typing, paste/autofill, keyboard, duplicate prevention, error recovery, success, reduced motion, workspace retry, Face ID interlock and teardown');
}
function providerFixture(){
 const log=[],session={access_token:'fixture',refresh_token:'fixture',user:{id:'agent'},aal:'aal1'},S={profile:{id:'agent'},session,mfaMode:'challenge',mfaFactor:{id:'factor'},mfaEnroll:{id:'enrollment'},err:'old error'};
 const context={S,portalSessionEpoch:0,log,Error,String,SB:{auth:{setSession:async()=>({data:{session}}),getSession:async()=>({data:{session:S.session}}),mfa:{challenge:async args=>{log.push(['challenge',args]);return {data:{id:'challenge'}};},verify:async args=>{log.push(['verify',args]);return {data:{...session,aal:'aal2'}};}}}},saveSession:value=>{S.session=value;log.push('adopt');},currentAal:()=>S.session?.aal||'aal1',loadCore:async()=>log.push('load'),render:()=>log.push('render')};
 vm.createContext(context);vm.runInContext('async '+get('syncSbSession')+'\nasync '+get('adoptSbSession')+'\n'+app.slice(app.indexOf('async function verifyMfaCode('),app.indexOf('\nfunction tokenExpiry(')),context);return context;
}
async function providerTests(){
 let c=providerFixture();await assert.rejects(c.verifyMfaCode('short'),/6-digit/);assert.equal(c.log.length,0);
 c=providerFixture();await c.verifyMfaCode('012345',false,{onVerified:async()=>{assert.equal(c.S.session.aal,'aal2');c.log.push('success');}});assert.deepEqual(JSON.parse(JSON.stringify(c.log.filter(Array.isArray))),[['challenge',{factorId:'factor'}],['verify',{factorId:'factor',challengeId:'challenge',code:'012345'}]]);assert(c.log.indexOf('success')<c.log.indexOf('load'));assert.equal(c.S.mfaMode,null);assert.equal(c.S.err,'');
 c=providerFixture();await c.verifyMfaCode('012345',true);assert.equal(c.log.find(Array.isArray)[1].factorId,'enrollment');
 for(const failure of ['challenge','verify']){c=providerFixture();c.SB.auth.mfa[failure]=async()=>({error:Error('Rejected by provider')});await assert.rejects(c.verifyMfaCode('012345',false,{onVerified:()=>{throw Error('False success');}}),/Rejected by provider/);assert(!c.log.includes('load'));assert.equal(c.S.mfaMode,'challenge');}
 c=providerFixture();c.SB.auth.mfa.verify=async()=>({data:{...c.S.session}});await assert.rejects(c.verifyMfaCode('012345',false,{onVerified:()=>{throw Error('False success');}}),/did not complete/);assert(!c.log.includes('load'));
 for(const stage of ['sync','verify','adopt']){
  c=providerFixture();const pending=deferred();if(stage==='sync')c.SB.auth.setSession=()=>pending.promise;if(stage==='verify')c.SB.auth.mfa.verify=()=>pending.promise;if(stage==='adopt'){c.SB.auth.mfa.verify=async()=>({data:{}});c.SB.auth.getSession=()=>pending.promise;}
  const task=c.verifyMfaCode('012345');await tick();c.portalSessionEpoch++;c.S.profile={id:'other'};c.S.session={user:{id:'other'},aal:'aal1'};pending.resolve({data:{session:{access_token:'old',refresh_token:'old',user:{id:'agent'},aal:'aal2'}}});await assert.rejects(task,/session changed/);assert.equal(c.S.session.user.id,'other');assert(!c.log.includes('load'));
 }
 console.log('PASS MFA provider integration: real challenge/verify contract, enrolled factor, AAL2 requirement, provider rejection and stale-session protection');
}
async function viewTests(){
 const dom=new JSDOM('<div id="app"></div>',{runScripts:'outside-only',url:'https://portal.test/'}),w=dom.window,d=w.document;const calls=[];
 w.matchMedia=()=>({matches:true});w.verifyMfaCode=async(code,enrolling,{onVerified}={})=>{calls.push({code,enrolling});await onVerified?.();};w.logout=()=>calls.push('logout');
 try{
  w.eval(ui);w.eval(`var app=document.getElementById('app'),q=s=>document.querySelector(s),esc=v=>String(v??''),S={profile:{id:'agent'},session:{},mfaEnroll:{id:'enrollment',totp:{}}};var portalSessionEpoch=0;function alertHtml(){return '';}function loadCore(){}function render(){}`);
  w.eval(app.slice(app.indexOf('function mfaVerificationHeading('),app.indexOf('\nfunction setupView(')));
  for(const enrolling of [false,true]){w.eval(enrolling?'mfaEnrollView()':'mfaChallengeView()');assert.equal(d.querySelectorAll('[data-code-digit]').length,6);assert(d.querySelector('.pv-title').textContent.includes('2-step verification'));const first=d.querySelector('[data-code-digit]');first.value='012345';first.dispatchEvent(new w.Event('input'));await tick();assert.equal(calls.at(-1).enrolling,enrolling);assert(!d.querySelector('.pv-success').hidden);}
  w.PortalVerification=undefined;w.eval('mfaChallengeView()');[...d.querySelectorAll('[data-code-digit]')].forEach((input,i)=>input.value=String(i));d.querySelector('form').dispatchEvent(new w.Event('submit',{cancelable:true}));await tick();assert.equal(calls.at(-1).code,'012345');assert.equal(calls.at(-1).enrolling,false);d.querySelector('#out').click();assert.equal(calls.at(-1),'logout');
 }finally{w.close();}
 console.log('PASS real MFA challenge/enrollment views bind the entry controller, preserve sign-out and support script-load fallback');
}
(async()=>{await uiTests();await providerTests();await viewTests();})().catch(error=>{console.error(error);process.exitCode=1;});
