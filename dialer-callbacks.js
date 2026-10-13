/* Callback inbox and a separate incoming-only device. Outgoing calls keep their existing grants. */
(() => {
 'use strict';
 let badgeOwner=null,badgeTimer=null,badgeFlight=null,unread=0;
 const account=()=>typeof S!=='undefined'&&S.session&&S.profile?.id===S.session.user?.id?S.profile.id+':'+portalSessionEpoch:null;
 function drawBadge(){const button=document.getElementById('powerDialerOpen');if(!button)return;let badge=button.querySelector('.callback-count');if(!unread){badge?.remove();return;}if(!badge){badge=document.createElement('span');badge.className='callback-count';button.append(badge);}badge.textContent=String(unread);badge.title=unread+' missed callbacks or voicemails';}
 async function badgePoll(){const key=account();if(!key||document.hidden||badgeFlight)return;badgeFlight=key;try{const count=await api('/rest/v1/rpc/my_dialer_callback_unread',{method:'POST',body:{}});if(account()===key){unread=Number(count)||0;drawBadge();}}catch{}finally{if(badgeFlight===key)badgeFlight=null;}}
 function bindBadge(){const key=account();if(key!==badgeOwner){clearInterval(badgeTimer);badgeTimer=null;badgeOwner=key;unread=0;badgeFlight=null;if(key){badgePoll();badgeTimer=setInterval(badgePoll,30000);}}drawBadge();}
 window.PortalCallbacks={bindBadge,refresh:badgePoll,reset(){clearInterval(badgeTimer);badgeTimer=null;badgeOwner=null;unread=0;drawBadge();}};
 window.createDialerCallbacks=function(root,options){
  const owner=account(),userId=S.profile.id,browserId=crypto.randomUUID();let disposed=false,device=null,registered=false,starting=false,call=null,connected=false,visible=true,offset=0,loading=false,polling=false,heartbeatBusy=false,heartbeatAgain=false,heartbeatFlight=null,lastPresence='',renewing=false,rows=[],audioUrl=null;
  const $=id=>root.querySelector('#'+id),isOwner=()=>{try{return !disposed&&account()===owner&&JSON.parse(localStorage.getItem('lld_session')||'null')?.user?.id===userId;}catch{return false;}};
  const section=document.createElement('main');section.id='callbacks';section.className='secondary-view callback-inbox';section.hidden=true;
  section.innerHTML='<div class="section-heading"><div><h2>Callbacks &amp; voicemail</h2><p>Incoming calls to your dialer numbers. Open a matching lead or listen to a message.</p></div><button id="callbackRefresh">Refresh</button></div><p id="callbackMessage" role="status"></p><div id="callbackRows"></div><div class="history-pager"><button id="callbackPrevious">← Previous</button><button id="callbackNext">Next →</button></div>';
  root.append(section);
  const tab=document.createElement('button');tab.dataset.view='callbacks';tab.textContent='Callbacks & voicemail';root.querySelector('.workspace-tabs').append(tab);tab.onclick=()=>options.openView('callbacks');
  const bar=document.createElement('div');bar.className='incoming-toolbar';bar.innerHTML='<div><strong id="incomingState">Voicemail only</strong><span id="incomingHint">Go online to answer callbacks in this dialer.</span></div><button id="incomingOnline" class="primary">Go online</button><button id="incomingOffline" hidden>Go offline</button><button id="callbackNotice" hidden></button>';
  root.querySelector('.workspace-toolbar').after(bar);
  const panel=document.createElement('section');panel.className='incoming-call';panel.hidden=true;panel.setAttribute('role','region');panel.setAttribute('aria-label','Incoming callback');panel.innerHTML='<div><span id="incomingCaption">Incoming call</span><strong id="incomingCaller"></strong><small id="incomingLead"></small></div><div class="incoming-actions"><button id="incomingAnswer" class="primary">Answer</button><button id="incomingReject">Send to voicemail</button><button id="incomingMute" hidden>Mute</button><button id="incomingHangup" class="danger" hidden>Hang up</button></div>';
  bar.after(panel);
  function state(message,hint){$('incomingState').textContent=message;$('incomingHint').textContent=hint||'';}
  async function request(action,extra={},audio=false){
   if(!isOwner())throw Error('Your account changed.');if(typeof sessionExpiresWithin==='function'&&sessionExpiresWithin(120)&&!await refreshToken())throw Error('Sign in again to receive calls.');
   if(!isOwner())throw Error('Your account changed.');const session=S.session;
   const response=await fetch(audio?'/api/dialer/callback-audio':'/api/dialer/callbacks',{method:'POST',headers:{'Content-Type':'application/json',Authorization:'Bearer '+session.access_token},body:JSON.stringify({action,...extra}),cache:'no-store',signal:AbortSignal.timeout(30000)});
   if(!isOwner())throw Error('Your account changed.');if(!response.ok){let d;try{d=await response.json();}catch{}throw Error(d?.error||'Callbacks could not load. Please retry.');}return audio?response.blob():response.json();
  }
  function updateCount(count){unread=Number(count)||0;drawBadge();tab.textContent='Callbacks & voicemail'+(unread?' ('+unread+')':'');$('callbackNotice').hidden=!unread;$('callbackNotice').textContent=unread+' new '+(unread===1?'callback':'callbacks')+' — view';}
  async function heartbeat(){
   if(!isOwner())return;if(heartbeatBusy){heartbeatAgain=true;return heartbeatFlight;}
   heartbeatBusy=true;heartbeatFlight=(async()=>{try{do{heartbeatAgain=false;const busy=!!call||options.isBusy();lastPresence=String(registered&&visible)+':'+String(busy);await request('presence',{browserId,ready:registered&&visible,busy});if(registered&&!call)state(busy?'Busy — voicemail on':'Online for callbacks',busy?'Incoming callers can leave a message.':'Keep this dialer open to answer calls.');}while(heartbeatAgain&&isOwner());}
    catch(e){if(isOwner()&&registered){state('Connection interrupted','Callbacks may go to voicemail. '+e.message);}}
    finally{heartbeatBusy=false;heartbeatFlight=null;}})();return heartbeatFlight;
  }
  async function renew(){if(renewing||!isOwner()||!device)return;renewing=true;try{const d=await request('token',{browserId});if(isOwner()&&device)device.updateToken(d.token);}catch(e){if(isOwner())state('Reconnect needed',e.message);}finally{renewing=false;}}
  async function goOnline(){
   if(starting||registered||!isOwner())return;starting=true;$('incomingOnline').disabled=true;state('Connecting…','Allow microphone access if your browser asks.');
   try{
    if(!window.Twilio?.Device)throw Error('Calling support is loading. Try again.');
    // Ask during the user's click so the browser can enable audio and the microphone.
    const stream=await navigator.mediaDevices.getUserMedia({audio:true});stream.getTracks().forEach(track=>track.stop());
    const d=await request('token',{browserId});if(!isOwner())return;
    device?.destroy();device=new Twilio.Device(d.token,{logLevel:0,closeProtection:true,tokenRefreshMs:60000,allowIncomingWhileBusy:false});
    device.on('registered',()=>{if(!isOwner())return;registered=true;$('incomingOnline').hidden=true;$('incomingOffline').hidden=false;heartbeat();});
    device.on('unregistered',()=>{registered=false;if(isOwner()){state('Voicemail only','Go online to answer callbacks.');$('incomingOnline').hidden=false;$('incomingOffline').hidden=true;heartbeat();}});
    device.on('tokenWillExpire',renew);device.on('incoming',receive);
    device.on('error',e=>{if(isOwner()){state('Incoming connection needs attention',e.message||'Reconnect to receive calls.');if(!call){registered=false;device?.destroy();device=null;$('incomingOnline').hidden=false;$('incomingOffline').hidden=true;heartbeat();}}});
    await device.register();
   }catch(e){if(isOwner())state('Voicemail only',e.name==='NotAllowedError'?'Allow microphone access, then click Go online.':e.message);}
   finally{starting=false;if(isOwner())$('incomingOnline').disabled=false;}
  }
  function endIncoming(){const hadCall=!!call;call=null;connected=false;panel.hidden=true;if(hadCall){options.onBusyChange(false);heartbeat();load();}}
  async function receive(incoming){
   if(!isOwner()||!visible||options.isBusy()||call){incoming.reject();return;}
   root.querySelectorAll('.callback-row audio').forEach(audio=>audio.pause());call=incoming;connected=false;options.onBusyChange(true);panel.hidden=false;$('incomingCaption').textContent='Incoming call';$('incomingCaller').textContent=incoming.parameters?.From||'Unknown caller';$('incomingLead').textContent='Finding matching lead…';$('incomingAnswer').hidden=$('incomingReject').hidden=false;$('incomingAnswer').disabled=false;$('incomingMute').hidden=$('incomingHangup').hidden=true;heartbeat();
   incoming.on('accept',()=>{if(call!==incoming)return;connected=true;$('incomingCaption').textContent='Connected';$('incomingAnswer').hidden=$('incomingReject').hidden=true;$('incomingMute').hidden=$('incomingHangup').hidden=false;state('On an incoming call','Other callers can leave a message.');});
   for(const event of ['disconnect','cancel','reject','error'])incoming.on(event,()=>{if(call===incoming)endIncoming();});
   const id=incoming.customParameters?.get('CallbackId');
   if(id)try{const data=await request('list',{id});if(call!==incoming||!isOwner())return;const c=data.calls?.[0];if(c?.matches?.length===1)options.showIncomingLead(c.matches[0]);$('incomingLead').textContent=c?.matches?.length===1?leadLabel(c.matches[0]):c?.matches?.length?'Multiple matching leads — view in Callbacks.':'No matching assigned lead.';}catch{if(call===incoming)$('incomingLead').textContent='Caller details are available in Callbacks.';}
  }
  function leadLabel(lead){return [lead.first_name,lead.last_name].filter(Boolean).join(' ')||'Unnamed lead';}
  function button(label,fn){const b=document.createElement('button');b.type='button';b.textContent=label;b.onclick=fn;return b;}
  async function markSeen(c){await request('seen',{id:c.id});c.seen_at=new Date().toISOString();window.PortalCallbacks.refresh();await load();}
  function renderRows(){
   const box=$('callbackRows');box.replaceChildren();
   for(const c of rows){const item=document.createElement('article');item.className='callback-row'+(!c.seen_at&&['missed','voicemail'].includes(c.status)?' unread':'');const summary=document.createElement('div'),name=document.createElement('strong'),detail=document.createElement('p'),status=document.createElement('span');
    name.textContent=c.matches?.length===1?leadLabel(c.matches[0]):c.caller_phone;detail.textContent=c.caller_phone+' · '+new Date(c.created_at).toLocaleString()+' · To '+c.dialed_phone;status.className='callback-status';status.textContent=c.status==='voicemail'?'Voicemail':c.status==='answered'?'Answered':c.status==='ringing'?'Ringing':'Missed call';summary.append(name,status,detail);item.append(summary);
    const actions=document.createElement('div');actions.className='callback-actions';
    for(const lead of c.matches||[])actions.append(button('Open '+leadLabel(lead),async()=>{if(options.isBusy()||call)return;try{const fresh=await request('list',{id:c.id});const match=fresh.calls?.[0]?.matches?.find(l=>l.id===lead.id);if(!match)throw Error('This lead is no longer assigned to you.');if(options.openLead(match))await markSeen(c);}catch(e){$('callbackMessage').textContent=e.message;}}));
    if(!c.matches?.length){const note=document.createElement('span');note.className='callback-muted';note.textContent='No matching assigned lead';actions.append(note);}
    if(c.has_voicemail){const listen=button('Play voicemail'+(c.recording_seconds?' · '+c.recording_seconds+'s':''),async()=>{listen.disabled=true;try{const blob=await request('audio',{id:c.id},true);if(!isOwner())return;if(audioUrl)URL.revokeObjectURL(audioUrl);audioUrl=URL.createObjectURL(blob);root.querySelectorAll('.callback-row audio').forEach(el=>el.remove());const audio=document.createElement('audio');audio.controls=true;audio.src=audioUrl;audio.setAttribute('aria-label','Voicemail from '+c.caller_phone);item.append(audio);await audio.play();await request('seen',{id:c.id});item.classList.remove('unread');window.PortalCallbacks.refresh();}catch(e){$('callbackMessage').textContent=e.message;}finally{listen.disabled=false;}});actions.append(listen);}
    else if(c.recording_pending){const wait=document.createElement('span');wait.className='callback-muted';wait.textContent='Checking for voicemail…';actions.append(wait);}
    if(!c.seen_at)actions.append(button('Mark reviewed',()=>markSeen(c).catch(e=>{$('callbackMessage').textContent=e.message;})));
    item.append(actions);box.append(item);
   }
   $('callbackMessage').textContent=rows.length?'':'No callbacks yet. Incoming calls will appear here.';$('callbackPrevious').disabled=offset===0;$('callbackNext').disabled=rows.length<50;
  }
  async function load(){if(loading||!isOwner())return;loading=true;$('callbackRefresh').disabled=true;try{const d=await request('list',{offset});if(!isOwner())return;rows=d.calls||[];updateCount(d.unread);renderRows();}catch(e){if(isOwner())$('callbackMessage').textContent=e.message;}finally{loading=false;if(isOwner())$('callbackRefresh').disabled=false;}}
  async function poll(){if(polling||!isOwner())return;polling=true;try{if(registered&&visible)await heartbeat();if(visible&&!document.hidden&&![...root.querySelectorAll('.callback-row audio')].some(audio=>!audio.paused))await load();}finally{polling=false;}}
  $('incomingOnline').onclick=goOnline;$('incomingOffline').onclick=()=>{if(call)return;registered=false;device?.destroy();device=null;state('Voicemail only','Go online to answer callbacks.');$('incomingOnline').hidden=false;$('incomingOffline').hidden=true;heartbeat();};
  $('incomingAnswer').onclick=()=>{if(!call||connected)return;$('incomingAnswer').disabled=true;try{call.accept();}catch(e){$('incomingAnswer').disabled=false;state('Could not answer',e.message);}};
  $('incomingReject').onclick=()=>{if(call&&!connected){call.reject();endIncoming();}};
  $('incomingMute').onclick=()=>{if(call&&connected){const muted=!call.isMuted();call.mute(muted);$('incomingMute').textContent=muted?'Unmute':'Mute';}};
  $('incomingHangup').onclick=()=>{call?.disconnect();endIncoming();};
  $('callbackNotice').onclick=()=>options.openView('callbacks');$('callbackRefresh').onclick=load;
  $('callbackPrevious').onclick=()=>{if(!loading){offset=Math.max(0,offset-50);load();}};$('callbackNext').onclick=()=>{if(!loading){offset+=50;load();}};
  const timer=setInterval(()=>{if(!isOwner()){dispose();return;}poll();},20000);
  const unload=e=>{if(call){e.preventDefault();e.returnValue='';}},storageEvent=e=>{if(e.key==='lld_session'&&!isOwner())dispose();};window.addEventListener('beforeunload',unload);window.addEventListener('storage',storageEvent);
  function dispose(){if(disposed)return;registered=false;if(isOwner())request('presence',{browserId,ready:false,busy:true}).catch(()=>{});disposed=true;clearInterval(timer);window.removeEventListener('beforeunload',unload);window.removeEventListener('storage',storageEvent);call?.disconnect();device?.destroy();if(audioUrl)URL.revokeObjectURL(audioUrl);rows=[];section.replaceChildren();panel.remove();bar.remove();tab.remove();}
  load();return {dispose,busy:()=>!!call,changed(){if(options.isBusy())root.querySelectorAll('.callback-row audio').forEach(audio=>audio.pause());if(registered&&lastPresence!==String(registered&&visible)+':'+String(!!call||options.isBusy()))heartbeat();},show:load,setVisible(value){visible=value;if(!value&&!call)heartbeat();else if(value){heartbeat();load();}},canLeave(){return !call;}};
 };
})();
