'use strict';
const assert=require('node:assert/strict'),{createHmac}=require('node:crypto');
Object.assign(process.env,{TWILIO_ACCOUNT_SID:'AC'+'a'.repeat(32),TWILIO_AUTH_TOKEN:'test-secret',TWILIO_API_KEY_SID:'SK'+'a'.repeat(32),TWILIO_API_KEY_SECRET:'test-key',TWILIO_TWIML_APP_SID:'AP'+'a'.repeat(32),TWILIO_PHONE_NUMBER:'+12025550123',TWILIO_TEST_PHONE_NUMBER:'+12025550124',SUPABASE_SECRET_KEY:'sb_secret_test',STRIPE_SECRET_KEY:'sk_live_test',DIALER_LIVE_BILLING_ENABLED:'true'});
const full=require('../lib/dialer-full'),parallel=require('../lib/dialer-parallel'),owner=full.MASTER;
const id='11111111-1111-4111-8111-111111111111',authSession='22222222-2222-4222-8222-222222222222',agent='CA'+'b'.repeat(32),account=process.env.TWILIO_ACCOUNT_SID;
let s,legs,records,requests=[],rateCountry='US',rate='0.014',winner=null,createUncertain=false,creates=0;
function reset(){s={id,user_id:owner,session_id:authSession,provider_sid:account,caller_id:'+12025550123',state:'prepared',heartbeat_at:new Date().toISOString(),expires_at:new Date(Date.now()+240000).toISOString(),agent_sid:agent};legs=[1,2,3].map(n=>({id:'33333333-3333-4333-8333-'+String(n).padStart(12,'0'),session_id:id,position:n,phone:'+1202555012'+(n+3),rate:.014,state:'prepared',terminal:false,duration_seconds:0}));records=new Map([[agent,{sid:agent,account_sid:account,from:'client:vivid_parallel_'+id.replaceAll('-',''),status:'in-progress',duration:'10'}]]);winner=null;creates=0;createUncertain=false;requests=[];}
const json=d=>new Response(JSON.stringify(d),{headers:{'content-type':'application/json'}});
global.fetch=async(url,opt={})=>{const u=new URL(url),body=opt.body&&String(opt.body).startsWith('{')?JSON.parse(opt.body):null;requests.push({url,method:opt.method,body});
 if(u.hostname==='pricing.twilio.com')return json({destination_number:decodeURIComponent(u.pathname.split('/').at(-1)),iso_country:rateCountry,price_unit:'USD',outbound_call_prices:[{current_price:rate}]});
 if(u.pathname.endsWith('/rpc/dialer_parallel_prepare'))return json(id);
 if(u.pathname.endsWith('/rpc/dialer_parallel_event')){const l=legs.find(l=>l.id===body.p_leg);let result='ignored';
  if(body.p_event==='agent'){s.agent_sid=body.p_sid;result='agent';}
  if(body.p_event==='ready'){s.state='ready';result='ready';}
  if(body.p_event==='launch'&&s.state==='ready'){s.state='dialing';result='launch';}
  if(body.p_event==='claim'&&l.state==='prepared'&&s.state==='dialing'&&!winner){l.state='creating';result='create';}
  if(body.p_event==='bind'){l.provider_sid=body.p_sid;if(l.state==='creating')l.state='queued';result='bound';}
  if(body.p_event==='answer'){l.provider_sid=body.p_sid;l.answer=body.p_value;if(s.state==='stopping'||s.state==='complete')result='stopped';else if(body.p_value==='human'){if(!winner||winner===l.id){s.winner_id=winner=l.id;s.state='connected';l.outcome='connected';result='winner';}else{l.outcome='second_answer';result='overflow';}}else{l.outcome=body.p_value;result='hangup';}}
  if(body.p_event==='status'){l.provider_sid=body.p_sid;l.state=body.p_value;l.duration_seconds=body.p_seconds;l.terminal=['completed','canceled','failed','no-answer','busy'].includes(body.p_value);result='status';}
  if(body.p_event==='stop'){s.state='stopping';for(const l of legs)if(l.state==='prepared'){l.state='canceled';l.terminal=true;}result='stopped';}
  if(body.p_event==='complete'){s.state='complete';result='complete';}
  return json({result});
 }
 if(u.pathname.endsWith('/dialer_parallel_sessions')){if(opt.method==='PATCH'){Object.assign(s,body);return json([s]);}if(u.searchParams.get('select')==='reserved_cents')return json([{reserved_cents:50}]);return json([{...s}]);}
 if(u.pathname.endsWith('/dialer_parallel_legs')){if(opt.method==='PATCH'){const l=legs.find(l=>'eq.'+l.id===u.searchParams.get('id'));Object.assign(l,body);return json([l]);}return json(legs.map(l=>({...l})));}
 if(u.pathname.endsWith('/dialer_numbers'))return json([{phone:s.caller_id}]);
 if(u.pathname.endsWith('/master_dialer_numbers'))return json([]);
 if(u.hostname==='api.twilio.com'){
  if(u.pathname.endsWith('/Calls.json')&&opt.method==='POST'){creates++;const p=new URLSearchParams(opt.body);assert.deepEqual(p.getAll('StatusCallbackEvent'),['initiated','ringing','answered','completed']);assert.equal(p.get('MachineDetection'),'Enable');assert.equal(p.get('AsyncAmd'),'false');assert.equal(p.get('TimeLimit'),'90');assert.equal(p.get('Timeout'),'20');if(createUncertain)throw Error('Provider timeout');const sid='CA'+String(creates).padStart(32,'0'),d={sid,account_sid:account,to:p.get('To'),from:p.get('From'),status:'queued',duration:'0',price:null};records.set(sid,d);return json(d);}
  const sid=u.pathname.split('/').at(-1).replace('.json',''),d=records.get(sid);assert(d,'Unowned provider call read');if(opt.method==='POST'){const p=new URLSearchParams(opt.body);d.status=p.get('Status');}return json(d);
 }
 throw Error('Unexpected fetch '+url);
};
const response=()=>({setHeader(){},status(n){this.code=n;return this;},send(d){this.data=d;return this;},json(d){this.data=d;return this;},end(){return this;}});
function signed(path,body){let raw=full.ORIGIN+path;for(const k of Object.keys(body).sort())raw+=k+body[k];return {method:'POST',url:path,body,headers:{'content-type':'application/x-www-form-urlencoded','x-twilio-signature':createHmac('sha1','test-secret').update(raw).digest('base64')}};}
function webhook(kind,l,extra={}){const path='/api/dialer/parallel-events?'+new URLSearchParams({id,kind,leg:l.id});return signed(path,{AccountSid:account,CallSid:l.provider_sid,To:l.phone,From:s.caller_id,...extra});}
(async()=>{reset();assert.equal(parallel.normalize('(202) 555-0124'),'+12025550124');assert.throws(()=>parallel.normalize('911'));const c=full.config(),t=parallel.tokens(s,c);assert.equal(parallel.grant(t.callGrant,c).id,id);assert.throws(()=>parallel.grant(t.callGrant+'x',c));
 await assert.rejects(parallel.action({body:{action:'options'}},{id:'other',live:true}),/owner-only/);
 await assert.rejects(parallel.action({body:{action:'prepare',id,callerId:s.caller_id,phones:[legs[0].phone],testPhonesConfirmed:false,acceptCharges:true}},{id:owner,sessionId:authSession,live:true}),/Confirm/);
 rateCountry='CA';await assert.rejects(parallel.price(legs[0].phone,s.caller_id,c),/standard-rate US/);rateCountry='US';rate='.09';await assert.rejects(parallel.price(legs[0].phone,s.caller_id,c),/standard-rate US/);rate='0.014';assert.equal(await parallel.price(legs[0].phone,s.caller_id,c),.014);
 let res=response();await parallel.voice(signed('/api/dialer/voice',{AccountSid:account,CallSid:agent,From:'client:vivid_parallel_'+id.replaceAll('-',''),ParallelGrant:t.callGrant}),res);assert.equal(res.code,200);assert.match(res.data,/<Conference/);assert.match(res.data,/maxParticipants="2"/);assert.match(res.data,/timeLimit="120"/);
 res=response();await parallel.events({method:'POST',url:'/api/dialer/parallel-events',body:{},headers:{}},res);assert.equal(res.code,403);
 s.state='ready';await parallel.launch(await parallel.get(id));assert.equal(creates,3);await parallel.launch(await parallel.get(id));assert.equal(creates,3,'Repeated launch created extra calls');
 res=response();await parallel.events(webhook('answer',legs[0],{AnsweredBy:'machine_start'}),res);assert.equal(res.code,200);assert(!res.data.includes('<Conference'));
 res=response();await parallel.events(webhook('answer',legs[1],{AnsweredBy:'human'}),res);assert.match(res.data,/<Conference/);assert.equal(s.winner_id,legs[1].id);
 res=response();await parallel.events(webhook('answer',legs[2],{AnsweredBy:'human'}),res);assert(!res.data.includes('<Conference'));assert.match(res.data,/Another test phone/);
 const wrong=webhook('answer',legs[1],{AnsweredBy:'human',To:'+12025550999'});res=response();await parallel.events(wrong,res);assert.equal(res.code,403);
 await parallel.stop(await parallel.get(id));assert.equal(s.state,'complete');for(const call of records.values())assert(['completed','canceled'].includes(call.status));
 reset();s.state='ready';createUncertain=true;await assert.rejects(parallel.launch(await parallel.get(id)),/did not confirm/);assert.equal(creates,1,'Uncertain creation retried or placed additional calls');assert.equal(s.state,'stopping');
 console.log('PASS: owner gating, consent, rate limits, signed grants/webhooks, three distinct bounded calls, replay protection, human/voicemail/second-human routing, stop-all and ambiguous creation safety.');
})().catch(e=>{console.error(e);process.exitCode=1;});
