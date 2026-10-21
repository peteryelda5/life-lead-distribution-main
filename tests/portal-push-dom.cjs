'use strict';
const fs=require('fs'),assert=require('node:assert/strict'),vm=require('vm'),{JSDOM}=require('jsdom');
const source=fs.readFileSync(__dirname+'/../portal-push.js','utf8');
const id='11111111-1111-4111-8111-111111111111',deviceId='22222222-2222-4222-8222-222222222222',pushId='33333333-3333-4333-8333-333333333333';
const tick=async()=>{for(let i=0;i<12;i++)await new Promise(r=>setImmediate(r));};
function setup({installed=true,permission='default',url='https://www.lldportal.com/',existing=false}={}){
 const dom=new JSDOM('<body><button id="pnPhone">Phone alerts</button></body>',{url,runScripts:'outside-only',pretendToBeVisual:true}),w=dom.window;
 let prompts=0,unsubscribed=0,registered=0,subscribed=0,currentSub=existing?subscription():null,serverDevice=existing?{id:deviceId,enabled:true,categories:['deals','chat','leads']}:null,blocked=false;
 const actions=[],opened=[];let workerMessage;
 function subscription(){return {endpoint:'https://web.push.apple.com/fixture',toJSON(){return {endpoint:this.endpoint,keys:{p256dh:'A'.repeat(87),auth:'A'.repeat(22)}};},async unsubscribe(){unsubscribed++;currentSub=null;return true;}};}
 Object.defineProperty(w,'isSecureContext',{value:true});Object.defineProperty(w.navigator,'userAgent',{value:'iPhone'});Object.defineProperty(w.navigator,'standalone',{value:installed});
 w.matchMedia=()=>({matches:installed});w.PushManager=function(){};w.Notification={permission,requestPermission(){prompts++;w.Notification.permission=permission==='denied'?'denied':'granted';return Promise.resolve(w.Notification.permission);}};
 const reg={pushManager:{async getSubscription(){return currentSub;},async subscribe(){subscribed++;return currentSub=subscription();}},async getNotifications(){return [];}};
 Object.defineProperty(w.navigator,'serviceWorker',{value:{async register(){registered++;return reg;},ready:Promise.resolve(reg),async getRegistration(){return reg;},addEventListener(type,fn){workerMessage=fn;}}});
 w.S={profile:{id,active:true},session:{access_token:'e30.'+Buffer.from(JSON.stringify({session_id:'fixture'})).toString('base64url')+'.x'},mfaMode:null};w.currentAal=()=> 'aal2';w.sessionExpiresWithin=()=>false;
 w.portalDialerInstance={canLeave:()=>!blocked};w.PortalNotifications={async openItem(n){opened.push(n);return true;},open(){opened.push('inbox');}};
 w.fetch=async(url,opt={})=>{if(opt.method!=='POST')return {ok:true,json:async()=>({available:true,publicKey:'B'.repeat(87)})};const b=JSON.parse(opt.body);actions.push(b);
  let result;if(b.action==='subscribe')result={device:serverDevice={id:deviceId,enabled:true,categories:['deals','chat','leads']}};
  else if(b.action==='disable')result={device:serverDevice=null};else if(b.action==='preferences'){serverDevice.categories=b.categories;result={device:serverDevice};}
  else if(b.action==='test')result={sent:true};else if(b.action==='open')result={item:{key:'deal:fixture',target:{tab:'leaderboard'}}};else result={device:serverDevice};return {ok:true,json:async()=>result};};
 w.eval(source);
 return {w,dom,actions,opened,get prompts(){return prompts;},get unsubscribed(){return unsubscribed;},get registered(){return registered;},get subscribed(){return subscribed;},block(v){blocked=v;},message(value){workerMessage({data:value});},async click(action){w.document.querySelector('[data-push-action="'+action+'"]').click();await tick();},close(){w.PortalPush.reset();w.close();}};
}
(async()=>{
 const safari=setup({installed:false});try{safari.w.PortalPush.open();await tick();assert.match(safari.w.document.body.textContent,/Add Vivid Life to your Home Screen/);assert.equal(safari.registered,0);assert.equal(safari.prompts,0);}finally{safari.close();}
 const h=setup();try{
  h.w.PortalPush.open();await tick();assert.equal(h.prompts,0);assert(h.registered>0);assert.equal(h.w.document.querySelector('[data-push-action=enable]').disabled,false);
  await h.click('enable');assert.equal(h.prompts,1);assert.equal(h.subscribed,1);assert(h.w.document.querySelector('[value=deals]').checked);assert(h.w.document.querySelector('[value=chat]').checked);
  h.w.document.querySelector('[value=chat]').checked=false;await h.click('preferences');assert.deepEqual(h.actions.at(-1).categories,['deals','leads']);
  await h.click('test');assert.equal(h.actions.at(-1).id,deviceId);assert.match(h.w.document.querySelector('.pp-status').textContent,/Test sent/);
  await h.click('disable');assert.equal(h.unsubscribed,1);assert(h.w.document.querySelector('[data-push-action=enable]'));
 }finally{h.close();}
 const denied=setup({permission:'denied'});try{denied.w.PortalPush.open();await tick();await denied.click('enable');assert.equal(denied.subscribed,0);assert(!denied.actions.some(a=>a.action==='subscribe'));assert.match(denied.w.document.querySelector('.pp-status').textContent,/Settings/);}finally{denied.close();}
 const link=setup({url:'https://www.lldportal.com/?push='+pushId});try{link.block(true);link.w.PortalPush.sync();await tick();assert.equal(link.opened.length,0);link.block(false);link.w.PortalPush.sync();await tick();assert.equal(link.opened[0].target.tab,'leaderboard');assert.equal(new URL(link.w.location.href).search,'');}finally{link.close();}
 const logout=setup({existing:true});try{logout.w.PortalPush.sync();await tick();await logout.w.PortalPush.beforeLogout();assert(logout.actions.some(a=>a.action==='disable'));assert.equal(logout.unsubscribed,1);assert.equal(logout.w.localStorage.getItem('vivid_phone_notifications'),null);}finally{logout.close();}
 const swap=setup({existing:true});try{swap.w.localStorage.setItem('vivid_phone_notifications',JSON.stringify({owner:'other-user',id:deviceId}));swap.w.PortalPush.sync();await tick();assert.equal(swap.unsubscribed,1);assert(!swap.actions.some(a=>a.action==='sync'));assert.equal(swap.prompts,0);}finally{swap.close();}
 // Saving sends a wake without enrolling the sender for phone notifications.
 const sender=setup({installed:false});try{
  const w=sender.w,requests=[];let throttled=true;
  w.fetch=async(url,opt)=>{requests.push({url,opt,body:JSON.parse(opt.body)});const result=throttled?{accepted:false,retry_after_ms:100}:{accepted:true};throttled=false;return {ok:true,json:async()=>result};};
  w.PortalPush.afterWrite('/rest/v1/rpc/portal_collaboration',{method:'POST',body:{p_action:'list'}});
  w.PortalPush.afterWrite('/rest/v1/rpc/chat_send_social',{method:'GET'});
  await new Promise(r=>setTimeout(r,180));assert.equal(requests.length,0);
  w.PortalPush.afterWrite('/rest/v1/rpc/chat_send_social',{method:'POST'});
  await new Promise(r=>setTimeout(r,380));assert.equal(requests.length,2);assert.equal(requests[0].opt.keepalive,true);assert.deepEqual(requests[0].body,{action:'wake'});assert.equal(sender.registered,0);assert.equal(sender.prompts,0);
  for(const [path,body] of [['close_lead',{}],['chat_standalone_deal',{}],['portal_collaboration',{p_action:'send'}]]){
   w.PortalPush.afterWrite('/rest/v1/rpc/'+path,{method:'POST',body});await new Promise(r=>setTimeout(r,180));
  }
  assert.equal(requests.length,5);
  w.PortalPush.afterWrite('/rest/v1/rpc/chat_send_social',{method:'POST'});w.S.profile.id='different-account';await new Promise(r=>setTimeout(r,180));assert.equal(requests.length,5);
  // Exercise the actual shared API success/failure boundary, including retries.
  const appSource=fs.readFileSync(__dirname+'/../portal-app.js','utf8');
  const rawSource=appSource.slice(appSource.indexOf('async function raw('),appSource.indexOf('let refreshPromise=null;'));
  let wakes=0,ok=false;
  const context={portalSessionEpoch:0,KEY:'public-fixture',BASE:'https://fixture.invalid',S:{session:{access_token:'fixture'}},window:{PortalPush:{afterWrite(){wakes++;}}},portalFetch:async()=>({ok,status:ok?200:400,text:async()=>JSON.stringify(ok?{saved:true}:{message:'Save failed'})})};
  vm.createContext(context);vm.runInContext(rawSource,context);
  await assert.rejects(context.raw('/rest/v1/rpc/close_lead',{method:'POST'}),/Save failed/);assert.equal(wakes,0);
  ok=true;await context.raw('/rest/v1/rpc/close_lead',{method:'POST'});assert.equal(wakes,1);
 }finally{sender.close();}
 // Worker always displays a visible notification; external URLs cannot be opened.
 const handlers={},shown=[],windows=[],messages=[];let wait;
 const self={location:{origin:'https://www.lldportal.com'},addEventListener(k,f){handlers[k]=f;},registration:{async showNotification(title,opt){shown.push({title,opt});}},clients:{async matchAll(){return [];},async openWindow(url){windows.push(url);}}};
 vm.runInNewContext(fs.readFileSync(__dirname+'/../portal-push-sw.js','utf8'),{self,URL});
 handlers.push({data:{json(){return {notification:{title:'New deal',body:'An agent closed a deal',navigate:'https://evil.test/',tag:'one'}};}},waitUntil(p){wait=p;}});await wait;assert.equal(shown[0].opt.data.url,'https://www.lldportal.com/');
 handlers.notificationclick({notification:{close(){},data:{url:'https://www.lldportal.com/?push='+pushId}},waitUntil(p){wait=p;}});await wait;assert.equal(windows[0],'https://www.lldportal.com/?push='+pushId);
 self.clients.matchAll=async()=>[{url:'https://www.lldportal.com/',async focus(){},postMessage(v){messages.push(v);}}];
 handlers.notificationclick({notification:{close(){},data:{url:'https://www.lldportal.com/?push='+pushId}},waitUntil(p){wait=p;}});await wait;assert.equal(messages[0].type,'vivid-push-open');assert.equal(windows.length,1);
 console.log('PASS: iPhone install instructions, explicit permission gesture, defaults, preferences/test/disable, denied permission, safe deep links, active-call preservation, logout/account switch, and worker display/click behavior.');
})().catch(e=>{console.error(e);process.exitCode=1;});
