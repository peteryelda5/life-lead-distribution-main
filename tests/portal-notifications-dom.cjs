'use strict';
const fs=require('node:fs'),assert=require('node:assert/strict'),{JSDOM}=require('jsdom');
const tick=async()=>{for(let i=0;i<5;i++)await new Promise(r=>setImmediate(r));};
const source=fs.readFileSync(__dirname+'/../portal-notifications.js','utf8');
const event=(key='delivery:1',extra={})=>({key,category:'leads',title:'New leads assigned to you',body:'10 leads delivered',target:{tab:'my-leads'},at:'2026-10-20T10:00:00Z',read:false,...extra});
function setup(role='agent',leader=false){
 const dom=new JSDOM('<body><header class="portal-topnav"></header></body>',{url:'https://www.lldportal.com',runScripts:'outside-only',pretendToBeVisual:true}),w=dom.window;
 const requests=[],navigation=[];let list=[event()],muted=[],popups=true,now='2026-10-20T10:01:00Z',hold=null,pending=null,blocked=false;
 w.S={session:{},profile:{id:'agent-one',role,is_team_leader:leader,active:true},tab:'dashboard'};w.currentAal=()=> 'aal2';
 w.portalDialerInstance={canLeave:()=>!blocked,root:w.document.createElement('div')};w.portalDialerInstance.root.innerHTML='<button data-view="callbacks"></button><button data-view="billing"></button><button id="agentPriority"></button>';
 w.mountPortalDialer=async()=>{};w.navigatePortalTab=async tab=>{navigation.push(tab);w.S.tab=tab;};w.PC={chats:[{id:'private-chat'}]};w.CHAT={division:'mine'};w.pcList=async()=>{};w.render=()=>{};w.refreshChat=async()=>{};w.changeChatRoom=async(d,r)=>{w.CHAT.room=r;};
 const response=q=>{const all=list.filter(n=>!n.archived&&!muted.includes(n.category)),items=all.filter(n=>(!q.category||q.category==='all'||q.category===n.category)&&(!q.unread||!n.read));return JSON.parse(JSON.stringify({items:items.slice(q.offset||0,(q.offset||0)+50),total:items.length,unread:all.filter(n=>!n.read).length,as_of:now,preferences:{muted_categories:muted,toast_enabled:popups}}));};
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
 return {w,dom,$,click,requests,navigation,async poll(){poll();await tick();},setList(v){list=v;},setNow(v){now=v;},hold(a){hold=a;},release(){assert(pending);const p=pending;pending=null;p();},block(v){blocked=v;},async close(){w.PortalNotifications.reset();dom.window.close();}};
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
 console.log('PASS: all roles, inbox and unread badge, safe text, filters, persisted action payloads, preferences, active-call protection, callback/chat navigation, stable focus, polling races, account cleanup and MFA gating.');
})().catch(e=>{console.error(e);process.exitCode=1;});
