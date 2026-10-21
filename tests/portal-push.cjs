'use strict';
const assert=require('node:assert/strict'),crypto=require('node:crypto'),webpush=require('web-push');
const keys=webpush.generateVAPIDKeys();
Object.assign(process.env,{WEB_PUSH_ENABLED:'true',WEB_PUSH_PUBLIC_KEY:keys.publicKey,WEB_PUSH_PRIVATE_KEY:keys.privateKey,SUPABASE_SECRET_KEY:'sb_secret_fixture',CRON_SECRET:'fixture-cron',VERCEL_ENV:'production'});
const push=require('../lib/portal-push');
const u='11111111-1111-4111-8111-111111111111',session='22222222-2222-4222-8222-222222222222',id='33333333-3333-4333-8333-333333333333',lease='44444444-4444-4444-8444-444444444444';
const client=crypto.createECDH('prime256v1');client.generateKeys();
const sub={endpoint:'https://web.push.apple.com/fixture',keys:{p256dh:client.getPublicKey().toString('base64url'),auth:crypto.randomBytes(16).toString('base64url')}};
const token=aal=>'e30.'+Buffer.from(JSON.stringify({sub:u,session_id:session,aal,exp:Date.now()/1000+3600})).toString('base64url')+'.fixture';
const job={id,lease,category:'chat',title:'New chat message',body:'Open Vivid Life Portal to view your update.',subscription:sub};
let calls=[],providerStatus=201,manageResult={device:{id,enabled:true,categories:['deals','chat']}};
const json=(value,status=200)=>({ok:status>=200&&status<300,status,json:async()=>value,body:{cancel:async()=>{}}});
global.fetch=async(url,opt)=>{
 calls.push({url,opt});
 if(url.endsWith('/auth/v1/user'))return json({id:u});
 if(url.endsWith('/portal_push_manage'))return json(manageResult);
 if(url.endsWith('/portal_push_batch'))return json([job]);
 if(url.endsWith('/portal_push_finish'))return json(true);
 if(url===sub.endpoint){assert.equal(opt.redirect,'error');assert.equal(opt.headers['Content-Encoding'],'aes128gcm');assert(Buffer.isBuffer(opt.body));assert(!opt.body.includes(Buffer.from(job.body)));assert.match(opt.headers.Authorization,/vapid /);return json({},providerStatus);}
 throw Error('Unexpected request');
};
const req=(body={},aal='aal2')=>({method:'POST',headers:{origin:'https://www.lldportal.com',authorization:'Bearer '+token(aal)},body});
async function run(request,handler=push.handler){const res={headers:{},setHeader(k,v){this.headers[k]=v;},status(s){this.code=s;return this;},json(v){this.body=v;return this;},end(){return this;}};await handler(request,res);return res;}
(async()=>{
 for(const endpoint of ['http://web.push.apple.com/x','https://web.push.apple.com.evil.test/x','https://127.0.0.1/x','https://web.push.apple.com@evil.test/x','https://web.push.apple.com:8443/x','https://web.push.apple.com/x#fragment','https://example.com/x'])assert.throws(()=>push.subscription({...sub,endpoint}),/endpoint/);
 assert.throws(()=>push.subscription({...sub,keys:{...sub.keys,p256dh:'A'.repeat(87)}}),/keys/);
 assert.deepEqual(push.subscription({...sub,userId:'untrusted'}),sub);
 let r=await run({method:'GET',headers:{}});assert.equal(r.body.publicKey,keys.publicKey);assert(!JSON.stringify(r.body).includes(keys.privateKey));
 process.env.VERCEL_ENV='preview';r=await run({method:'GET',headers:{}});assert.equal(r.body.available,false);process.env.VERCEL_ENV='production';
 r=await run({...req(),method:'DELETE'});assert.equal(r.code,405);
 r=await run({...req(),headers:{origin:'https://evil.test'}});assert.equal(r.code,403);
 r=await run({...req(),headers:{origin:'https://www.lldportal.com'}});assert.equal(r.code,401);
 r=await run(req({action:'subscribe',subscription:sub},'aal1'));assert.equal(r.code,403);
 r=await run(req({action:'subscribe',subscription:sub,userId:lease,sessionId:lease}));assert.equal(r.code,200);
 const body=JSON.parse(calls.findLast(c=>c.url.endsWith('/portal_push_manage')).opt.body);assert.equal(body.p_user,u);assert.equal(body.p_session,session);assert.equal(body.p_data.userId,undefined);
 r=await run(req({action:'preferences',id,categories:['deals','bad']}));assert.equal(r.code,400);
 const before=calls.length;assert.equal(await push.deliver(job),true);assert.equal(calls.length,before+2);assert.equal(JSON.parse(calls.at(-1).opt.body).p_status,201);
 providerStatus=410;assert.equal(await push.deliver(job),false);assert.equal(JSON.parse(calls.at(-1).opt.body).p_status,410);
 providerStatus=302;assert.equal(await push.deliver(job),false);assert.equal(JSON.parse(calls.at(-1).opt.body).p_status,302);
 providerStatus=201;manageResult={job:id};r=await run(req({action:'test',id}));assert.equal(r.code,200);assert.equal(r.body.sent,true);assert.equal(JSON.parse(calls.findLast(c=>c.url.endsWith('/portal_push_batch')).opt.body).p_test,id);
 r=await run({method:'GET',headers:{}},push.maintenance);assert.equal(r.code,401);
 r=await run({method:'GET',headers:{authorization:'Bearer fixture-cron'}},push.maintenance);assert.equal(r.code,200);assert.equal(r.body.sent,1);
 const p=push.payload(job);assert.equal(p.web_push,8030);assert.equal(p.notification.navigate,'https://www.lldportal.com/?push='+id);assert.equal(p.notification.data.push,id);
 console.log('PASS: authenticated AAL2 ownership, no billing dependency, opt-in validation, endpoint SSRF restrictions, encryption, declarative payload, no redirects, acknowledgements, per-device tests, and protected cron. No external notifications sent.');
})().catch(e=>{console.error(e);process.exitCode=1;});
