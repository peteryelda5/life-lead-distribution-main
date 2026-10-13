'use strict';
const assert=require('node:assert/strict'),{createHmac}=require('node:crypto');
Object.assign(process.env,{TWILIO_ACCOUNT_SID:'AC'+'a'.repeat(32),TWILIO_AUTH_TOKEN:'test-secret',TWILIO_API_KEY_SID:'SK'+'a'.repeat(32),TWILIO_API_KEY_SECRET:'test-key',TWILIO_TWIML_APP_SID:'AP'+'a'.repeat(32),TWILIO_PHONE_NUMBER:'+12025550123',TWILIO_TEST_PHONE_NUMBER:'+12025550124',SUPABASE_SECRET_KEY:'sb_secret_test',STRIPE_SECRET_KEY:'sk_live_test',DIALER_LIVE_BILLING_ENABLED:'true'});
const full=require('../lib/dialer-full'),incoming=require('../lib/dialer-incoming');
const user='11111111-1111-4111-8111-111111111111',id='22222222-2222-4222-8222-222222222222',session='33333333-3333-4333-8333-333333333333',browser='44444444-4444-4444-8444-444444444444';
const parent='CA'+'b'.repeat(32),recording='RE'+'c'.repeat(32),account=process.env.TWILIO_ACCOUNT_SID;
let online=true,foreign=false,storageFail=false,wrongRecording=false,events=[],order=[],call={id,user_id:user,livemode:true,provider_sid:account,parent_sid:parent,caller_phone:'+12025550124',dialed_phone:'+12025550123',recording_pending:true,recording_path:null};
const json=d=>new Response(JSON.stringify(d),{status:200,headers:{'content-type':'application/json'}});
global.fetch=async(url,opt={})=>{
 url=String(url);const u=new URL(url),body=opt.body&&typeof opt.body==='string'&&opt.body.startsWith('{')?JSON.parse(opt.body):null;
 if(url.includes('/auth/v1/user'))return json({id:user,email:'test@example.invalid'});
 if(url.includes('/rest/v1/profiles?'))return json([{id:user,active:true,archived:false,role:'agent'}]);
 if(url.includes('/rest/v1/rpc/')){const name=u.pathname.split('/').at(-1);events.push({name,body});
  if(name==='dialer_session_valid'||name==='dialer_entitled')return json(true);
  if(name==='dialer_get_account')return json({customer_id:'cus_test'});
  if(name==='dialer_callback_start')return json({id,identity:online?'vivid_in_test':null});
  if(name==='dialer_callback_event'||name==='dialer_callback_presence')return json({});
  if(name==='dialer_callback_list')return json({calls:[],unread:0});
  throw Error('Unknown RPC '+name);
 }
 if(url.includes('/rest/v1/dialer_numbers?'))return json([{user_id:user,livemode:true}]);
 if(url.includes('/rest/v1/dialer_callbacks?')){if(opt.method==='PATCH'){Object.assign(call,body);order.push('database');return json([call]);}return json(foreign?[]:[call]);}
 if(url.includes('api.stripe.com/v1/subscriptions'))return json({data:[],has_more:false});
 if(url.includes('api.twilio.com')&&url.includes('/Recordings/')){
  if(opt.method==='DELETE'){assert(call.recording_path,'Provider copy deleted before private archive');order.push('delete-provider');return new Response(null,{status:204});}
  if(url.endsWith('.json'))return json({call_sid:wrongRecording?'CA'+'e'.repeat(32):parent,account_sid:account,source:'RecordVerb',status:'completed'});
  assert(url.endsWith(recording+'.mp3'));assert(opt.headers.Authorization.startsWith('Basic '));order.push('download');return new Response('test audio',{headers:{'content-type':'audio/mpeg'}});
 }
 if(url.includes('/storage/v1/object/')&&url.includes('/dialer-voicemails/')){assert(opt.headers.apikey===process.env.SUPABASE_SECRET_KEY);if(opt.method==='POST'){order.push('private-upload');return new Response('{}',{status:storageFail?503:200});}assert(url.includes('/object/authenticated/dialer-voicemails/'));return new Response('test audio',{headers:{'content-type':'audio/mpeg'}});}
 throw Error('Unexpected fetch '+url);
};
const response=()=>({headers:{},setHeader(k,v){this.headers[k]=v;},status(n){this.code=n;return this;},send(v){this.data=v;return this;},json(v){this.data=v;return this;},end(){return this;}});
function signed(path,body,method='POST',rewritten){let url=path,raw=full.ORIGIN+path;if(method==='GET'){url+='?'+new URLSearchParams(body);raw=full.ORIGIN+url;}else for(const key of Object.keys(body).sort())raw+=key+body[key];return {method,url:rewritten?url.replace(path,rewritten):url,body:method==='POST'?body:undefined,headers:{'content-type':'application/x-www-form-urlencoded','x-twilio-signature':createHmac('sha1','test-secret').update(raw).digest('base64')}};}
const jwt=aal=>'x.'+Buffer.from(JSON.stringify({sub:user,aal,exp:Math.floor(Date.now()/1000)+300,session_id:session})).toString('base64url')+'.x';
const authenticated=body=>({method:'POST',headers:{origin:full.ORIGIN,authorization:'Bearer '+jwt('aal2')},body});
(async()=>{
 const body={AccountSid:account,CallSid:parent,From:'+12025550124',To:'+12025550123'};let res=response();
 await incoming.incoming(signed('/dialer-inbound.xml',body),res);assert.equal(res.code,200);assert.match(res.data,/<Client/);assert.match(res.data,/timeout="25"/);assert.match(res.data,/CallbackId/);assert(!res.data.includes('unavailable'));
 res=response();await incoming.incoming(signed('/dialer-inbound.xml',body,'GET','/api/dialer/incoming'),res);assert.equal(res.code,200,'Legacy GET signature survives the rewrite');
 res=response();await incoming.incoming({...signed('/dialer-inbound.xml',body),headers:{'x-twilio-signature':'bad'}},res);assert.equal(res.code,403);
 online=false;res=response();await incoming.incoming(signed('/api/dialer/incoming',body),res);assert.match(res.data,/<Record maxLength="120"/);assert(!res.data.includes('<Client'));assert(res.data.includes('after the tone'));
 res=response();await incoming.action(signed('/api/dialer/incoming-action',{...body,DialCallStatus:'no-answer'}),res);assert.match(res.data,/<Record/);
 res=response();await incoming.action(signed('/api/dialer/incoming-action',{...body,DialCallStatus:'completed',DialCallDuration:'25'}),res);assert(!res.data.includes('<Record'));assert.equal(events.at(-1).body.p_event,'completed');
 const recordBody={...body,RecordingSid:recording,RecordingStatus:'completed',RecordingSource:'RecordVerb',RecordingDuration:'9',RecordingUrl:'http://127.0.0.1/ignored'};
 storageFail=true;res=response();await incoming.recording(signed('/api/dialer/incoming-recording',recordBody),res);assert.equal(res.code,503);assert(!order.includes('delete-provider'));
 storageFail=false;wrongRecording=true;res=response();await incoming.recording(signed('/api/dialer/incoming-recording',recordBody),res);assert.equal(res.code,403);wrongRecording=false;
 res=response();await incoming.recording(signed('/api/dialer/incoming-recording',recordBody),res);assert.equal(res.code,204);assert.equal(call.status,'voicemail');assert.equal(call.provider_copy_removed,true);assert(order.indexOf('private-upload')<order.indexOf('delete-provider'));
 const downloads=order.filter(s=>s==='download').length;res=response();await incoming.recording(signed('/api/dialer/incoming-recording',recordBody),res);assert.equal(res.code,204);assert.equal(order.filter(s=>s==='download').length,downloads,'Duplicate webhook redownloaded archive');
 const callbacks=require('../api/dialer/callbacks');res=response();await callbacks(authenticated({action:'token',browserId:browser}),res);assert.equal(res.code,200);const claims=JSON.parse(Buffer.from(res.data.token.split('.')[1],'base64url'));assert.equal(claims.grants.voice.incoming.allow,true);assert.equal(claims.grants.voice.outgoing,undefined);assert(claims.grants.identity.includes(browser.replace(/-/g,'')));
 res=response();await callbacks(authenticated({action:'list',userId:'another-user'}),res);assert.equal(events.at(-1).body.p_user,user);
 res=response();await callbacks({...authenticated({action:'list'}),headers:{origin:full.ORIGIN,authorization:'Bearer '+jwt('aal1')}},res);assert.equal(res.code,403);
 res=response();await require('../api/dialer/callback-audio')(authenticated({id}),res);assert.equal(res.code,200);assert.equal(res.headers['Content-Type'],'audio/mpeg');
 foreign=true;res=response();await require('../api/dialer/callback-audio')(authenticated({id}),res);assert.equal(res.code,404);res=response();await incoming.action(signed('/api/dialer/incoming-action',{...body,DialCallStatus:'no-answer'}),res);assert.equal(res.code,403);
 console.log('PASS: signed GET/POST routes, online ringing, missed-call voicemail, completed-call hangup, private archival before provider cleanup, recording ownership, replay, incoming-only tokens, MFA and audio ownership.');
})().catch(e=>{console.error(e);process.exitCode=1;});
