'use strict';
const fs=require('node:fs'),assert=require('node:assert/strict'),{JSDOM}=require('jsdom');
const tick=()=>new Promise(r=>setImmediate(r));
class Events{constructor(){this.events={};}on(name,fn){(this.events[name]??=[]).push(fn);}emit(name,...args){for(const fn of this.events[name]||[])fn(...args);}}
class Call extends Events{constructor(){super();this.parameters={From:'+12025550124'};this.customParameters=new Map([['CallbackId','22222222-2222-4222-8222-222222222222']]);this.state='pending';}accept(){this.state='open';this.emit('accept');}reject(){this.rejected=true;this.emit('reject');}disconnect(){this.state='closed';this.emit('disconnect');}status(){return this.state;}isMuted(){return !!this.muted;}mute(value){this.muted=value;}}
(async()=>{
 const dom=new JSDOM('<body><button id="powerDialerOpen">Power Dialer</button><div id="portalDialer"></div></body>',{url:'https://www.lldportal.com',runScripts:'outside-only'}),w=dom.window;let instance;
 try{
  const session={user:{id:'11111111-1111-4111-8111-111111111111'},access_token:'test'};w.localStorage.setItem('lld_session',JSON.stringify(session));w.S={session,profile:{id:session.user.id},leads:[]};w.portalSessionEpoch=0;w.AbortSignal=AbortSignal;w.confirm=()=>false;w.sessionExpiresWithin=()=>false;
  let stopped=0;Object.defineProperty(w.navigator,'mediaDevices',{value:{getUserMedia:async()=>({getTracks:()=>[{stop:()=>stopped++}]})}});
  const devices=[];class Device extends Events{constructor(token){super();this.token=token;devices.push(this);}async register(){this.emit('registered');}destroy(){this.destroyed=true;this.emit('unregistered');}updateToken(token){this.token=token;this.renewed=true;}}
  w.Twilio={Device};const lead={id:'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',first_name:'Matched',last_name:'Lead',phone:'+12025550124',lead_type:'Folder',state:'MI',email:'matched@example.test',csv_headers:['DOB','Coverage'],csv_values:['1/2/1980','$50,000'],agent_status:null,call_notes:'Prior call note'},callback={id:'22222222-2222-4222-8222-222222222222',caller_phone:lead.phone,dialed_phone:'+12025550123',created_at:new Date().toISOString(),status:'missed',matches:[lead],seen_at:null},requests=[];
  w.api=async()=>1;
  w.fetch=async(url,opt)=>{const b=JSON.parse(opt.body);requests.push({url,...b});let data;
   if(url==='/api/dialer/callbacks'){
    if(b.action==='token')data={token:'incoming-only'};
    else if(b.action==='presence')data={};
    else if(b.action==='list')data={calls:[callback],unread:callback.seen_at?0:1};
    else if(b.action==='seen'){callback.seen_at=new Date().toISOString();data={saved:true};}
   }else if(url.includes('/account'))data={ownerExempt:true,entitled:true,realCallingAllowed:true,numbers:[{state:'active',slot:1,phoneNumber:'+12025550123'}],usedMinutes:0};
   else if(b.action==='profile')data={profile:{full_name:'Agent',division:'vivid_life'},scripts:[]};
   else if(b.action==='folders')data={folders:[{lead_type:'Folder',lead_count:1}]};
   else if(b.action==='leads')data={leads:[{...lead}],count:1,states:[]};
   else if(b.action==='history')data={calls:[]};
   else throw Error('Unexpected API '+url+' '+b.action);
   return {ok:true,json:async()=>data};
  };
  w.eval(fs.readFileSync(__dirname+'/../call-notes.js','utf8'));w.eval(fs.readFileSync(__dirname+'/../dialer-callbacks.js','utf8'));w.eval(fs.readFileSync(__dirname+'/../portal-dialer.js','utf8'));
  const root=w.document.getElementById('portalDialer'),$=id=>root.querySelector('#'+id);instance=w.createPortalDialer(root);await tick();await tick();
  assert(root.querySelector('[data-view="callbacks"]'));assert.equal($('incomingState').textContent,'Voicemail only');assert.equal($('callbackNotice').hidden,false);assert(w.document.querySelector('.callback-count'));
  $('incomingOnline').click();await tick();await tick();assert.equal(stopped,1);assert.equal(devices.length,1);assert.equal($('incomingState').textContent,'Online for callbacks');assert(requests.some(r=>r.action==='presence'&&r.ready&&!r.busy));
  root.querySelector('[data-view="callbacks"]').click();await tick();assert.equal($('callbacks').hidden,false);assert.equal($('workspace').hidden,true);assert(root.textContent.includes('Matched Lead'));
  assert(root.querySelector('.callback-lead-preview').textContent.includes('MI'));
  root.querySelector('.callback-phone-link').click();await tick();await tick();assert.equal($('workspace').hidden,false);assert.equal($('name').textContent,'Matched Lead');assert.equal($('email').textContent,lead.email);assert.equal($('notes').value,'Prior call note');assert($('clientLeadFields').textContent.includes('$50,000'));assert(callback.seen_at);
  root.querySelector('[data-view="callbacks"]').click();await tick();const oldMatches=callback.matches;callback.matches=[];root.querySelector('.callback-lead-link').click();await tick();assert.match($('callbackMessage').textContent,/no longer assigned/);assert.equal($('callbacks').hidden,false);callback.matches=oldMatches;
  callback.matches=[lead,{...lead,id:'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb',first_name:'Second',lead_type:'Different folder'}];$('callbackRefresh').click();await tick();assert.equal(root.querySelectorAll('.callback-lead-choices button').length,2);assert.equal(root.querySelector('.callback-phone-link'),null);callback.matches=[];$('callbackRefresh').click();await tick();assert.match(root.querySelector('.callback-muted').textContent,/No matching lead/);callback.matches=[lead];$('callbackRefresh').click();await tick();
  const incoming=new Call();devices[0].emit('incoming',incoming);await tick();await tick();assert.equal(instance.canLeave(),false);assert.equal($('workspace').hidden,false);assert.equal($('name').textContent,'Matched Lead');assert.equal($('calllead').disabled,true);assert.equal($('incomingCaller').textContent,lead.phone);
  $('incomingAnswer').click();assert.equal(incoming.status(),'open');assert.equal($('incomingHangup').hidden,false);assert.equal($('incomingAnswer').hidden,true);
  const overlapping=new Call();devices[0].emit('incoming',overlapping);assert.equal(overlapping.rejected,true);
  $('incomingMute').click();assert.equal(incoming.muted,true);$('incomingHangup').click();await tick();assert.equal(instance.canLeave(),true);assert.equal($('incomingHangup').closest('.incoming-call').hidden,true);
  devices[0].emit('tokenWillExpire');await tick();assert.equal(devices[0].renewed,true);
  instance.setVisible(false);await tick();const away=new Call();devices[0].emit('incoming',away);assert.equal(away.rejected,true);assert(requests.some(r=>r.action==='presence'&&!r.ready));instance.setVisible(true);await tick();
  const declined=new Call();devices[0].emit('incoming',declined);$('incomingReject').click();await tick();assert(declined.rejected);assert.equal(instance.canLeave(),true);
  $('incomingOffline').click();await tick();assert.equal($('incomingState').textContent,'Voicemail only');
  w.localStorage.setItem('lld_session',JSON.stringify({user:{id:'different-agent'},access_token:'new'}));w.dispatchEvent(new w.StorageEvent('storage',{key:'lld_session'}));assert.equal(root.querySelector('.incoming-call'),null);assert.equal(root.querySelector('[data-view="callbacks"]'),null);
  console.log('PASS: actual portal dialer integration, callback badge/inbox, microphone setup, online registration, matching lead, answer/mute/hangup, simultaneous-call rejection, token renewal, away/offline voicemail and account cleanup.');
 }finally{instance?.dispose();dom.window.close();}
})().catch(e=>{console.error(e);process.exitCode=1;});
