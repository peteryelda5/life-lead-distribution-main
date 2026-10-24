/* Opt-in Web Push for installed iPhone web apps and other capable browsers. */
(() => {
 'use strict';
 const labels={deals:'Closed deals',chat:'New chats & direct messages',leads:'New leads',requests:'Lead requests',calls:'Callbacks & voicemails',announcements:'Announcements',team:'Team updates',billing:'Calling plan updates'};
 const storageKey='vivid_phone_notifications';
 let owner=null,epoch=0,device=null,registration=null,config=null,preparing=null,panel=null,busy=false,checkedSession=null,opening=false;
 let wakeTimer=null,wakeOwner=null,wakeFlight=false,wakeDirty=false,wakeRetries=0;
 let pending=new URL(location.href).searchParams.get('push');
 const uuid=value=>/^[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}$/i.test(value||'');
 if(!uuid(pending))pending=null;
 const eligible=()=>typeof S!=='undefined'&&typeof ONBOARDING!=='undefined'&&ONBOARDING.complete&&ONBOARDING.userId===S.profile?.id&&S.session&&S.profile?.active&&!S.profile.archived&&!S.mfaMode&&(currentAal()==='aal2'||window.PortalPasskeys?.verified()===true);
 const iphone=()=>/iPad|iPhone|iPod/.test(navigator.userAgent)||(navigator.platform==='MacIntel'&&navigator.maxTouchPoints>1);
 const standalone=()=>navigator.standalone===true||window.matchMedia?.('(display-mode: standalone)').matches;
 const supported=()=>window.isSecureContext&&'serviceWorker' in navigator&&'PushManager' in window&&'Notification' in window;
 const current=(id,ticket)=>eligible()&&S.profile.id===id&&owner===id&&epoch===ticket;
 const el=(tag,className,text)=>{const e=document.createElement(tag);if(className)e.className=className;if(text!==undefined)e.textContent=text;return e;};
 function saved(){try{return JSON.parse(localStorage.getItem(storageKey)||'null');}catch{return null;}}
 function remember(){try{if(device)localStorage.setItem(storageKey,JSON.stringify({owner,id:device.id}));else localStorage.removeItem(storageKey);}catch{}}
 function message(text,error=false){const p=panel?.querySelector('.pp-status');if(p){p.textContent=text;p.classList.toggle('pp-error',error);}}
 function close(){panel?.remove();panel=null;document.getElementById('pnPhone')?.focus();}
 function reset(){clearTimeout(wakeTimer);wakeTimer=null;wakeOwner=null;wakeDirty=false;wakeRetries=0;epoch++;owner=null;device=null;preparing=null;registration=null;config=null;checkedSession=null;opening=false;busy=false;close();}
 async function request(action,extra={}){
  const id=owner,ticket=epoch;
  if(!current(id,ticket))throw Error('Sign in to manage phone notifications.');
  if(typeof sessionExpiresWithin==='function'&&sessionExpiresWithin(120))await refreshToken();
  if(!current(id,ticket))throw Error('Your account changed. Open notifications again.');
  const r=await fetch('/api/notifications/push',{method:'POST',headers:{Authorization:'Bearer '+S.session.access_token,'Content-Type':'application/json'},body:JSON.stringify({action,...extra}),signal:AbortSignal.timeout(15000)});
  const d=await r.json();if(!current(id,ticket))throw Error('Your account changed. Open notifications again.');
  if(!r.ok)throw Error(d.error||'Could not update phone notifications.');return d;
 }
 // Successful source writes wake delivery even on desktops without push enabled.
 // The recipient does not need an open portal. The scheduled worker is fallback.
 function afterWrite(path,opt={}){
  if(opt.method!=='POST'||!eligible())return;
  const route=path.split('?')[0];
  const direct=['/rest/v1/rpc/chat_send_social','/rest/v1/rpc/chat_standalone_deal','/rest/v1/rpc/chat_standalone_deal_with_client','/rest/v1/rpc/close_lead','/rest/v1/rpc/book_crm_save','/rest/v1/rpc/book_crm_save_v2','/rest/v1/rpc/book_crm_policy_save','/rest/v1/closed_business','/rest/v1/portal_announcements'];
  if(!direct.includes(route)&&!(route==='/rest/v1/rpc/portal_collaboration'&&opt.body?.p_action==='send'))return;
  wakeOwner=S.profile.id;wakeDirty=true;wakeRetries=0;clearTimeout(wakeTimer);
  wakeTimer=setTimeout(wake,150);
 }
 async function wake(){
  wakeTimer=null;
  if(wakeFlight||!wakeDirty||!eligible()||wakeOwner!==S.profile.id)return;
  const id=wakeOwner;wakeDirty=false;wakeFlight=true;
  try{
   const r=await fetch('/api/notifications/push',{method:'POST',headers:{Authorization:'Bearer '+S.session.access_token,'Content-Type':'application/json'},body:JSON.stringify({action:'wake'}),keepalive:true,signal:AbortSignal.timeout(55000)});
   const result=await r.json();
   if(id!==wakeOwner||!eligible()||id!==S.profile.id)return;
   if(r.ok&&result.accepted===false&&Number(result.retry_after_ms)>0){wakeDirty=true;wakeTimer=setTimeout(wake,Math.min(3000,Math.max(100,result.retry_after_ms+50)));}
   else if(!r.ok&&r.status>=500&&wakeRetries++<2){wakeDirty=true;wakeTimer=setTimeout(wake,2000);}
  }catch{
   if(id===wakeOwner&&eligible()&&id===S.profile.id&&wakeRetries++<2){wakeDirty=true;wakeTimer=setTimeout(wake,2000);}
  }finally{
   wakeFlight=false;
   if(wakeDirty&&!wakeTimer&&eligible()&&wakeOwner===S.profile.id)wakeTimer=setTimeout(wake,150);
  }
 }
 function prepare(){
  if(preparing)return preparing;
  const id=owner,ticket=epoch;
  preparing=(async()=>{
   const response=await fetch('/api/notifications/push',{cache:'no-store',signal:AbortSignal.timeout(10000)}),settings=await response.json();
   if(!current(id,ticket))return;
   config=settings;
   if(!supported()||(iphone()&&!standalone()))return;
   const reg=await navigator.serviceWorker.register('/portal-push-sw.js',{scope:'/',updateViaCache:'none'});
   await navigator.serviceWorker.ready;if(!current(id,ticket))return;registration=reg;
   let sub=await reg.pushManager.getSubscription();
   if(saved()?.owner&&saved().owner!==id){if(sub)await sub.unsubscribe();sub=null;if(current(id,ticket)){device=null;remember();}}
   if(sub){const result=await request('sync',{endpoint:sub.endpoint});if(current(id,ticket)){device=result.device;remember();}}
   else if(current(id,ticket)){device=null;remember();}
  })().finally(()=>{if(current(id,ticket)){preparing=null;paint();}});
  return preparing;
 }
 function keyBytes(value){const text=atob(value.replace(/-/g,'+').replace(/_/g,'/')+'='.repeat((4-value.length%4)%4));return Uint8Array.from(text,c=>c.charCodeAt(0));}
 async function enable(){
  if(busy||!registration||!config?.available)return;
  // Invoke the native prompt directly inside the user's click, before any await.
  const permission=Notification.requestPermission();
  busy=true;paint();const id=owner,ticket=epoch;let candidate=null;
  try{
   if(await permission!=='granted')throw Error('Notifications are off. On iPhone, open Settings → Notifications → Vivid Life to allow them, then return here.');
   if(!current(id,ticket))return;
   let sub=await registration.pushManager.getSubscription();
   const key=keyBytes(config.publicKey);
   if(sub?.options?.applicationServerKey&&Array.from(new Uint8Array(sub.options.applicationServerKey)).join(',')!==Array.from(key).join(',')){await sub.unsubscribe();sub=null;}
   sub=sub||await registration.pushManager.subscribe({userVisibleOnly:true,applicationServerKey:key});candidate=sub;
   if(!current(id,ticket)){await sub.unsubscribe();return;}
   const result=await request('subscribe',{subscription:sub.toJSON()});device=result.device;remember();paint();
   message('Phone notifications are on. Send a test below to check your iPhone.');
  }catch(e){if(current(id,ticket)){paint();message(e.message,true);}else await candidate?.unsubscribe().catch(()=>{});}
  finally{if(current(id,ticket)){busy=false;paintButtons();}}
 }
 async function change(action){
  if(busy||!device)return;busy=true;paintButtons();const id=owner,ticket=epoch;
  try{
   const extra=action==='preferences'?{categories:[...panel.querySelectorAll('[name=phone-category]:checked')].map(x=>x.value)}:{};
   const result=await request(action,{id:device.id,...extra});
   if(action==='test'){message('Test sent. Check your iPhone’s lock screen or Notification Center.');return;}
   if(action==='disable'){const sub=await registration?.pushManager.getSubscription();await sub?.unsubscribe();}
   if(!current(id,ticket))return;device=result.device;remember();paint();
   message(action==='disable'?'Phone notifications are off on this device.':'Phone notification choices saved.');
  }catch(e){if(current(id,ticket))message(e.message,true);}
  finally{if(current(id,ticket)){busy=false;paintButtons();}}
 }
 function paintButtons(){if(!panel)return;for(const b of panel.querySelectorAll('[data-push-action]'))b.disabled=busy||!!preparing||(b.dataset.pushAction==='enable'&&(!registration||!config?.available));}
 function paint(){
  if(!panel)return;const content=panel.querySelector('.pp-content');content.replaceChildren();
  if(iphone()&&!standalone()){
   content.append(el('h3','','Add Vivid Life to your Home Screen'),el('p','','This one-time step lets your iPhone receive alerts while the portal is closed.'));
   const steps=el('ol','pp-steps');for(const text of ['Open lldportal.com in Safari.','Tap Share, then Add to Home Screen. If shown, keep Open as Web App on.','Open the new Vivid Life icon and sign in.','Open Notifications → Phone alerts, then tap Enable iPhone notifications.'])steps.append(el('li','',text));
   content.append(steps,el('p','pp-note','Requires iOS 16.4 or newer. Each agent chooses whether to allow notifications.'));
  }else if(!supported())content.append(el('p','','Open this page from the Vivid Life Home Screen app on an updated iPhone to enable notifications.'));
  else if(device?.enabled){
   content.append(el('div','pp-enabled','✓ Notifications enabled on this device'),el('h3','','Choose your phone alerts'));
   const choices=el('div','pp-choices');for(const [key,label] of Object.entries(labels)){const row=el('label'),input=el('input');input.type='checkbox';input.name='phone-category';input.value=key;input.checked=device.categories.includes(key);row.append(input,document.createTextNode(label));choices.append(row);}content.append(choices);
   const actions=el('div','pp-actions');actions.append(control('Save choices',()=>change('preferences'),'preferences','pp-primary'),control('Send test notification',()=>change('test'),'test'));content.append(actions,control('Turn off on this device',()=>change('disable'),'disable','pp-disable'));
  }else{
   content.append(el('p','','Get closed-deal celebrations, new chats, leads, and callback alerts on your lock screen. You can choose which alerts you receive.'));
   content.append(control(iphone()?'Enable iPhone notifications':'Enable notifications on this device',enable,'enable','pp-primary'));
   if(preparing)content.append(el('p','pp-note','Preparing phone notifications…'));
   else if(!config?.available)content.append(el('p','pp-note','Phone notifications are not available yet. Close this window and try again shortly.'));
   if(window.Notification?.permission==='denied')content.append(el('p','pp-note','Notifications are blocked. Allow Vivid Life notifications in your phone’s Settings, then reopen the app.'));
  }
  content.append(el('p','pp-note','Alerts follow your agency access and notification preferences. Muted chats stay muted. Chats show the sender and message preview. Closed deals show the agent, carrier, policy type and premium. Alerts are sent after saving, with a scheduled retry if needed. Your phone’s preview and Focus settings control what appears on the lock screen.'));
  paintButtons();
 }
 function control(text,action,name,className=''){const b=el('button',className,text);b.type='button';b.dataset.pushAction=name;b.onclick=action;return b;}
 function open(){
  if(!eligible())return;sync();if(panel){close();return;}
  panel=el('div','pp-overlay');const box=el('section','pp-dialog');box.setAttribute('role','dialog');box.setAttribute('aria-modal','true');box.setAttribute('aria-labelledby','ppTitle');
  const header=el('header','pp-header'),heading=el('div');heading.append(el('span','pp-eyebrow','VIVID LIFE · PHONE ALERTS'));const title=el('h2','','Stay in the loop');title.id='ppTitle';heading.append(title,el('p','','Closed deals. New chats. Right on your lock screen.'));
  const dismiss=el('button','pp-close','×');dismiss.setAttribute('aria-label','Close phone notifications');dismiss.onclick=close;header.append(heading,dismiss);
  const status=el('p','pp-status');status.setAttribute('role','status');status.setAttribute('aria-live','polite');box.append(header,el('div','pp-content'),status);panel.append(box);panel.onclick=e=>{if(e.target===panel)close();};document.body.append(panel);paint();dismiss.focus();
  prepare().catch(e=>message(e.message,true));
 }
 async function openPending(){
  if(!pending||opening||!eligible()||!window.PortalNotifications?.openItem)return;
  if(typeof portalDialerInstance!=='undefined'&&portalDialerInstance&&!portalDialerInstance.canLeave())return;
  const id=pending,ticket=epoch;opening=true;
  try{
   const result=await request('open',{id});if(ticket!==epoch||pending!==id)return;
   if(result.item){const done=await window.PortalNotifications.openItem(result.item);if(!done)return;}
   else window.PortalNotifications.open?.();
   pending=null;const url=new URL(location.href);url.searchParams.delete('push');history.replaceState(history.state,'',url.pathname+url.search+url.hash);
  }catch{ /* Keep the deep link through sign-in/temporary network failures. */ }
  finally{if(ticket===epoch)opening=false;}
 }
 function sync(){
  if(!eligible()){if(owner)reset();return;}
  if(owner!==S.profile.id){reset();owner=S.profile.id;}
  let session;try{session=JSON.parse(atob(S.session.access_token.split('.')[1].replace(/-/g,'+').replace(/_/g,'/'))).session_id;}catch{session=S.session.access_token;}
  if(checkedSession!==session){checkedSession=session;if((iphone()&&standalone())||saved())prepare().catch(()=>{checkedSession=null;});}
  openPending();
 }
 async function beforeLogout(){
  const existing=device||saved();
  try{if(existing?.id&&eligible()){if(!owner)owner=S.profile.id;await request('disable',{id:existing.id});}}catch{}
  try{const reg=registration||await navigator.serviceWorker?.getRegistration('/');const sub=await reg?.pushManager.getSubscription();await sub?.unsubscribe();const alerts=await reg?.getNotifications();alerts?.forEach(n=>n.close());}catch{}
  device=null;remember();reset();
 }
 navigator.serviceWorker?.addEventListener('message',event=>{
  if(event.data?.type!=='vivid-push-open')return;
  try{const u=new URL(event.data.url);if(u.origin!==location.origin||u.pathname!=='/'||!uuid(u.searchParams.get('push')))return;pending=u.searchParams.get('push');history.replaceState(history.state,'',u.pathname+u.search);sync();}catch{}
 });
 document.addEventListener('keydown',e=>{if(!panel)return;if(e.key==='Escape'){e.preventDefault();close();}if(e.key==='Tab'){const controls=[...panel.querySelectorAll('button:not(:disabled),input')],first=controls[0],last=controls.at(-1);if(e.shiftKey&&document.activeElement===first){e.preventDefault();last?.focus();}else if(!e.shiftKey&&document.activeElement===last){e.preventDefault();first?.focus();}}});
 document.addEventListener('visibilitychange',()=>{if(!document.hidden)sync();});
 window.PortalPush={open,sync,beforeLogout,reset,afterWrite};
})();
