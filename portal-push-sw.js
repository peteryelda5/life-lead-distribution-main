/* Notification-only worker: no page, API, session, or lead data caching. */
'use strict';
self.addEventListener('install',event=>event.waitUntil(self.skipWaiting()));
self.addEventListener('activate',event=>event.waitUntil(self.clients.claim()));
function destination(value){
 try{const u=new URL(value,self.location.origin);if(u.origin===self.location.origin&&u.pathname==='/'&&/^[a-f0-9-]{36}$/i.test(u.searchParams.get('push')||''))return u.href;}catch{}
 return self.location.origin+'/';
}
self.addEventListener('push',event=>{
 let n;try{n=event.data.json().notification;}catch{}
 n=n&&typeof n==='object'?n:{};
 const navigate=destination(n.navigate);
 event.waitUntil(self.registration.showNotification(String(n.title||'Vivid Life Portal').slice(0,120),{
  body:String(n.body||'Open the portal to see your new notification.').slice(0,180),icon:'/assets/vivid-life-app-192.png',
  tag:typeof n.tag==='string'?n.tag.slice(0,100):'vivid-update',data:{url:navigate},silent:false
 }));
});
self.addEventListener('notificationclick',event=>{
 event.notification.close();const url=destination(event.notification.data?.url);
 event.waitUntil((async()=>{
  const clients=await self.clients.matchAll({type:'window',includeUncontrolled:true});
  const client=clients.find(c=>new URL(c.url).origin===self.location.origin);
  if(client){await client.focus();client.postMessage({type:'vivid-push-open',url});return;}
  await self.clients.openWindow(url);
 })());
});
