'use strict';
const fs=require('node:fs'),assert=require('node:assert/strict'),{JSDOM}=require('jsdom');
const tick=()=>new Promise(r=>setImmediate(r));const flush=async()=>{for(let i=0;i<8;i++)await tick();};
class Events{constructor(){this.events={};}on(n,f){(this.events[n]??=[]).push(f);}emit(n,...a){for(const f of this.events[n]||[])f(...a);}}
class Call extends Events{status(){return 'open';}disconnect(){this.emit('disconnect');}mute(v){this.muted=v;}}
(async()=>{
 const dom=new JSDOM('<body><div id="root"></div></body>',{url:'https://www.lldportal.com',runScripts:'outside-only'}),w=dom.window;let instance;
 try{
 const owner='77777777-7777-4777-8777-777777777777',session={user:{id:owner},access_token:'test'};w.localStorage.setItem('lld_session',JSON.stringify(session));w.AbortSignal=AbortSignal;w.confirm=()=>false;w.sessionExpiresWithin=()=>false;w.S={session,profile:{id:owner}};w.portalSessionEpoch=0;
 let dialogOpens=0;w.HTMLDialogElement.prototype.showModal=function(){this.open=true;dialogOpens++;};w.HTMLDialogElement.prototype.close=function(){this.open=false;this.dispatchEvent(new w.Event('close'));};
 const timers=[];w.setInterval=(fn,ms)=>{timers.push({fn,ms});return timers.length;};w.clearInterval=()=>{};
 let microphoneError=false,stopError=false,access=true;Object.defineProperty(w.navigator,'mediaDevices',{value:{getUserMedia:async()=>{if(microphoneError)throw Object.assign(Error('Denied'),{name:'NotAllowedError'});return{getTracks:()=>[{stop(){}}]};}}});
 const leads=[1,2,3,4].map(n=>({id:'11111111-1111-4111-8111-'+String(n).padStart(12,'0'),first_name:n===1?'<img src=x onerror=alert(1)>':'Lead '+n,last_name:'Fixture',phone:n===4?'911':'+1202555019'+n,state:n===2?'OH':'MI',lead_type:'Folder A',agent_status:null,call_notes:'Original notes',csv_headers:['Age'],csv_values:['61']}));
 let state=null,activeCall,starts=0,prepareGate=null;const requests=[];
 class Device extends Events{async connect(){state.state='ready';return activeCall=new Call();}destroy(){}}
 w.Twilio={Device};w.fetch=async(url,opt)=>{const b=JSON.parse(opt.body);requests.push({url,...b});let data;
 if(url==='/api/dialer/parallel'){
  if(b.action==='options')data={canCall:access,numbers:access?['+12025550198']:[],sessions:state?[{id:state.id,state:state.state,kind:'leads',created_at:new Date().toISOString()}]:[]};
  else if(b.action==='prepareLeads'){if(prepareGate)await prepareGate;state={id:b.id,kind:'leads',connectMode:b.connectMode,state:'prepared',callerId:b.callerId,legs:b.leadIds.map((leadId,i)=>({id:'leg'+i,leadId,position:i+1,phone:leads.find(l=>l.id===leadId).phone,state:'queued'}))};data={session:structuredClone(state),leads:leads.filter(l=>b.leadIds.includes(l.id)),token:'test',callGrant:'signed'};}
  else if(b.action==='status')data={session:structuredClone(state),leads:b.details?leads:[]};
  else if(b.action==='launch'){starts++;state.state='dialing';data={session:structuredClone(state)};}
  else if(b.action==='stop'){if(stopError)return{ok:false,status:503,json:async()=>({error:'Temporary provider timeout'})};state.state='complete';data={session:structuredClone(state)};}
  else throw Error('Unexpected parallel '+b.action);
 }else if(url.includes('/account'))data={ownerExempt:false,entitled:true,realCallingAllowed:true,numbers:[{state:'active',slot:1,phoneNumber:'+12025550198'}]};
 else if(b.action==='profile')data={profile:{full_name:'Paid agent',division:'vivid_life'},scripts:[]};
 else if(b.action==='folders')data={folders:[{lead_type:'Folder A',lead_count:4}]};
 else if(b.action==='leads')data={leads:b.states?.length?leads.filter(l=>b.states.includes(l.state)):leads,count:4,states:[{state:'MI',lead_count:3},{state:'OH',lead_count:1}]};
 else if(b.action==='save'){const l=leads.find(l=>l.id===b.leadId);assert.equal(b.expectedNotes,l.call_notes);assert.equal(b.expectedStatus,l.agent_status);l.call_notes=b.notes;l.agent_status=b.status;data={lead:{...l}};}
 else throw Error('Unexpected API '+url+' '+b.action);
 return {ok:true,status:200,json:async()=>data};};
 w.eval(fs.readFileSync(__dirname+'/../dialer-parallel.js','utf8'));w.eval(fs.readFileSync(__dirname+'/../portal-dialer.js','utf8'));
 const root=w.document.querySelector('#root'),$=id=>root.querySelector('#'+id);instance=w.createPortalDialer(root);await flush();
 assert.equal(root.querySelector('[data-view="parallel"]').textContent,'Power Dialer');root.querySelector('[data-view="parallel"]').click();await flush();
 assert.equal($('parallel').hidden,false);assert.equal($('powerMode').value,'human','Voicemail detection must be the default');assert.equal($('powerSetup').hidden,true);assert.equal($('powerRows').querySelectorAll('input').length,4);assert.equal($('powerRows').querySelectorAll('input')[3].disabled,true);assert.equal(root.querySelector('img[src=x]'),null,'Lead data became HTML');
 $('powerRows').querySelector('button').click();assert.equal($('powerConnectedDialog').open,true);assert.equal($('powerConnectedTitle').textContent,'Lead information');assert.equal(root.querySelector('img[src=x]'),null);$('powerDialogMinimize').click();dialogOpens=0;
 $('powerFolder').value='1';$('powerFolder').dispatchEvent(new w.Event('change'));await flush();assert.equal(requests.filter(r=>r.action==='leads').at(-1).folder,'Folder A');
 $('powerStateChoices').querySelector('input').checked=true;$('powerApplyStates').click();await flush();assert.deepEqual(requests.filter(r=>r.action==='leads').at(-1).states,['MI']);
 $('powerReload').click();await flush();$('powerSelect').click();assert.match($('powerCount').textContent,/3 selected/);assert.equal($('powerStart').disabled,false);
 microphoneError=true;$('powerStart').click();await flush();assert.equal(starts,0);assert.match($('powerMessage').textContent,/Allow microphone access/);assert.equal(instance.canLeave(),true);microphoneError=false;
 // A slow preparation request must not race polling or cancellation against a missing batch.
 let finishPrepare;prepareGate=new Promise(resolve=>{finishPrepare=resolve;});$('powerStart').click();await flush();const statuses=requests.filter(r=>r.action==='status').length;await timers.find(t=>t.ms===1200).fn();await flush();assert.equal(requests.filter(r=>r.action==='status').length,statuses,'Polling ran before the batch existed');
 $('powerStop').click();await flush();assert.match($('powerMessage').textContent,/Canceling call setup/);assert.equal(requests.filter(r=>r.action==='stop').length,0,'Cancellation raced unfinished preparation');finishPrepare();prepareGate=null;await flush();assert.equal(state.state,'complete');assert.equal(starts,0);assert.equal(instance.canLeave(),true);assert.equal($('powerStart').disabled,false);
 $('powerStart').click();await flush();assert.equal(starts,1);assert.equal(requests.filter(r=>r.action==='prepareLeads').at(-1).connectMode,'human');assert.equal(requests.find(r=>r.action==='prepareLeads').leadIds.length,3);assert.equal(instance.canLeave(),false);assert.equal($('powerCards').children.length,3);const firstCard=$('powerCards').firstChild;
 root.querySelector('[data-view="manual"]').click();assert.equal($('parallel').hidden,false);$('powerMute').click();assert.equal(activeCall.muted,true);
 state.legs[0].state='in-progress';await timers.find(t=>t.ms===1200).fn();await flush();assert.match(firstCard.textContent,/Checking for voicemail/);assert.equal(dialogOpens,0);
 state.legs[0].outcome='machine';state.legs[0].answer='machine';state.legs[0].state='completed';await timers.find(t=>t.ms===1200).fn();await flush();assert.match(firstCard.textContent,/Voicemail detected/);assert.equal(dialogOpens,0,'A machine must not open a connected-lead popup');
 state.state='connected';state.winnerId='leg1';state.legs[1].outcome='connected';await timers.find(t=>t.ms===1200).fn();await flush();assert.equal($('powerCards').firstChild,firstCard,'Polling replaced live cards');assert.match($('powerName').textContent,/Lead 2/);assert.match($('powerDetails').textContent,/61/);assert.equal($('powerSave').disabled,true);assert.equal($('powerConnectedDialog').open,true);assert.equal(dialogOpens,1);assert.equal($('powerDialogBody').querySelector('#powerName'),$('powerName'),'Popup must contain the real lead editor');assert.equal($('powerDialogStop').disabled,false);
 $('powerDialogMute').click();assert.equal(activeCall.muted,false);assert.equal($('powerMute').textContent,'Mute');
 $('powerDialogMinimize').click();assert.equal($('powerConnectedDialog').open,false);assert.equal($('powerReopen').hidden,false);await timers.find(t=>t.ms===1200).fn();await flush();assert.equal(dialogOpens,1,'Polling reopened a minimized card');$('powerReopen').click();assert.equal(dialogOpens,2);
 $('powerNotes').value='Customer asked for a callback tomorrow';$('powerNotes').dispatchEvent(new w.Event('input'));
 stopError=true;$('powerDialogStop').click();await flush();assert.equal(instance.canLeave(),false);assert.match($('powerMessage').textContent,/confirmation is pending/);stopError=false;
 $('powerDialogStop').click();await flush();assert.equal($('powerConnection').textContent,'Batch finished');assert.equal(instance.canLeave(),false,'Required wrap-up was discarded');assert.equal(starts,1,'Stop automatically redialed');assert.equal($('powerConnectedDialog').open,true,'Call end hid required wrap-up');assert.match($('powerConnectedState').textContent,/save your notes/);assert.equal($('powerDialogStop').disabled,true);assert.equal($('powerNotes').value,'Customer asked for a callback tomorrow');
 $('powerOutcome').value='call_back';$('powerSave').click();await flush();assert.equal(instance.canLeave(),true);assert.equal($('powerConnectedDialog').open,false);assert.equal(root.querySelector('.power-columns .power-lead #powerName'),$('powerName'));assert.equal(leads[1].agent_status,'call_back');assert.equal(leads[1].call_notes,'Customer asked for a callback tomorrow');
 // Existing subscriptions stay required, with visible setup guidance for new agents.
 access=false;$('powerRefreshHistory').click();await flush();assert.equal($('powerSetup').hidden,false);assert.equal($('powerStart').disabled,true);
 w.localStorage.setItem('lld_session',JSON.stringify({user:{id:'other'},access_token:'other'}));w.dispatchEvent(new w.StorageEvent('storage',{key:'lld_session'}));assert.equal(root.querySelector('#parallel'),null);
 console.log('PASS: paid-agent tab, folder/states, valid lead queue, HTML escaping, microphone recovery, pending-setup polling and cancellation, default voicemail filtering, three-line launch, stable cards, automatic winner popup, minimize/reopen, popup call controls, draft preservation, stop retry, required outcome, no auto-redial, setup guidance and account cleanup.');
 }finally{instance?.dispose();dom.window.close();}
})().catch(e=>{console.error(e);process.exitCode=1;});
