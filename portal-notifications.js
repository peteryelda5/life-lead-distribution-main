/* One permission-scoped notification center, shared by every portal role. */
(() => {
 'use strict';
 const categories={leads:'Leads',requests:'Lead requests',calls:'Calls & follow-ups',deals:'Closed deals',chat:'Chat',announcements:'Announcements',team:'Team & goals',billing:'Billing'};
 let failures=0,retryAt=0;
 let owner=null,epoch=0,revision=0,timer=null,flight=null,again=false,busy=false,panel=null,data=null,filter='all',unreadOnly=false,offset=0,lastSignature='',seen=null,seenAfter=0,toastQueue=[],toastCards=new Map(),toastRegion=null;
 let liveChannel=null,liveStarting=false,liveTimer=null,dealStart=0,chatSeen=new Map(),celebrationSound=null,soundEnabled=true;
 const soundKey=()=> 'lld_celebration_sound:'+owner;
 function loadSoundPreference(){try{soundEnabled=localStorage.getItem(soundKey())!=='off';}catch{soundEnabled=true;}}
 function quietForCall(){return !!window.manualCalling?.()||(typeof portalDialerInstance!=='undefined'&&!!portalDialerInstance&&(typeof portalDialerInstance.isBusy!=='function'||portalDialerInstance.isBusy()));}
 function getSound(){if(!celebrationSound&&eligible()&&window.createPortalCelebrationSound){const id=owner,ticket=epoch;celebrationSound=window.createPortalCelebrationSound({enabled:()=>soundEnabled,quiet:quietForCall,active:()=>current(id,ticket)});}return celebrationSound;}
 function unlockSound(){if(eligible())getSound()?.unlock();}
 const $=id=>document.getElementById(id);
 const eligible=()=>typeof S!=='undefined'&&S.session&&S.profile?.active&&!S.profile.archived&&!S.mfaMode&&(currentAal()==='aal2'||window.PortalPasskeys?.verified()===true)&&!!document.querySelector('.portal-topnav');
 const current=(id,ticket)=>eligible()&&S.profile.id===id&&epoch===ticket;
 const query=()=>({category:filter,unread:unreadOnly,offset});
 const rpc=(action,extra={})=>api('/rest/v1/rpc/portal_notifications',{method:'POST',body:{p_action:action,p_data:{...query(),...extra}}});
 const element=(tag,className,text)=>{const el=document.createElement(tag);if(className)el.className=className;if(text!==undefined)el.textContent=text;return el;};
 function button(text,action,className=''){const b=element('button',className,text);b.type='button';b.onclick=action;return b;}
 function reset(){failures=0;retryAt=0;epoch++;revision++;close(false);clearToasts();stopLive();celebrationSound?.dispose();celebrationSound=null;clearInterval(timer);timer=null;owner=null;data=null;seen=null;seenAfter=0;dealStart=0;chatSeen.clear();flight=null;again=false;busy=false;offset=0;filter='all';unreadOnly=false;lastSignature='';paintBadge();}
 function stopLive(){clearTimeout(liveTimer);liveTimer=null;liveStarting=false;const channel=liveChannel;liveChannel=null;if(channel&&typeof SB!=='undefined')Promise.resolve(SB.removeChannel(channel)).catch(()=>{});}
 function queueLiveRefresh(id,ticket){if(!current(id,ticket)||document.hidden||liveTimer)return;liveTimer=setTimeout(()=>{liveTimer=null;if(current(id,ticket))refresh();},250);}
 async function connectLive(){
  if(!eligible()||liveChannel||liveStarting||typeof SB==='undefined'||!SB.channel||!SB.realtime)return;
  const id=owner,ticket=epoch;liveStarting=true;
  try{
   await SB.realtime.setAuth(S.session.access_token);if(!current(id,ticket))return;
   const channel=SB.channel('lld-notifications-'+id);liveChannel=channel;
   channel.on('postgres_changes',{event:'UPDATE',schema:'public',table:'leaderboard_updates'},()=>queueLiveRefresh(id,ticket))
    .on('postgres_changes',{event:'INSERT',schema:'public',table:'chat_messages'},()=>queueLiveRefresh(id,ticket))
    .on('postgres_changes',{event:'DELETE',schema:'public',table:'chat_messages'},()=>queueLiveRefresh(id,ticket)).subscribe(state=>{
    if(!current(id,ticket)||liveChannel!==channel)return;
    if(state==='SUBSCRIBED')queueLiveRefresh(id,ticket);
    else if(['CHANNEL_ERROR','TIMED_OUT','CLOSED'].includes(state))stopLive();
   });
  }catch(e){if(current(id,ticket))stopLive();}finally{if(ticket===epoch)liveStarting=false;}
 }
 function paintBadge(){const b=$('portalNotifications');if(!b)return;const count=Number(data?.unread||0),badge=b.querySelector('.pn-badge');badge.textContent=count>99?'99+':String(count);badge.hidden=!count;b.setAttribute('aria-label','Notifications'+(count?', '+count+' unread':''));b.setAttribute('aria-expanded',String(!!panel));}
 function status(text,error=false){const el=$('pnStatus');if(el){el.textContent=text;el.classList.toggle('pn-error',error);}}
 function close(focus=true){if(!panel)return;panel.remove();panel=null;lastSignature='';paintBadge();if(focus)$('portalNotifications')?.focus();}
 function clearToasts(){for(const card of toastCards.values())clearTimeout(card.timer);toastCards.clear();toastQueue=[];toastRegion?.remove();toastRegion=null;}
 function dismissToast(key){const card=toastCards.get(key);if(card){clearTimeout(card.timer);card.box.remove();toastCards.delete(key);}pumpToasts();}
 function pumpToasts(){
  if(!eligible()||document.hidden)return;
  while(toastCards.size<3&&toastQueue.length){
   const n=toastQueue.shift();if(toastCards.has(n.key))continue;
   if(!toastRegion){toastRegion=element('section','pn-toast-stack');toastRegion.setAttribute('aria-label','New notifications');document.body.append(toastRegion);}
   const box=element('aside','pn-toast');box.dataset.key=n.key;box.setAttribute('role','status');box.setAttribute('aria-live','polite');
   const icon=element('span','pn-toast-icon',({leads:'↗',requests:'✓',calls:'☎',chat:'✉',announcements:'i',team:'★',billing:'!'}[n.category]||'i'));icon.setAttribute('aria-hidden','true');
   const open=button('',async()=>{if(await openNotification(n))dismissToast(n.key);},'pn-toast-open');
   const deal=n.category==='deals'&&n.target?.celebration==='corner';
   if(deal){
    const amount=Number(n.target.annual_premium),premium=Number.isFinite(amount)&&amount>=0?new Intl.NumberFormat('en-US',{style:'currency',currency:'USD',maximumFractionDigits:Number.isInteger(amount)?0:2}).format(amount):'—';
    box.classList.add('pn-celebration');icon.textContent='✓';
    open.append(element('span','pn-toast-category','Deal closed'),element('strong','pn-deal-agent',n.target.agent_name||'A teammate'),element('span','pn-deal-agency',n.target.agency_name||''),element('span','pn-deal-premium','+ '+premium),element('span','pn-toast-link','Annual premium · View leaderboard →'));
    const progress=element('span','pn-deal-progress');progress.setAttribute('aria-hidden','true');box.append(progress);
    if(!window.matchMedia?.('(prefers-reduced-motion: reduce)').matches){
     const burst=element('span','pn-confetti');burst.setAttribute('aria-hidden','true');
     for(let i=0;i<18;i++){const piece=element('i');piece.style.setProperty('--x',((i*41)%257-128)+'px');piece.style.setProperty('--rise',(-40-(i*17)%55)+'px');piece.style.setProperty('--turn',((i%2?1:-1)*(180+i*37))+'deg');piece.style.setProperty('--delay',((i%6)*35)+'ms');piece.style.setProperty('--color',['#16a577','#f0bf4c','#4299e1'][i%3]);burst.append(piece);}
     box.append(burst);
    }
   }else open.append(element('span','pn-toast-category',categories[n.category]||'Update'),element('strong','',n.title),element('span','pn-toast-body',n.body),element('span','pn-toast-link','Open →'));
   const dismiss=button('×',()=>dismissToast(n.key),'pn-toast-close');dismiss.setAttribute('aria-label','Dismiss alert');
   box.append(icon,open,dismiss);toastRegion.append(box);if(deal)getSound()?.play();
   const card={box,item:n,timer:null,remaining:10000,started:0};toastCards.set(n.key,card);
   const pause=()=>{box.classList.add('pn-paused');if(card.timer){clearTimeout(card.timer);card.timer=null;card.remaining=Math.max(0,card.remaining-(Date.now()-card.started));}};
   const resume=()=>{if(card.timer||box.matches(':hover')||box.contains(document.activeElement))return;box.classList.remove('pn-paused');card.started=Date.now();card.timer=setTimeout(()=>dismissToast(n.key),card.remaining);};
   box.onmouseenter=pause;box.onmouseleave=resume;box.onfocusin=pause;box.onfocusout=()=>setTimeout(resume,0);resume();
  }
  if(!toastCards.size&&!toastQueue.length){toastRegion?.remove();toastRegion=null;}
 }
 function toast(items){
  const next=new Map(items.map(n=>[n.key,n.at]));
  const viewing=n=>S.tab==='live-chat'&&n.category==='chat'&&(n.target?.conversation?(typeof PC!=='undefined'&&PC.group===n.target.conversation):(typeof CHAT!=='undefined'&&CHAT.room===n.target?.room&&!(typeof PC!=='undefined'&&PC.group)));
  const chatVersion=n=>/^\d+$/.test(String(n.target?.message_id||''))?BigInt(n.target.message_id):null;
  const freshChat=n=>{
   const at=Date.parse(n.at),version=chatVersion(n),previous=chatSeen.get(n.key);
   if(at<=dealStart||at<=seenAfter-120000)return false;
   if(version!==null)return previous===undefined||version>previous;
   return seen.get(n.key)!==n.at&&(!seen.has(n.key)||at>Date.parse(seen.get(n.key)));
  };
  // Message IDs distinguish same-millisecond messages and never replay older
  // messages when the latest post is deleted. The overlap handles late commits.
  const chatItems=new Map(items.filter(n=>n.category==='chat').map(n=>[n.key,n]));
  const currentChat=n=>{const latest=chatItems.get(n.key);return latest&&!latest.read&&(chatVersion(latest)!==null?chatVersion(latest)===chatVersion(n):latest.at===n.at);};
  toastQueue=toastQueue.filter(n=>n.category!=='chat'||currentChat(n));
  for(const [key,card] of toastCards)if(card.item?.category==='chat'&&!currentChat(card.item)){clearTimeout(card.timer);card.box.remove();toastCards.delete(key);}
  // The small overlap catches transactions committed just after the last poll.
  // The first-response cutoff and stable deal key prevent history/edit replays.
  const fresh=seen?items.filter(n=>!n.read&&!viewing(n)&&(n.category==='deals'?(!seen.has(n.key)&&Date.parse(n.at)>dealStart&&Date.parse(n.at)>seenAfter-120000):(n.category==='chat'?freshChat(n):(seen.get(n.key)!==n.at&&Date.parse(n.at)>seenAfter)))):[];
  for(const n of items)if(n.category==='chat'){const version=chatVersion(n);if(version!==null&&(chatSeen.get(n.key)===undefined||version>chatSeen.get(n.key)))chatSeen.set(n.key,version);}
  if(!seen)dealStart=Date.parse(data?.as_of)||Date.now();
  seenAfter=Date.parse(data?.as_of)||Date.now();seen=new Map([...(seen||[]),...next]);if(seen.size>1000)seen=next;
  if(document.hidden||!data?.preferences?.toast_enabled)return;
  for(const n of fresh){
   // New versions replace the old card, while distinct alerts queue without loss.
   const old=toastCards.get(n.key);if(old){clearTimeout(old.timer);old.box.remove();toastCards.delete(n.key);}
   toastQueue=toastQueue.filter(x=>x.key!==n.key);toastQueue.push(n);
  }
  pumpToasts();
 }
 async function refresh(){
  if(!eligible()){reset();return;}if(owner!==S.profile.id){reset();owner=S.profile.id;loadSoundPreference();}
  if(Date.now()<retryAt)return;if(busy){again=true;return;}if(flight){again=true;return flight;}const id=owner,ticket=epoch,view=revision;
  flight=(async()=>{try{const filtered=filter!=='all'||unreadOnly||offset!==0;const [d,feed]=await Promise.all([rpc('list'),filtered?rpc('list',{category:'all',unread:false,offset:0}):Promise.resolve(null)]);if(!current(id,ticket)||view!==revision){again=true;return;}failures=0;retryAt=0;data=d;paintBadge();paint();toast((feed||d).items||[]);status('');}
   catch(e){if(current(id,ticket)){failures=Math.min(failures+1,4);retryAt=Date.now()+Math.min(120000,20000*2**(failures-1));status('Notifications could not refresh. Retrying shortly. '+e.message,true);}}
   finally{if(ticket===epoch){flight=null;if(again){again=false;refresh();}}}})();return flight;
 }
 async function change(action,extra={}){
  if(busy||!eligible())return false;busy=true;revision++;const id=owner,ticket=epoch,view=revision;paintBusy();
  try{const result=await rpc(action,extra);if(!current(id,ticket))return false;if(view===revision){data=result;paintBadge();paint();if(action==='preferences'){clearToasts();dealStart=Date.parse(result.as_of)||Date.now();}}else refresh();status('');return true;}
  catch(e){if(current(id,ticket))status(e.message,true);return false;}
  finally{if(ticket===epoch){busy=false;paintBusy();if(again){again=false;refresh();}}}
 }
 function paintBusy(){if(!panel)return;for(const b of panel.querySelectorAll('[data-mutation]'))b.disabled=busy||(b.id==='pnMarkAll'&&!data?.unread);panel.setAttribute('aria-busy',String(busy));}
 function receipt(n){return {items:[{key:n.key,at:n.at}]};}
 async function openNotification(n){
  if(!eligible())return;
  if(typeof portalDialerInstance!=='undefined'&&portalDialerInstance&&!portalDialerInstance.canLeave()){if(!panel)open();status('Finish your call and save its outcome before opening this notification.',true);return;}
  const id=owner,ticket=epoch,t=n.target||{},tabs=['my-leads','activity','lead-requests','power-dialer','live-chat','announcements','dashboard','agents','leaderboard'];
  if(!tabs.includes(t.tab))return;
  try{
   await navigatePortalTab(t.tab);if(!current(id,ticket)||S.tab!==t.tab)return;
   if(t.tab==='power-dialer'){
    await mountPortalDialer();if(!current(id,ticket))return;
    const root=portalDialerInstance?.root;
    const control=t.view==='priority'?root?.querySelector('#agentPriority'):['callbacks','billing'].includes(t.view)?root?.querySelector('[data-view="'+t.view+'"]'):null;
    if(!control)throw Error('This dialer view is still loading. Please try again.');control.click();
   }else if(t.tab==='live-chat'){
    if(t.conversation){await pcList();if(!current(id,ticket))return;if(!PC.chats.some(c=>c.id===t.conversation))throw Error('This conversation is no longer available.');PC.group=t.conversation;CHAT.rows=[];PC.rows=[];render();await refreshChat();}
    else if(['general','deals','resources'].includes(t.room)){await changeChatRoom(CHAT.division,t.room);}
   }
   if(!current(id,ticket))return;const success=await change('read',receipt(n));if(success)close(false);return success;
  }catch(e){if(current(id,ticket)){if(!panel)open();status(e.message,true);}}
 }
 function paint(){
  if(!panel||!data)return;const rows=$('pnRows'),signature=JSON.stringify([data.items,data.total,offset,filter,unreadOnly]);
  $('pnAll').setAttribute('aria-pressed',String(!unreadOnly));$('pnUnread').setAttribute('aria-pressed',String(unreadOnly));$('pnUnread').textContent='Unread ('+data.unread+')';
  $('pnCategory').value=filter;$('pnMarkAll').disabled=busy||!data.unread;
  $('pnPrevious').disabled=offset===0;$('pnNext').disabled=offset+50>=Number(data.total);
  $('pnPage').textContent=data.total?(offset+1)+'–'+Math.min(offset+50,data.total)+' of '+data.total:'No notifications';
  if(signature===lastSignature)return;lastSignature=signature;
  const scroll=rows.scrollTop,focus=document.activeElement?.dataset.pnFocus;rows.replaceChildren();
  for(const n of data.items||[]){
   const item=element('article','pn-item'+(n.read?'':' pn-unread'));item.dataset.key=n.key;
   const dot=element('span','pn-dot');dot.setAttribute('aria-hidden','true');
   const content=element('div','pn-item-content'),head=element('div','pn-item-meta');
   const time=element('time','',new Date(n.at).toLocaleString(undefined,{month:'short',day:'numeric',hour:'numeric',minute:'2-digit'}));time.dateTime=n.at;
   head.append(element('span','',categories[n.category]||'Update'),time);
   const open=button('',()=>openNotification(n),'pn-item-open');open.dataset.pnFocus=n.key+':open';open.append(element('strong','',n.title),element('span','',n.body));
   const actions=element('div','pn-item-actions');
   const mark=button(n.read?'Mark unread':'Mark read',()=>change(n.read?'unread':'read',receipt(n)));mark.dataset.mutation='true';mark.dataset.pnFocus=n.key+':read';
   const archive=button('Dismiss',()=>change('archive',receipt(n)));archive.dataset.mutation='true';archive.dataset.pnFocus=n.key+':archive';
   actions.append(mark,archive);content.append(head,open,actions);item.append(dot,content);rows.append(item);
  }
  if(!rows.children.length){const empty=element('div','pn-empty');empty.append(element('strong','',unreadOnly?'You’re all caught up':'No notifications here'),element('p','','Updates appear here as activity happens in your workspace.'));rows.append(empty);}
  rows.scrollTop=scroll;if(focus)[...rows.querySelectorAll('[data-pn-focus]')].find(el=>el.dataset.pnFocus===focus)?.focus({preventScroll:true});paintBusy();
 }
 function preferences(){
  const box=$('pnPreferences');box.hidden=!box.hidden;if(box.hidden)return;box.replaceChildren();
  box.append(element('h3','','Notification preferences'),element('p','','Choose which updates appear in your inbox. Chat also follows each conversation’s notification settings.'));
  for(const [key,label] of Object.entries(categories)){const row=element('label'),input=element('input');input.type='checkbox';input.name='category';input.value=key;input.checked=!data?.preferences?.muted_categories?.includes(key);row.append(input,document.createTextNode(label));box.append(row);}
  const row=element('label'),input=element('input');input.type='checkbox';input.name='toasts';input.checked=data?.preferences?.toast_enabled!==false;row.append(input,document.createTextNode('Show bottom-right pop-up alerts'));box.append(row);
  const soundRow=element('label'),soundInput=element('input');soundInput.type='checkbox';soundInput.name='celebration-sound';soundInput.checked=soundEnabled;soundRow.append(soundInput,document.createTextNode('Play cash-register sound on this device'));box.append(soundRow);
  const preview=button('Preview sound',async()=>{if(quietForCall()){status('Celebration sound is muted during calls and wrap-up.');return;}const played=await getSound()?.play(true);status(played?'Cash-register sound preview.':'Click Preview sound again to enable audio in your browser.');});preview.disabled=!soundEnabled;
  soundInput.onchange=()=>{soundEnabled=soundInput.checked;preview.disabled=!soundEnabled;try{localStorage.setItem(soundKey(),soundEnabled?'on':'off');}catch{}if(soundEnabled)unlockSound();else celebrationSound?.stop();};
  box.append(element('p','','Sound preference saves on this device. Chimes stay quiet during calls and wrap-up.'),preview);
  const save=button('Save preferences',async()=>{const muted=[...box.querySelectorAll('[name=category]:not(:checked)')].map(i=>i.value);if(await change('preferences',{muted_categories:muted,toast_enabled:input.checked})){box.hidden=true;status('Preferences saved.');}},'pn-primary');save.dataset.mutation='true';box.append(save);
 }
 function open(){
  if(!eligible())return;if(panel){close();return;}
  panel=element('section','pn-panel');panel.id='portalNotificationPanel';panel.setAttribute('role','dialog');panel.setAttribute('aria-modal','false');panel.setAttribute('aria-labelledby','pnTitle');
  panel.innerHTML='<header class="pn-header"><div><h2 id="pnTitle">Notifications</h2><p>Your workspace updates</p></div><button id="pnClose" aria-label="Close notifications">×</button></header><div class="pn-toolbar"><div><button id="pnAll" aria-pressed="true">All</button><button id="pnUnread" aria-pressed="false">Unread</button></div><button id="pnPhone">Phone alerts</button><button id="pnSettings">Preferences</button></div><div class="pn-filters"><label>Category<select id="pnCategory"><option value="all">All categories</option></select></label><button id="pnMarkAll" data-mutation="true">Mark all read</button><button id="pnRefresh" aria-label="Refresh notifications">Refresh</button></div><div id="pnPreferences" class="pn-preferences" hidden></div><p id="pnStatus" class="pn-status" role="status" aria-live="polite"></p><div id="pnRows" class="pn-rows"></div><footer class="pn-footer"><span id="pnPage"></span><button id="pnPrevious">Previous</button><button id="pnNext">Next</button></footer><p class="pn-retention">Recent 30 days, plus unresolved callbacks. Alerts update while the portal is open.</p>';
  document.body.append(panel);for(const [key,label] of Object.entries(categories))$('pnCategory').add(new Option(label,key));
  $('pnClose').onclick=()=>close();$('pnPhone').onclick=()=>window.PortalPush?.open();$('pnSettings').onclick=preferences;$('pnRefresh').onclick=()=>refresh();
  const applyFilter=()=>{revision++;offset=0;lastSignature='';status('Loading…');refresh();};
  $('pnAll').onclick=()=>{unreadOnly=false;applyFilter();};$('pnUnread').onclick=()=>{unreadOnly=true;applyFilter();};$('pnCategory').onchange=e=>{filter=e.target.value;applyFilter();};
  $('pnMarkAll').onclick=()=>{if(data?.as_of)change('read_all',{before:data.as_of});};
  $('pnPrevious').onclick=()=>{offset=Math.max(0,offset-50);revision++;refresh();};$('pnNext').onclick=()=>{offset+=50;revision++;refresh();};
  paintBadge();paint();status(data?'':'Loading notifications…');$('pnClose').focus();refresh();
 }
 function bind(){
  if(!eligible()){reset();return;}if(owner!==S.profile.id){reset();owner=S.profile.id;loadSoundPreference();}
  const bell=$('portalNotifications');if(bell)bell.onclick=open;paintBadge();window.PortalPush?.sync();
  connectLive();
  if(!timer){timer=setInterval(()=>{if(!eligible()){reset();return;}if(!document.hidden){connectLive();if(!busy)refresh();}},20000);refresh();}
 }
 document.addEventListener('pointerdown',unlockSound,{passive:true});document.addEventListener('keydown',unlockSound);
 document.addEventListener('keydown',e=>{if(panel&&e.key==='Escape'){e.preventDefault();e.stopPropagation();close();}},true);
 document.addEventListener('pointerdown',e=>{if(panel&&!panel.contains(e.target)&&!$('portalNotifications')?.contains(e.target))close(false);});
 document.addEventListener('visibilitychange',()=>{if(!document.hidden){bind();pumpToasts();}});
 window.addEventListener('storage',e=>{if(e.key==='lld_session')reset();});
 window.PortalNotifications={bind,open,openItem:openNotification,refresh(){if(eligible())queueLiveRefresh(owner,epoch);},sync(){if(!eligible())reset();else bind();},reset,buttonHtml:()=>'<button type="button" id="portalNotifications" class="pn-bell" aria-label="Notifications" aria-haspopup="dialog" aria-expanded="false" aria-controls="portalNotificationPanel"><svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" aria-hidden="true"><path d="M18 8a6 6 0 0 0-12 0c0 7-3 7-3 9h18c0-2-3-2-3-9M10 21h4"/></svg><span class="pn-bell-label">Notifications</span><span class="pn-badge" hidden></span></button>'};
})();

