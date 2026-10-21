'use strict';
const fs=require('node:fs'),assert=require('node:assert/strict'),{JSDOM}=require('jsdom');
const tick=async()=>{for(let i=0;i<5;i++)await new Promise(r=>setImmediate(r));};
const source=fs.readFileSync(__dirname+'/../portal-notifications.js','utf8');
const event=(key='delivery:1',extra={})=>({key,category:'leads',title:'New leads assigned to you',body:'10 leads delivered',target:{tab:'my-leads'},at:'2026-10-20T10:00:00Z',read:false,...extra});
function setup(role='agent',leader=false,options={}){
 const dom=new JSDOM('<body><header class="portal-topnav"></header></body>',{url:'https://www.lldportal.com',runScripts:'outside-only',pretendToBeVisual:true}),w=dom.window;
 const requests=[],navigation=[];let list=options.items||[event()],muted=[],popups=true,now='2026-10-20T10:01:00Z',hold=null,pending=null,blocked=false;
 w.S={session:{},profile:{id:'agent-one',role,is_team_leader:leader,active:true},tab:'dashboard'};w.currentAal=()=> 'aal2';
 w.portalDialerInstance={canLeave:()=>!blocked,root:w.document.createElement('div')};w.portalDialerInstance.root.innerHTML='<button data-view="callbacks"></button><button data-view="billing"></button><button id="agentPriority"></button>';
 w.mountPortalDialer=async()=>{};w.navigatePortalTab=async tab=>{navigation.push(tab);w.S.tab=tab;};w.PC={chats:[{id:'private-chat'}]};w.CHAT={division:'mine'};w.pcList=async()=>{};w.render=()=>{};w.refreshChat=async()=>{};w.changeChatRoom=async(d,r)=>{w.CHAT.room=r;};
 const response=q=>{const all=list.filter(n=>!n.archived&&!muted.includes(n.category)),items=all.filter(n=>(!q.category||q.category==='all'||q.category===n.category)&&(!q.unread||!n.read));return JSON.parse(JSON.stringify({items:items.slice(q.offset||0,(q.offset||0)+50),total:items.length,unread:all.filter(n=>!n.read).length,as_of:now,preferences:{muted_categories:muted,toast_enabled:popups}}));};
 const live={subscriptions:0,removed:0,event:null,state:null};
 w.matchMedia=()=>({matches:!!options.reducedMotion});
 if(options.live)w.SB={realtime:{async setAuth(){}},channel(){live.subscriptions++;return {on(type,config,fn){assert.equal(type,'postgres_changes');assert.equal(config.schema,'public');if(config.table==='leaderboard_updates'){assert.equal(config.event,'UPDATE');live.event=fn;}else{assert.equal(config.table,'chat_messages');assert(['INSERT','DELETE'].includes(config.event));live[config.event]=fn;}return this;},subscribe(fn){live.state=fn;return this;}};},async removeChannel(){live.removed++;}};
 w.api=async(path,{body})=>{assert.equal(path,'/rest/v1/rpc/portal_notifications');requests.push(body);const {p_action:a,p_data:q}=body;
  if(hold===a){hold=null;const snapshot=response(q);return new Promise(resolve=>{pending=()=>resolve(snapshot);});}
  if(['read','unread','archive'].includes(a))for(const item of q.items){const n=list.find(n=>n.key===item.key);if(n){if(a==='archive')n.archived=true;else n.read=a==='read';}}
  if(a==='read_all')list.forEach(n=>{if(n.at<=q.before)n.read=true;});
  if(a==='preferences'){muted=q.muted_categories;popups=q.toast_enabled;}
  return response(q);
 };
 let poll;const originalInterval=w.setInterval.bind(w);w.setInterval=(fn,ms)=>{poll=fn;return originalInterval(fn,ms);};
 w.eval(source);w.document.querySelector('header').innerHTML=w.PortalNotifications.buttonHtml();w.PortalNotifications.bind();
 const $=id=>w.document.getElementById(id),click=async id=>{$(id).click();await tick();};
 return {w,dom,$,click,requests,navigation,live,async poll(){poll();await tick();},setList(v){list=v;},setNow(v){now=v;},hold(a){hold=a;},release(){assert(pending);const p=pending;pending=null;p();},block(v){blocked=v;},async close(){w.PortalNotifications.reset();dom.window.close();}};
}
(async()=>{
 for(const [role,leader] of [['agent',false],['agent',true],['admin',false]]){const h=setup(role,leader);try{await tick();assert.equal(h.$('portalNotifications').getAttribute('aria-label'),'Notifications, 1 unread');assert.equal(h.w.document.querySelector('.pn-toast'),null);await h.click('portalNotifications');assert.equal(h.w.document.querySelectorAll('.pn-item').length,1);h.w.PortalNotifications.sync();assert.equal(h.w.document.querySelectorAll('#portalNotificationPanel').length,1);}finally{await h.close();}}
 const shellSource=fs.readFileSync(__dirname+'/../portal-app.js','utf8');assert(shellSource.includes("+(window.PortalNotifications?.buttonHtml()||'')+"));assert(shellSource.includes('renderContent();window.PortalNotifications?.sync();'));
 const html=fs.readFileSync(__dirname+'/../index.html','utf8');assert(html.indexOf('/portal-notifications.js?')<html.indexOf('/portal-app.js?'));
 const h=setup();try{
  await tick();h.setList([event('unsafe',{title:'<img src=x onerror=alert(1)>',body:'<script>bad()</script>'})]);await h.click('portalNotifications');assert.equal(h.w.document.querySelector('.pn-item img'),null);assert.match(h.w.document.querySelector('.pn-item-open').textContent,/<img/);
  h.w.document.querySelector('.pn-item-actions button').click();await tick();assert.equal(h.requests.at(-1).p_action,'read');assert.equal(h.$('pnMarkAll').disabled,true);assert.match(h.w.document.querySelector('.pn-item-actions button').textContent,/unread/);
  h.w.document.querySelector('.pn-item-actions button').click();await tick();assert.equal(h.requests.at(-1).p_action,'unread');assert.equal(h.$('pnMarkAll').disabled,false);
  await h.click('pnUnread');assert(h.requests.slice(-2).some(r=>r.p_data.unread===true));h.$('pnCategory').value='calls';h.$('pnCategory').dispatchEvent(new h.w.Event('change'));await tick();assert(h.requests.slice(-2).some(r=>r.p_data.category==='calls'));assert.match(h.$('pnRows').textContent,/caught up/);
  h.$('pnCategory').value='all';h.$('pnCategory').dispatchEvent(new h.w.Event('change'));await tick();await h.click('pnAll');
  await h.click('pnSettings');h.w.document.querySelector('[name=category][value=team]').checked=false;h.w.document.querySelector('[name=toasts]').checked=false;h.w.document.querySelector('.pn-primary').click();await tick();assert.equal(h.requests.at(-1).p_action,'preferences');assert.deepEqual([...h.requests.at(-1).p_data.muted_categories],['team']);assert.equal(h.requests.at(-1).p_data.toast_enabled,false);
  await h.click('pnMarkAll');assert.equal(h.requests.at(-1).p_data.before,'2026-10-20T10:01:00Z');assert.equal(h.$('pnMarkAll').disabled,true);
  h.w.document.querySelectorAll('.pn-item-actions button')[1].click();await tick();assert.equal(h.requests.at(-1).p_action,'archive');assert.equal(h.w.document.querySelector('.pn-item'),null);
  h.setList([event('call',{category:'calls',target:{tab:'power-dialer',view:'callbacks'}})]);await h.click('pnRefresh');h.block(true);h.w.document.querySelector('.pn-item-open').click();await tick();assert.equal(h.navigation.length,0);assert.match(h.$('pnStatus').textContent,/Finish your call/);assert.equal(h.w.document.querySelector('.pn-item').classList.contains('pn-unread'),true);
  h.block(false);let callbacks=0;h.w.portalDialerInstance.root.querySelector('[data-view=callbacks]').onclick=()=>callbacks++;h.w.document.querySelector('.pn-item-open').click();await tick();assert.equal(callbacks,1);assert.equal(h.navigation.at(-1),'power-dialer');assert.equal(h.$('portalNotificationPanel'),null);
  h.setList([event('group:private-chat',{category:'chat',target:{tab:'live-chat',conversation:'private-chat'}})]);await h.click('portalNotifications');h.w.document.querySelector('.pn-item-open').click();await tick();assert.equal(h.w.PC.group,'private-chat');assert.equal(h.requests.at(-1).p_action,'read');
  h.setList([event('same')]);await h.click('portalNotifications');const item=h.w.document.querySelector('.pn-item');item.querySelector('button').focus();h.$('pnRows').scrollTop=40;await h.click('pnRefresh');assert.equal(h.w.document.querySelector('.pn-item'),item);assert.equal(h.$('pnRows').scrollTop,40);
  // An older poll must never undo a completed mark-read mutation.
  h.hold('list');h.$('pnRefresh').click();await tick();h.w.document.querySelector('.pn-item-actions button').click();await tick();assert.equal(h.w.document.querySelector('.pn-item').classList.contains('pn-unread'),false);h.release();await tick();assert.equal(h.w.document.querySelector('.pn-item').classList.contains('pn-unread'),false);
  // Logout/account changes discard in-flight data and remove private UI.
  h.hold('list');h.$('pnRefresh').click();await tick();h.w.S.profile.id='agent-two';h.w.PortalNotifications.reset();h.release();await tick();assert.equal(h.$('portalNotificationPanel'),null);assert.equal(h.w.document.querySelector('.pn-toast'),null);
  h.w.currentAal=()=> 'aal1';const before=h.requests.length;h.w.PortalNotifications.bind();await tick();assert.equal(h.requests.length,before);
 }finally{await h.close();}
 const t=setup();try{await tick();assert.equal(t.w.document.querySelector('.pn-toast'),null);
  t.setNow('2026-10-20T10:03:00Z');t.setList([event('fresh',{at:'2026-10-20T10:02:00Z'})]);await t.poll();assert(t.w.document.querySelector('.pn-toast'));
  t.w.document.querySelector('.pn-toast-close').click();await t.poll();assert.equal(t.w.document.querySelector('.pn-toast'),null);
  t.setList([event('older',{at:'2026-10-20T09:00:00Z'})]);await t.poll();assert.equal(t.w.document.querySelector('.pn-toast'),null);
  t.w.S.tab='live-chat';t.w.PC.group='currently-open';t.setNow('2026-10-20T10:05:00Z');t.setList([event('group:currently-open',{category:'chat',at:'2026-10-20T10:04:00Z',target:{tab:'live-chat',conversation:'currently-open'}})]);await t.poll();assert.equal(t.w.document.querySelector('.pn-toast'),null);
  t.setNow('2026-10-20T10:07:00Z');t.setList([event('group:other-chat',{category:'chat',at:'2026-10-20T10:06:00Z',target:{tab:'live-chat',conversation:'other-chat'}})]);await t.poll();assert(t.w.document.querySelector('.pn-toast'));t.w.document.querySelector('.pn-toast-close').click();
  await t.click('portalNotifications');t.$('pnCategory').value='calls';t.$('pnCategory').dispatchEvent(new t.w.Event('change'));await tick();await t.click('pnClose');
  t.setNow('2026-10-20T10:09:00Z');t.setList([event('delivery:after-filter',{at:'2026-10-20T10:08:00Z'})]);await t.poll();assert(t.w.document.querySelector('.pn-toast'));assert.match(t.w.document.querySelector('.pn-toast').textContent,/New leads/);
 }finally{await t.close();}
 const stack=setup();try{
  await tick();await stack.click('portalNotifications');
  stack.setNow('2026-10-20T10:04:00Z');stack.setList(Array.from({length:5},(_,i)=>event('batch:'+i,{title:'Alert '+i,body:'<img src=x onerror=alert(1)> Details '+i,at:'2026-10-20T10:03:00Z'})));await stack.poll();
  assert.equal(stack.w.document.querySelectorAll('.pn-toast').length,3,'show three cards even with inbox open');assert(stack.w.document.querySelector('.pn-toast-stack'));
  assert.equal(stack.w.document.querySelector('.pn-toast img'),null);assert.match(stack.w.document.querySelector('.pn-toast-body').textContent,/<img/);
  stack.w.document.querySelector('.pn-toast-close').click();assert.equal(stack.w.document.querySelectorAll('.pn-toast').length,3);assert.match(stack.w.document.querySelector('.pn-toast-stack').textContent,/Alert 3/);
  stack.w.document.querySelector('.pn-toast-close').click();assert.equal(stack.w.document.querySelectorAll('.pn-toast').length,3);assert.match(stack.w.document.querySelector('.pn-toast-stack').textContent,/Alert 4/);
  stack.block(true);stack.w.document.querySelector('.pn-toast-open').click();await tick();assert.equal(stack.navigation.length,0);assert.equal(stack.w.document.querySelectorAll('.pn-toast').length,3);
  stack.block(false);stack.w.document.querySelector('.pn-toast-open').click();await tick();assert.equal(stack.navigation.at(-1),'my-leads');assert.equal(stack.w.document.querySelectorAll('.pn-toast').length,2,'opening one alert leaves the others');
  stack.w.PortalNotifications.reset();assert.equal(stack.w.document.querySelector('.pn-toast-stack'),null);
 }finally{await stack.close();}
 const deal=(key,at='2026-10-20T10:02:00Z',extra={})=>event(key,{category:'deals',title:'Agent closed a deal',body:'Agency · $1,440.00 annual premium',at,target:{tab:'leaderboard',celebration:'corner',agent_name:'Test Agent',agency_name:'Test Agency',annual_premium:1440,...extra}});
 const c=setup('agent',false,{live:true,items:[deal('deal:history','2026-10-20T10:00:00Z')]});try{
  await tick();assert.equal(c.w.document.querySelector('.pn-celebration'),null,'no historical celebration on initial load');assert.equal(c.live.subscriptions,1);c.w.PortalNotifications.sync();await tick();assert.equal(c.live.subscriptions,1);
  c.setNow('2026-10-20T10:03:00Z');c.setList([deal('deal:new'),event('normal',{at:'2026-10-20T10:02:00Z'})]);
  const before=c.requests.length;c.live.event();c.live.event();c.live.event();await new Promise(r=>setTimeout(r,300));await tick();assert.equal(c.requests.length,before+1,'agency signals coalesce into one refresh');
  let card=c.w.document.querySelector('.pn-celebration');assert(card);assert.match(card.textContent,/Test Agent/);assert.match(card.textContent,/Test Agency/);assert.match(card.textContent,/\+ \$1,440/);assert.equal(card.querySelectorAll('.pn-confetti i').length,18);assert.equal(c.w.document.querySelectorAll('.pn-toast').length,2,'regular alerts stay visible');assert.equal(c.w.document.querySelector('audio,video,canvas'),null);
  card.onmouseenter();assert(card.classList.contains('pn-paused'));card.onmouseleave();assert(!card.classList.contains('pn-paused'));
  c.block(true);card.querySelector('.pn-toast-open').click();await tick();assert.equal(c.navigation.length,0,'celebration cannot leave an active call');
  c.block(false);card.querySelector('.pn-toast-open').click();await tick();assert.equal(c.navigation.at(-1),'leaderboard');assert.equal(c.w.document.querySelector('.pn-celebration'),null);assert(c.w.document.querySelector('.pn-toast'),'other alert survives celebration navigation');c.w.document.querySelector('.pn-toast-close').click();
  c.setNow('2026-10-20T10:04:00Z');c.setList([deal('deal:new','2026-10-20T10:02:00Z',{annual_premium:2400})]);await c.poll();assert.equal(c.w.document.querySelector('.pn-celebration'),null,'editing existing deal does not replay');
  c.setNow('2026-10-20T10:05:00Z');c.setList([deal('deal:late','2026-10-20T10:03:30Z',{agent_name:'<img src=x onerror=alert(1)>',annual_premium:1440.48})]);await c.poll();card=c.w.document.querySelector('.pn-celebration');assert(card,'late transaction gets a small overlap window');assert.equal(card.querySelector('img'),null);assert.match(card.textContent,/\$1,440.48/);card.querySelector('.pn-toast-close').click();
  c.setList([deal('deal:very-old','2026-10-20T09:59:00Z')]);await c.poll();assert.equal(c.w.document.querySelector('.pn-celebration'),null);
  await c.click('portalNotifications');await c.click('pnSettings');c.w.document.querySelector('[name=category][value=deals]').checked=false;c.w.document.querySelector('.pn-primary').click();await tick();
  c.setNow('2026-10-20T10:06:00Z');c.setList([deal('deal:muted','2026-10-20T10:05:30Z')]);await c.poll();assert.equal(c.w.document.querySelector('.pn-celebration'),null);
  await c.click('pnSettings');c.w.document.querySelector('[name=category][value=deals]').checked=true;c.w.document.querySelector('.pn-primary').click();await tick();await c.poll();assert.equal(c.w.document.querySelector('.pn-celebration'),null,'unmuting does not replay earlier deals');
  const oldEvent=c.live.event;c.w.PortalNotifications.reset();assert.equal(c.live.removed,1);const count=c.requests.length;oldEvent();await new Promise(r=>setTimeout(r,300));assert.equal(c.requests.length,count,'stale real-time event after logout is ignored');
 }finally{await c.close();}
 const reduced=setup('agent',false,{reducedMotion:true});try{await tick();reduced.setNow('2026-10-20T10:03:00Z');reduced.setList([deal('deal:reduced')]);await reduced.poll();assert(reduced.w.document.querySelector('.pn-celebration'));assert.equal(reduced.w.document.querySelector('.pn-confetti'),null,'reduced motion omits confetti');}finally{await reduced.close();}

 const chatMessage=(id,at='2026-10-20T10:02:00.001Z')=>event('channel:general',{category:'chat',title:'New message in #general',body:'A teammate posted in #general.',at,target:{tab:'live-chat',room:'general',message_id:String(id)}});
 for(const [role,leader] of [['agent',false],['agent',true],['admin',false]]){
  const liveChat=setup(role,leader,{live:true,items:[chatMessage(100,'2026-10-20T10:00:00Z')]});
  try{
   await tick();assert.equal(liveChat.w.document.querySelector('.pn-toast'),null);
   assert.equal(typeof liveChat.live.INSERT,'function');assert.equal(typeof liveChat.live.DELETE,'function');
   liveChat.setNow('2026-10-20T10:03:00Z');liveChat.setList([chatMessage(101)]);
   const before=liveChat.requests.length;liveChat.live.INSERT({new:{body:'Untrusted event payload'}});liveChat.live.INSERT();
   await new Promise(r=>setTimeout(r,300));await tick();assert.equal(liveChat.requests.length,before+1);
   assert.match(liveChat.w.document.querySelector('.pn-toast').textContent,/#general/);assert(!liveChat.w.document.body.textContent.includes('Untrusted event payload'));
   liveChat.w.document.querySelector('.pn-toast-close').click();await liveChat.poll();assert.equal(liveChat.w.document.querySelector('.pn-toast'),null);
   // A transaction created before the preceding refresh but committed afterward.
   liveChat.setNow('2026-10-20T10:03:20Z');liveChat.setList([chatMessage(102,'2026-10-20T10:02:59.999Z')]);await liveChat.poll();assert(liveChat.w.document.querySelector('.pn-toast'),'late chat commit is not lost');
   liveChat.w.document.querySelector('.pn-toast-close').click();
   // Message identity, not rounded JS timestamps, distinguishes rapid messages.
   liveChat.setList([chatMessage(103,'2026-10-20T10:02:59.999Z')]);await liveChat.poll();assert(liveChat.w.document.querySelector('.pn-toast'),'same millisecond message appears');
   liveChat.setList([chatMessage(101)]);liveChat.live.DELETE();await new Promise(r=>setTimeout(r,300));await tick();assert.equal(liveChat.w.document.querySelector('.pn-toast'),null,'deleted latest message removes card without replaying history');await liveChat.poll();assert.equal(liveChat.w.document.querySelector('.pn-toast'),null);
   liveChat.w.S.tab='live-chat';liveChat.w.CHAT.room='general';liveChat.w.PC.group=null;
   liveChat.setList([chatMessage(104,'2026-10-20T10:03:30Z')]);liveChat.setNow('2026-10-20T10:04:00Z');await liveChat.poll();assert.equal(liveChat.w.document.querySelector('.pn-toast'),null,'no duplicate toast in currently viewed channel');
   liveChat.w.S.tab='dashboard';liveChat.setList([chatMessage(105,'2026-10-20T10:04:10Z')]);liveChat.setNow('2026-10-20T10:04:20Z');await liveChat.poll();assert(liveChat.w.document.querySelector('.pn-toast'));
   liveChat.w.document.querySelector('.pn-toast-open').click();await tick();assert.equal(liveChat.navigation.at(-1),'live-chat');assert.equal(liveChat.w.CHAT.room,'general');
   const oldSignal=liveChat.live.INSERT;liveChat.w.PortalNotifications.reset();const count=liveChat.requests.length;oldSignal();await new Promise(r=>setTimeout(r,300));assert.equal(liveChat.requests.length,count);
  }finally{await liveChat.close();}
 }
 console.log('PASS: corner celebrations, stable deal deduplication, delayed transactions, reduced motion, preferences, real-time coalescing/cleanup, stacked alerts and burst queue, independent dismiss/open, active-call safety, all roles, inbox and unread badge, safe text, filters, persisted action payloads, preferences, active-call protection, callback/chat navigation, stable focus, polling races, account cleanup and MFA gating.');
})().catch(e=>{console.error(e);process.exitCode=1;});
