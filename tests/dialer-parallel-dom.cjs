'use strict';
const fs=require('node:fs'),assert=require('node:assert/strict'),{JSDOM}=require('jsdom');
const tick=()=>new Promise(r=>setImmediate(r));
class Events{constructor(){this.events={};}on(name,fn){(this.events[name]??=[]).push(fn);}emit(name,...args){for(const fn of this.events[name]||[])fn(...args);}}
class Call extends Events{status(){return 'open';}disconnect(){this.emit('disconnect');}mute(value){this.muted=value;}}
(async()=>{const dom=new JSDOM('<body><div id="root"></div></body>',{url:'https://www.lldportal.com',runScripts:'outside-only'}),w=dom.window;let instance;try{
 const owner='5893f335-aad3-4079-ad95-77eaf1347ac6',session={user:{id:owner},access_token:'test'};w.localStorage.setItem('lld_session',JSON.stringify(session));w.AbortSignal=AbortSignal;w.confirm=()=>false;w.sessionExpiresWithin=()=>false;w.S={session,profile:{id:owner}};w.portalSessionEpoch=0;
 const timers=[];w.setInterval=(fn,ms)=>{timers.push({fn,ms});return timers.length;};w.clearInterval=()=>{};Object.defineProperty(w.navigator,'mediaDevices',{value:{getUserMedia:async()=>({getTracks:()=>[{stop(){}}]})}});
 let state=null,activeCall,starts=0;const requests=[];
 class Device extends Events{constructor(){super();}async connect(){state.state='ready';return activeCall=new Call();}destroy(){}}
 w.Twilio={Device};w.fetch=async(url,opt)=>{const b=JSON.parse(opt.body);requests.push({url,...b});let data;
 if(url==='/api/dialer/parallel'){
  if(b.action==='access')data={allowed:true,atCost:true};
  if(b.action==='options')data={numbers:['+12025550123'],sessions:[],budget:{reservedCents:0}};
  if(b.action==='prepare'){state={id:b.id,state:'prepared',callerId:b.callerId,legs:b.phones.map((phone,i)=>({id:String(i),position:i+1,phone,state:'queued'}))};data={session:{...state},token:'test',callGrant:'signed',budget:{reservedCents:50}};}
  if(b.action==='status')data={session:{...state},budget:{reservedCents:50}};
  if(b.action==='launch'){starts++;state.state='dialing';data={session:{...state}};}
  if(b.action==='stop'){state.state='complete';state.estimatedUsd=.085;data={session:{...state},budget:{reservedCents:50}};}
 }else if(url.includes('/account'))data={ownerExempt:true,entitled:true,realCallingAllowed:true,numbers:[{state:'active',slot:1,phoneNumber:'+12025550123'}]};
 else if(b.action==='profile')data={profile:{full_name:'Owner',division:'vivid_life'},scripts:[]};
 else if(b.action==='folders')data={folders:[]};else if(b.action==='leads')data={leads:[],count:0,states:[]};
 else throw Error('Unexpected API '+url+' '+b.action);return {ok:true,json:async()=>data};};
 w.eval(fs.readFileSync(__dirname+'/../dialer-parallel.js','utf8'));w.eval(fs.readFileSync(__dirname+'/../portal-dialer.js','utf8'));const root=w.document.querySelector('#root'),$=id=>root.querySelector('#'+id);instance=w.createPortalDialer(root);await tick();await tick();
 assert.equal(root.querySelector('[data-view="parallel"]').hidden,false);assert.match($('parallelBilling').textContent,/\$0 monthly subscription/);root.querySelector('[data-view="parallel"]').click();await tick();assert.equal($('parallel').hidden,false);assert.equal($('workspace').hidden,true);
 $('parallelStart').click();await tick();assert.equal(starts,0);assert.match($('parallelMessage').textContent,/Confirm/);
 $('parallelConsent').checked=$('parallelCharges').checked=true;root.querySelectorAll('#parallelPhones input').forEach((el,i)=>el.value='+1202555012'+(i+4));$('parallelStart').click();await tick();await tick();await tick();assert.equal(starts,1);assert.equal(requests.find(x=>x.action==='prepare').phones.length,3);assert.equal(instance.canLeave(),false);
 root.querySelector('[data-view="manual"]').click();assert.equal($('parallel').hidden,false,'Busy pilot navigation unlocked');$('parallelMute').click();assert.equal(activeCall.muted,true);
 state.state='connected';state.winnerId='1';state.legs[1].outcome='connected';await timers.find(t=>t.ms===2500).fn();assert(root.querySelector('.parallel-line.connected'));assert.match($('parallelMessage').textContent,/Human detected/);
 $('parallelStop').click();await tick();await tick();assert.equal(instance.canLeave(),true);assert.match($('parallelEstimate').textContent,/0.085/);assert.equal(starts,1,'Stopping automatically started another batch');
 w.localStorage.setItem('lld_session',JSON.stringify({user:{id:'other'},access_token:'other'}));w.dispatchEvent(new w.StorageEvent('storage',{key:'lld_session'}));assert.equal(root.querySelector('#parallel'),null);assert.equal(root.querySelector('[data-view="parallel"]'),null);
 console.log('PASS: $0 account actual dialer pilot tab, consent gate, three test phones, microphone/headset launch, busy/manual/navigation locks, live winner, mute/stop, cost display, no auto-repeat, cross-account cleanup.');
 }finally{instance?.dispose();dom.window.close();}})().catch(e=>{console.error(e);process.exitCode=1;});
