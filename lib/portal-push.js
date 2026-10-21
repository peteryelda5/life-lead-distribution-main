'use strict';
const {timingSafeEqual,ECDH,createHash}=require('node:crypto');
const webpush=require('web-push');
const ORIGIN='https://www.lldportal.com';
const BASE='https://yfuuigykpihoetgaefmu.supabase.co';
const PUBLIC_KEY='sb_publishable_6O3XhhYJrjhN_5U1cFxz2g_fYI-3uE6';
const UUID=/^[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}$/i;
const CATEGORIES=['leads','requests','calls','deals','chat','announcements','team','billing'];
const fail=(status,message)=>Object.assign(new Error(message),{status});
function settings(){
 const publicKey=process.env.WEB_PUSH_PUBLIC_KEY,privateKey=process.env.WEB_PUSH_PRIVATE_KEY;
 const enabled=process.env.WEB_PUSH_ENABLED==='true'&&(!process.env.VERCEL_ENV||process.env.VERCEL_ENV==='production');
 if(!enabled||!/^[A-Za-z0-9_-]{87}$/.test(publicKey||'')||!/^[A-Za-z0-9_-]{43}$/.test(privateKey||''))throw fail(503,'Phone notifications are not available yet. Please try again shortly.');
 return {publicKey,privateKey,subject:ORIGIN};
}
function endpoint(value){
 let u;try{u=new URL(value);}catch{throw fail(400,'Invalid notification endpoint.');}
 const host=u.hostname;
 if(typeof value!=='string'||value.length>2048||u.protocol!=='https:'||u.port||u.username||u.password||u.hash||u.pathname==='/'||
  !(host==='push.apple.com'||/^[a-z0-9-]+(?:\.[a-z0-9-]+)*\.push\.apple\.com$/.test(host)||host==='fcm.googleapis.com'||host==='updates.push.services.mozilla.com')||u.href!==value)throw fail(400,'Unsupported notification endpoint.');
 return value;
}
function subscription(value){
 const url=endpoint(value?.endpoint),p256dh=value?.keys?.p256dh,auth=value?.keys?.auth;
 if(!/^[A-Za-z0-9_-]{87}$/.test(p256dh||'')||!/^[A-Za-z0-9_-]{22}$/.test(auth||''))throw fail(400,'Invalid notification keys.');
 try{const key=Buffer.from(p256dh,'base64url');if(key.length!==65||key[0]!==4||Buffer.from(auth,'base64url').length!==16)throw Error();ECDH.convertKey(key,'prime256v1');}catch{throw fail(400,'Invalid notification keys.');}
 return {endpoint:url,keys:{p256dh,auth}};
}
async function rpc(name,body){
 const key=process.env.SUPABASE_SECRET_KEY;
 if(!/^sb_secret_[A-Za-z0-9_-]+$/.test(key||''))throw fail(503,'Phone notifications are temporarily unavailable.');
 const r=await fetch(BASE+'/rest/v1/rpc/'+name,{method:'POST',headers:{apikey:key,'Content-Type':'application/json'},body:JSON.stringify(body),signal:AbortSignal.timeout(30000)});
 const d=await r.json();
 if(!r.ok){const known=/^(Sign in again|Reset phone notifications|Phone notification device|Invalid phone notification|Wait 30 seconds|Enable phone notifications)/.test(d?.message||'');throw fail(d?.code==='42501'?403:409,known?d.message:'Could not update phone notifications. Please try again.');}
 return d;
}
async function authenticate(req){
 const auth=req.headers.authorization||'';
 if(!/^Bearer [A-Za-z0-9_.-]+$/.test(auth))throw fail(401,'Sign in to the portal first.');
 const r=await fetch(BASE+'/auth/v1/user',{headers:{apikey:PUBLIC_KEY,Authorization:auth},signal:AbortSignal.timeout(8000)});
 if(!r.ok)throw fail(401,'Your session expired. Sign in again.');
 const user=await r.json();let c;
 try{c=JSON.parse(Buffer.from(auth.slice(7).split('.')[1],'base64url'));}catch{throw fail(401,'Invalid session.');}
 if(c.sub!==user.id||!UUID.test(user.id||'')||!Number.isFinite(c.exp)||c.exp<=Date.now()/1000||c.aal!=='aal2'||!UUID.test(c.session_id||''))throw fail(403,'Complete two-step verification first.');
 return {id:user.id,session:c.session_id};
}
function payload(job){
 if(!UUID.test(job.id||''))throw fail(400,'Invalid notification.');
 return {web_push:8030,notification:{title:String(job.title||'Vivid Life Portal').slice(0,120),body:String(job.body||'Open your portal to view the update.').slice(0,180),
  navigate:ORIGIN+'/?push='+job.id,icon:ORIGIN+'/assets/vivid-life-app-192.png',tag:'vivid-'+job.id,silent:false,data:{push:job.id}}};
}
async function deliver(job){
 let status=0;
 try{
  const sub=subscription(job.subscription);
  const request=webpush.generateRequestDetails(sub,JSON.stringify(payload(job)),{vapidDetails:settings(),TTL:3600,urgency:'normal',contentEncoding:'aes128gcm',topic:createHash('sha256').update(job.id).digest('base64url').slice(0,32)});
  const r=await fetch(request.endpoint,{method:'POST',headers:request.headers,body:request.body,redirect:'error',signal:AbortSignal.timeout(8000)});
  status=r.status;await r.body?.cancel();
 }catch(e){status=e.status===400?400:0;}
 // Never log subscription URLs, key material, payloads, or provider response bodies.
 await rpc('portal_push_finish',{p_id:job.id,p_lease:job.lease,p_status:status});
 return status>=200&&status<300;
}
async function dispatch(test=null){
 settings();const jobs=await rpc('portal_push_batch',{p_test:test});
 let sent=0,failed=0;
 for(let i=0;i<jobs.length;i+=5){const results=await Promise.allSettled(jobs.slice(i,i+5).map(deliver));for(const result of results)result.status==='fulfilled'&&result.value?sent++:failed++;}
 return {processed:jobs.length,sent,failed};
}
async function action(req){
 const u=await authenticate(req),b=req.body;
 if(!b||typeof b!=='object'||Array.isArray(b)||!['subscribe','sync','disable','preferences','test','open'].includes(b.action))throw fail(400,'Invalid phone notification request.');
 let data={};
 if(b.action==='subscribe'){settings();data.subscription=subscription(b.subscription);}
 else if(b.action==='sync')data.endpoint=endpoint(b.endpoint);
 else{if(!UUID.test(b.id||''))throw fail(400,'Select a phone notification device.');data.id=b.id;}
 if(b.action==='preferences'){
  if(!Array.isArray(b.categories)||b.categories.length>8||b.categories.some(c=>!CATEGORIES.includes(c)))throw fail(400,'Invalid phone notification choices.');
  data.categories=[...new Set(b.categories)];
 }
 if(b.action==='test')settings();
 const result=await rpc('portal_push_manage',{p_user:u.id,p_session:u.session,p_action:b.action,p_data:data});
 if(b.action==='test'){const outcome=await dispatch(result.job);if(!outcome.sent)throw fail(503,'The test could not be sent. Please try again shortly.');return {sent:true};}
 return result;
}
async function handler(req,res){
 res.setHeader('Cache-Control','no-store');
 if(req.method==='GET'){try{return res.status(200).json({available:true,publicKey:settings().publicKey});}catch{return res.status(200).json({available:false});}}
 if(req.method!=='POST')return res.status(405).json({error:'Use POST.'});
 if(req.headers.origin!==ORIGIN)return res.status(403).json({error:'Open notifications from the portal.'});
 try{return res.status(200).json(await action(req));}
 catch(e){if(!e.status)console.error('portal_push_request_failed');return res.status(e.status||503).json({error:e.status?e.message:'Phone notifications are temporarily unavailable. Please try again.'});}
}
async function maintenance(req,res){
 res.setHeader('Cache-Control','no-store');if(req.method!=='GET')return res.status(405).end();
 const secret=process.env.CRON_SECRET,a=Buffer.from(req.headers.authorization||''),b=Buffer.from('Bearer '+secret);
 if(!secret||a.length!==b.length||!timingSafeEqual(a,b))return res.status(401).end();
 try{const result=await dispatch();if(result.failed)console.error('portal_push_delivery_failures',result.failed);return res.status(result.failed?503:200).json(result);}
 catch{console.error('portal_push_dispatch_failed');return res.status(503).json({error:'Phone notification delivery unavailable.'});}
}
module.exports={handler,maintenance,action,dispatch,deliver,settings,subscription,endpoint,payload};
