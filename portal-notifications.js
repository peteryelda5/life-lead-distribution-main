/* One permission-scoped notification center, shared by every portal role. */
(() => {
 'use strict';
 const categories={leads:'Leads',requests:'Lead requests',calls:'Calls & follow-ups',chat:'Chat',announcements:'Announcements',team:'Team & goals',billing:'Billing'};
 let owner=null,epoch=0,revision=0,timer=null,flight=null,again=false,busy=false,panel=null,data=null,filter='all',unreadOnly=false,offset=0,lastSignature='',seen=null,seenAfter=0;
 const $=id=>document.getElementById(id);
 const eligible=()=>typeof S!=='undefined'&&S.session&&S.profile?.active&&!S.profile.archived&&!S.mfaMode&&currentAal()==='aal2'&&!!document.querySelector('.portal-topnav');
 const current=(id,ticket)=>eligible()&&S.profile.id===id&&epoch===ticket;
 const query=()=>({category:filter,unread:unreadOnly,offset});
 const rpc=(action,extra={})=>api('/rest/v1/rpc/portal_notifications',{method:'POST',body:{p_action:action,p_data:{...query(),...extra}}});
 const element=(tag,className,text)=>{const el=document.createElement(tag);if(className)el.className=className;if(text!==undefined)el.textContent=text;return el;};
 function button(text,action,className=''){const b=element('button',className,text);b.type='button';b.onclick=action;return b;}
 function reset(){epoch++;revision++;close(false);document.querySelector('.pn-toast')?.remove();clearInterval(timer);timer=null;owner=null;data=null;seen=null;seenAfter=0;flight=null;again=false;busy=false;offset=0;filter='all';unreadOnly=false;lastSignature='';paintBadge();}
 function paintBadge(){const b=$('portalNotifications');if(!b)return;const count=Number(data?.unread||0),badge=b.querySelector('.pn-badge');badge.textContent=count>99?'99+':String(count);badge.hidden=!count;b.setAttribute('aria-label','Notifications'+(count?', '+count+' unread':''));b.setAttribute('aria-expanded',String(!!panel));}
 function status(text,error=false){const el=$('pnStatus');if(el){el.textContent=text;el.classList.toggle('pn-error',error);}}
 function close(focus=true){if(!panel)return;panel.remove();panel=null;lastSignature='';paintBadge();if(focus)$('portalNotifications')?.focus();}
 function toast(items){
  const next=new Map(items.map(n=>[n.key,n.at]));
  const fresh=seen&&items.find(n=>!n.read&&seen.get(n.key)!==n.at&&Date.parse(n.at)>seenAfter);
  seenAfter=Date.parse(data?.as_of)||Date.now();seen=new Map([...(seen||[]),...next]);if(seen.size>1000)seen=next;
  if(!fresh||panel||document.hidden||!data?.preferences?.toast_enabled||S.tab==='live-chat'&&fresh.category==='chat')return;
  document.querySelector('.pn-toast')?.remove();const box=element('aside','pn-toast');box.setAttribute('role','status');
  const open=button('',()=>openNotification(fresh),'pn-toast-open');open.append(element('strong','',fresh.title),element('span','','Open notification'));
  const dismiss=button('×',()=>box.remove(),'pn-toast-close');dismiss.setAttribute('aria-label','Dismiss alert');box.append(open,dismiss);document.body.append(box);setTimeout(()=>box.remove(),8000);
 }
 async function refresh(){
  if(!eligible()){reset();return;}if(owner!==S.profile.id){reset();owner=S.profile.id;}
  if(busy){again=true;return;}if(flight){again=true;return flight;}const id=owner,ticket=epoch,view=revision;
  flight=(async()=>{try{const d=await rpc('list');if(!current(id,ticket)||view!==revision){again=true;return;}data=d;paintBadge();paint();if(filter==='all'&&!unreadOnly&&offset===0)toast(d.items||[]);status('');}
   catch(e){if(current(id,ticket))status('Notifications could not refresh. '+e.message,true);}
   finally{if(ticket===epoch){flight=null;if(again){again=false;refresh();}}}})();return flight;
 }
 async function change(action,extra={}){
  if(busy||!eligible())return false;busy=true;revision++;const id=owner,ticket=epoch,view=revision;paintBusy();
  try{const result=await rpc(action,extra);if(!current(id,ticket))return false;if(view===revision){data=result;paintBadge();paint();}else refresh();status('');return true;}
  catch(e){if(current(id,ticket))status(e.message,true);return false;}
  finally{if(ticket===epoch){busy=false;paintBusy();if(again){again=false;refresh();}}}
 }
 function paintBusy(){if(!panel)return;for(const b of panel.querySelectorAll('[data-mutation]'))b.disabled=busy||(b.id==='pnMarkAll'&&!data?.unread);panel.setAttribute('aria-busy',String(busy));}
 function receipt(n){return {items:[{key:n.key,at:n.at}]};}
 async function openNotification(n){
  if(!eligible())return;
  if(typeof portalDialerInstance!=='undefined'&&portalDialerInstance&&!portalDialerInstance.canLeave()){if(!panel)open();status('Finish your call and save its outcome before opening this notification.',true);return;}
  const id=owner,ticket=epoch,t=n.target||{},tabs=['my-leads','activity','lead-requests','power-dialer','live-chat','announcements','dashboard','agents'];
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
   if(!current(id,ticket))return;const success=await change('read',receipt(n));if(success)close(false);document.querySelector('.pn-toast')?.remove();
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
  const row=element('label'),input=element('input');input.type='checkbox';input.name='toasts';input.checked=data?.preferences?.toast_enabled!==false;row.append(input,document.createTextNode('Show in-portal pop-up alerts'));box.append(row);
  const save=button('Save preferences',async()=>{const muted=[...box.querySelectorAll('[name=category]:not(:checked)')].map(i=>i.value);if(await change('preferences',{muted_categories:muted,toast_enabled:input.checked})){box.hidden=true;status('Preferences saved.');}},'pn-primary');save.dataset.mutation='true';box.append(save);
 }
 function open(){
  if(!eligible())return;if(panel){close();return;}
  panel=element('section','pn-panel');panel.id='portalNotificationPanel';panel.setAttribute('role','dialog');panel.setAttribute('aria-modal','false');panel.setAttribute('aria-labelledby','pnTitle');
  panel.innerHTML='<header class="pn-header"><div><h2 id="pnTitle">Notifications</h2><p>Your workspace updates</p></div><button id="pnClose" aria-label="Close notifications">×</button></header><div class="pn-toolbar"><div><button id="pnAll" aria-pressed="true">All</button><button id="pnUnread" aria-pressed="false">Unread</button></div><button id="pnSettings">Preferences</button></div><div class="pn-filters"><label>Category<select id="pnCategory"><option value="all">All categories</option></select></label><button id="pnMarkAll" data-mutation="true">Mark all read</button><button id="pnRefresh" aria-label="Refresh notifications">Refresh</button></div><div id="pnPreferences" class="pn-preferences" hidden></div><p id="pnStatus" class="pn-status" role="status" aria-live="polite"></p><div id="pnRows" class="pn-rows"></div><footer class="pn-footer"><span id="pnPage"></span><button id="pnPrevious">Previous</button><button id="pnNext">Next</button></footer><p class="pn-retention">Recent 30 days, plus unresolved callbacks. Alerts update while the portal is open.</p>';
  document.body.append(panel);for(const [key,label] of Object.entries(categories))$('pnCategory').add(new Option(label,key));
  $('pnClose').onclick=()=>close();$('pnSettings').onclick=preferences;$('pnRefresh').onclick=()=>refresh();
  const applyFilter=()=>{revision++;offset=0;lastSignature='';status('Loading…');refresh();};
  $('pnAll').onclick=()=>{unreadOnly=false;applyFilter();};$('pnUnread').onclick=()=>{unreadOnly=true;applyFilter();};$('pnCategory').onchange=e=>{filter=e.target.value;applyFilter();};
  $('pnMarkAll').onclick=()=>{if(data?.as_of)change('read_all',{before:data.as_of});};
  $('pnPrevious').onclick=()=>{offset=Math.max(0,offset-50);revision++;refresh();};$('pnNext').onclick=()=>{offset+=50;revision++;refresh();};
  paintBadge();paint();status(data?'':'Loading notifications…');$('pnClose').focus();refresh();
 }
 function bind(){
  if(!eligible()){reset();return;}if(owner!==S.profile.id){reset();owner=S.profile.id;}
  const bell=$('portalNotifications');if(bell)bell.onclick=open;paintBadge();
  if(!timer){timer=setInterval(()=>{if(!eligible()){reset();return;}if(!document.hidden&&!busy)refresh();},20000);refresh();}
 }
 document.addEventListener('keydown',e=>{if(panel&&e.key==='Escape'){e.preventDefault();e.stopPropagation();close();}},true);
 document.addEventListener('pointerdown',e=>{if(panel&&!panel.contains(e.target)&&!$('portalNotifications')?.contains(e.target))close(false);});
 document.addEventListener('visibilitychange',()=>{if(!document.hidden)bind();});
 window.addEventListener('storage',e=>{if(e.key==='lld_session')reset();});
 window.PortalNotifications={bind,sync(){if(!eligible())reset();else bind();},reset,buttonHtml:()=>'<button type="button" id="portalNotifications" class="pn-bell" aria-label="Notifications" aria-haspopup="dialog" aria-expanded="false" aria-controls="portalNotificationPanel"><svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" aria-hidden="true"><path d="M18 8a6 6 0 0 0-12 0c0 7-3 7-3 9h18c0-2-3-2-3-9M10 21h4"/></svg><span class="pn-bell-label">Notifications</span><span class="pn-badge" hidden></span></button>'};
})();
