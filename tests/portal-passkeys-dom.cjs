'use strict';
const assert=require('node:assert/strict'),fs=require('fs'),{JSDOM}=require('jsdom');
const source=fs.readFileSync(__dirname+'/../portal-passkeys.js','utf8');
const tick=async()=>{for(let i=0;i<15;i++)await new Promise(r=>setImmediate(r));};
function setup(){
 const dom=new JSDOM('<body><div id="app"></div></body>',{url:'https://www.lldportal.com',runScripts:'outside-only'}),w=dom.window;
 let owner='owner',session='one',proof=false,registered=true,loaded=0,rendered=0,ceremonies=0,error='',cancel=false,defer;
 const actions=[];
 Object.defineProperty(w,'isSecureContext',{value:true});Object.defineProperty(w.navigator,'userAgent',{value:'iPhone'});w.PublicKeyCredential=function(){};Object.defineProperty(w.navigator,'credentials',{value:{}});
 w.S={session:{access_token:'fixture'},profile:{id:'owner'},mfaMode:'challenge'};w.jwtPayload=()=>({sub:owner,session_id:session});w.sessionExpiresWithin=()=>false;w.currentAal=()=> 'aal1';w.refreshToken=async()=>true;
 w.loadCore=async()=>{loaded++;};w.render=()=>{rendered++;};w.flash=t=>{error=t;};w.confirm=()=>true;
 w.SimpleWebAuthnBrowser={async startRegistration(){ceremonies++;return {id:'credential'};},async startAuthentication(){ceremonies++;if(cancel)throw Object.assign(Error('cancel'),{name:'NotAllowedError'});if(defer)await defer;return {id:'credential'};}};
 const status=()=>({verified:proof,expires_at:proof?new Date(Date.now()+60000).toISOString():null,credentials:registered?[{id:'credential',name:'My iPhone',created_at:new Date().toISOString()}]:[]});
 w.fetch=async(url,opt)=>{const b=JSON.parse(opt.body);actions.push(b);let result;
  if(b.action.endsWith('_options'))result={id:'challenge',options:{userVerification:'required'}};
  else{if(b.action==='authenticate_verify')proof=true;if(b.action==='register_verify')registered=true;if(b.action==='remove'){registered=false;proof=false;}result=status();}return {ok:true,json:async()=>result};};
 w.eval(source);
 return {w,actions,get loaded(){return loaded;},get ceremonies(){return ceremonies;},get error(){return error;},cancel(){cancel=true;},swap(){owner='other';session='two';},defer(p){defer=p;},close(){w.close();}};
}
(async()=>{
 const h=setup();try{
  assert.equal(await h.w.PortalPasskeys.check(),false);assert.match(h.w.PortalPasskeys.challengeHtml(),/Use Face ID/);assert.equal(h.ceremonies,0);
  h.w.document.getElementById('app').innerHTML=h.w.PortalPasskeys.challengeHtml();h.w.PortalPasskeys.bindChallenge();h.w.document.getElementById('usePortalPasskey').click();await tick();
  assert.equal(h.w.PortalPasskeys.verified(),true);assert.equal(h.loaded,1);assert.equal(h.w.S.mfaMode,null);
  h.swap();assert.equal(h.w.PortalPasskeys.verified(),false);assert.equal(h.w.PortalPasskeys.challengeHtml(),'');
 }finally{h.close();}
 const cancelled=setup();try{await cancelled.w.PortalPasskeys.check();cancelled.cancel();await cancelled.w.PortalPasskeys.verify();assert.equal(cancelled.loaded,0);assert.match(cancelled.error,/cancelled/);assert(!cancelled.actions.some(a=>a.action==='authenticate_verify'));}finally{cancelled.close();}
 const race=setup();try{await race.w.PortalPasskeys.check();let release;race.defer(new Promise(r=>release=r));const pending=race.w.PortalPasskeys.verify();await tick();race.swap();release();await pending;assert.equal(race.loaded,0);assert(!race.actions.some(a=>a.action==='authenticate_verify'));assert.match(race.error,/Account changed/);}finally{race.close();}
 const ui=setup();try{await ui.w.PortalPasskeys.open();assert.match(ui.w.document.body.textContent,/password is still used/);assert.match(ui.w.document.body.textContent,/authenticator app as a backup/);assert.equal(ui.ceremonies,0);ui.w.PortalPasskeys.reset();assert.equal(ui.w.document.querySelector('[role=dialog]'),null);assert.equal(ui.w.PortalPasskeys.verified(),false);}finally{ui.close();}
 console.log('PASS: explicit Face ID gesture, fallback after cancellation, session/account binding, no access on failure, account-change race, clear password/backup guidance and logout cleanup.');
})().catch(e=>{console.error(e);process.exitCode=1;});
