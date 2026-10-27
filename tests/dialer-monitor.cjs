'use strict';
const assert=require('node:assert/strict');
Object.assign(process.env,{TWILIO_ACCOUNT_SID:'AC'+'a'.repeat(32),TWILIO_AUTH_TOKEN:'test',TWILIO_API_KEY_SID:'SK'+'a'.repeat(32),TWILIO_API_KEY_SECRET:'test',TWILIO_TWIML_APP_SID:'AP'+'a'.repeat(32),TWILIO_PHONE_NUMBER:'+12025550123',TWILIO_TEST_PHONE_NUMBER:'+12025550124',SUPABASE_SECRET_KEY:'sb_secret_test',STRIPE_SECRET_KEY:'sk_live_test',DIALER_LIVE_BILLING_ENABLED:'true'});
const full=require('../lib/dialer-full'),parallel=require('../lib/dialer-parallel'),incoming=require('../lib/dialer-incoming'),provider=require('../lib/dialer-at-cost-provider');
const id='11111111-1111-4111-8111-111111111111',power='22222222-2222-4222-8222-222222222222',actor='33333333-3333-4333-8333-333333333333',session='44444444-4444-4444-8444-444444444444',sid='CA'+'b'.repeat(32),account=process.env.TWILIO_ACCOUNT_SID;
let calls=[],signature=true,denied=false;full.rpc=async(name,args)=>{calls.push(args);if(denied)throw Error('Access denied');if(args.p_action==='cleanup')return [{id,power_id:power,call_sid:sid}];return {id,power_id:power,call_sid:args.p_action==='prepare'?null:sid}};
parallel.get=async()=>({id:power,provider_sid:account});parallel.storedContext=async()=>full.config();parallel.callProvider=async(s,path,body)=>{calls.push({path,body});};provider.callbackContext=async()=>full.config();incoming.validSignature=()=>signature;
const monitor=require('../lib/dialer-monitor');const u={id:actor,sessionId:session,live:true};
const response=()=>({setHeader(){},status(n){this.code=n;return this;},send(s){this.body=s;return this;}});
(async()=>{
 const d=await monitor.action({body:{action:'prepare',powerId:power,actor:'forged'}},u);const jwt=JSON.parse(Buffer.from(d.token.split('.')[1],'base64url'));assert.equal(jwt.sub,account);assert.equal(jwt.grants.identity,'vivid_monitor_'+id.replaceAll('-',''));assert.equal(calls[0].p_actor,actor);
 const req={method:'POST',body:{AccountSid:account,MonitorGrant:id,From:'client:'+jwt.grants.identity,CallSid:sid}};let r=response();await monitor.voice(req,r);assert.equal(r.code,200);for(const flag of ['muted="true"','endConferenceOnExit="false"','startConferenceOnEnter="false"','beep="false"','record="do-not-record"'])assert(r.body.includes(flag));
 signature=false;r=response();await monitor.voice(req,r);assert.equal(r.code,403);signature=true;r=response();await monitor.voice({...req,body:{...req.body,From:'client:wrong'}},r);assert.equal(r.code,403);
 calls=[];await monitor.action({body:{action:'stop',id}},u);assert.equal(calls.find(c=>c.path).path,'Calls/'+sid+'.json');assert(!calls.some(c=>c.path?.includes('Conferences')));assert.equal(calls.at(-1).p_action,'finish');
 calls=[];await monitor.maintenance();assert(calls.some(c=>c.path==='Calls/'+sid+'.json'));
 denied=true;await assert.rejects(()=>monitor.action({body:{action:'prepare',powerId:power}},u));
 console.log('PASS: server-owned identity, provider account, signed callback, muted non-ending listener, stop only listener, stale cleanup, denied scope');
})().catch(e=>{console.error(e);process.exit(1)});
