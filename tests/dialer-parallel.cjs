'use strict';
const assert=require('node:assert/strict'),{createHmac}=require('node:crypto');
Object.assign(process.env,{TWILIO_ACCOUNT_SID:'AC'+'a'.repeat(32),TWILIO_AUTH_TOKEN:'test-secret',TWILIO_API_KEY_SID:'SK'+'a'.repeat(32),TWILIO_API_KEY_SECRET:'test-key',TWILIO_TWIML_APP_SID:'AP'+'a'.repeat(32),TWILIO_PHONE_NUMBER:'+12025550123',TWILIO_TEST_PHONE_NUMBER:'+12025550124',SUPABASE_SECRET_KEY:'sb_secret_test',STRIPE_SECRET_KEY:'sk_live_test',DIALER_LIVE_BILLING_ENABLED:'true'});
const provider=require('../lib/dialer-at-cost-provider');
const full=require('../lib/dialer-full'),parallel=require('../lib/dialer-parallel'),owner=full.MASTER;
const id='11111111-1111-4111-8111-111111111111',authSession='22222222-2222-4222-8222-222222222222',agent='CA'+'b'.repeat(32),account=process.env.TWILIO_ACCOUNT_SID;
const exempt='5893f335-aad3-4079-ad95-77eaf1347ac6',subaccount='AC'+'d'.repeat(32);let exemption,access=true,entitled=true,syncs=0;require('../lib/dialer-full-billing').sync=async()=>{syncs++;};require('../lib/dialer-full-billing').ensureFresh=async()=>{syncs++;};
let raceCancelSid=null;let recoveryRecords=[];let rejectNumber=false,parallelInFlight=0,maxInFlight=0;let s,legs,records,requests=[],rateCountry='US',rate='0.014',winner=null,createUncertain=false,creates=0;
function reset(user=owner){raceCancelSid=null;access=true;entitled=true;exemption={user_id:exempt,required_role:'agent',enabled:true,provider_sid:subaccount,provider_app:'AP'+'d'.repeat(32),provider_key:'SK'+'d'.repeat(32),provider_secret_cipher:provider.seal('sub-key',exempt)};s={id,created_at:new Date().toISOString(),user_id:user,session_id:authSession,provider_sid:user===owner?account:subaccount,caller_id:'+12025550123',state:'prepared',heartbeat_at:new Date().toISOString(),expires_at:new Date(Date.now()+240000).toISOString(),agent_sid:agent};legs=[1,2,3].map(n=>({id:'33333333-3333-4333-8333-'+String(n).padStart(12,'0'),session_id:id,position:n,phone:'+1202555012'+(n+3),rate:.014,state:'prepared',terminal:false,duration_seconds:0}));records=new Map([[agent,{sid:agent,account_sid:s.provider_sid,from:'client:vivid_parallel_'+id.replaceAll('-',''),status:'in-progress',duration:'10'}]]);winner=null;creates=0;createUncertain=false;recoveryRecords=[];rejectNumber=false;parallelInFlight=0;maxInFlight=0;requests=[];}
const json=d=>new Response(JSON.stringify(d),{headers:{'content-type':'application/json'}});
global.fetch=async(url,opt={})=>{const u=new URL(url),body=opt.body&&String(opt.body).startsWith('{')?JSON.parse(opt.body):null;requests.push({url,method:opt.method,body,authorization:opt.headers?.Authorization});
 if(u.pathname.endsWith('/dialer_caller_pools'))return json(u.searchParams.get('id')==='eq.pool-fixture'?[{id:'pool-fixture'}]:[]);
 if(u.pathname.endsWith('/rpc/dialer_pool_options'))return json(null);
 if(u.pathname.endsWith('/rpc/dialer_parallel_allowed'))return json(access);
 if(u.pathname.endsWith('/rpc/dialer_entitled'))return json(entitled);
 if(u.pathname.endsWith('/dialer_at_cost'))return json(exemption&&(!u.searchParams.has('user_id')||u.searchParams.get('user_id')==='eq.'+exempt)&&(!u.searchParams.has('provider_sid')||u.searchParams.get('provider_sid')==='eq.'+subaccount)&&(!u.searchParams.has('enabled')||exemption.enabled)?[exemption]:[]);
 if(u.hostname==='pricing.twilio.com')return json({destination_number:decodeURIComponent(u.pathname.split('/').at(-1)),iso_country:rateCountry,price_unit:'USD',outbound_call_prices:[{current_price:rate}]});
 if(u.pathname.endsWith('/rpc/dialer_parallel_prepare_mode')){s.connect_mode=body.p_mode;return json(id);}
 if(u.pathname.endsWith('/rpc/dialer_parallel_event')){const l=legs.find(l=>l.id===body.p_leg);let result='ignored';
  if(body.p_event==='agent'){s.agent_sid=body.p_sid;result='agent';}
  if(body.p_event==='ready'){s.state='ready';result='ready';}
  if(body.p_event==='launch'&&s.state==='ready'){s.state='dialing';result='launch';}
  if(body.p_event==='claim'&&l.state==='prepared'&&s.state==='dialing'&&!winner){l.state='creating';result='create';}
  if(body.p_event==='reject'&&l.state==='creating'&&!l.provider_sid){l.state='failed';l.terminal=true;l.outcome='number_rejected';l.error_code=body.p_seconds;result='rejected';}
  if(body.p_event==='bind'){l.provider_sid=body.p_sid;if(l.state==='creating')l.state='queued';result='bound';}
  if(body.p_event==='answer'){
   l.provider_sid=body.p_sid;l.pickup_at??=new Date().toISOString();records.get(body.p_sid).status='in-progress';
   l.answer=body.p_value;
   if(s.state==='stopping'||s.state==='complete')result='stopped';
   else if(['human','answered','unknown'].includes(body.p_value)){if(!winner||winner===l.id){s.winner_id=winner=l.id;s.state='connected';l.outcome='connected';result='winner';}else{l.outcome=body.p_value==='unknown'?'answer_unconfirmed':'second_answer';l.followup_noted_at=new Date().toISOString();result='overflow';}}
   else{l.outcome=s.kind==='leads'&&body.p_value==='unknown'?'answer_unconfirmed':body.p_value;result='hangup';}
  }
  if(body.p_event==='status'){l.provider_sid=body.p_sid;if(!l.terminal)l.state=body.p_value;l.duration_seconds=Math.max(l.duration_seconds,body.p_seconds);l.terminal||=['completed','canceled','failed','no-answer','busy'].includes(body.p_value);if(['in-progress','completed'].includes(body.p_value))l.pickup_at??=new Date().toISOString();if(l.terminal&&!l.answer&&l.pickup_at&&l.id!==winner)l.outcome='answer_unconfirmed';result='status';}
  if(body.p_event==='stop'){s.state='stopping';for(const l of legs)if(l.state==='prepared'){l.state='canceled';l.terminal=true;}result='stopped';}
  if(body.p_event==='complete'){s.state='complete';result='complete';}
  return json({result});
 }
 if(u.pathname.endsWith('/dialer_parallel_sessions')){if(opt.method==='PATCH'){Object.assign(s,body);return json([s]);}if(u.searchParams.get('select')==='reserved_cents')return json([{reserved_cents:50}]);return json(!u.searchParams.has('user_id')||u.searchParams.get('user_id')==='eq.'+s.user_id?[{...s}]:[]);}
 if(u.pathname.endsWith('/dialer_parallel_legs')){if(opt.method==='PATCH'){const l=legs.find(l=>'eq.'+l.id===u.searchParams.get('id'));Object.assign(l,body);return json([l]);}return json(legs.map(l=>({...l})));}
 if(u.pathname.endsWith('/leads')){assert.equal(u.searchParams.get('assigned_to'),'eq.'+s.user_id);assert.equal(u.searchParams.get('status'),'eq.assigned');return json(legs.filter(l=>u.searchParams.get('id').includes(l.lead_id)).map(l=>({id:l.lead_id,call_notes:'Existing notes\nAutomatic follow-up note',phone:l.phone})));}
 if(u.pathname.endsWith('/dialer_calls'))return json([]);
 if(u.pathname.endsWith('/dialer_numbers'))return json([{phone:s.caller_id}]);
 if(u.pathname.endsWith('/master_dialer_numbers'))return json([]);
 if(u.hostname==='api.twilio.com'){
  if(u.pathname.endsWith('/'+subaccount+'.json'))return json({sid:subaccount,owner_account_sid:account,status:'active',auth_token:'sub-secret'});
  assert(u.pathname.includes('/Accounts/'+s.provider_sid+'/'),'Wrong billing account');assert.equal(opt.headers.Authorization,'Basic '+Buffer.from(s.provider_sid+':'+(s.provider_sid===account?'test-secret':'sub-secret')).toString('base64'));
  if(u.pathname.endsWith('/Calls.json')&&opt.method==='GET')return json({calls:recoveryRecords.filter(c=>c.to===u.searchParams.get('To')&&c.from===u.searchParams.get('From')),next_page_uri:null});
  if(u.pathname.endsWith('/Calls.json')&&opt.method==='POST'){creates++;const p=new URLSearchParams(opt.body);assert.deepEqual(p.getAll('StatusCallbackEvent'),['initiated','ringing','answered','completed']);assert.equal(p.get('MachineDetection'),s.connect_mode==='fast'?null:'Enable');assert.equal(p.get('AsyncAmd'),s.connect_mode==='fast'?null:'false');assert.equal(p.get('TimeLimit'),String(s.kind==='leads'?1800:90));assert.equal(p.get('Timeout'),'20');if(createUncertain)throw Error('Provider timeout');const thisCreate=creates;parallelInFlight++;maxInFlight=Math.max(maxInFlight,parallelInFlight);await new Promise(r=>setTimeout(r,5));parallelInFlight--;if(rejectNumber&&thisCreate===1)return new Response(JSON.stringify({code:21211}),{status:400});const sid='CA'+String(thisCreate).padStart(32,'0'),d={sid,account_sid:s.provider_sid,to:p.get('To'),from:p.get('From'),status:'queued',duration:'0',price:null};records.set(sid,d);return json(d);}
  const sid=u.pathname.split('/').at(-1).replace('.json',''),d=records.get(sid);assert(d,'Unowned provider call read');if(opt.method==='POST'){const p=new URLSearchParams(opt.body);if(sid===raceCancelSid&&p.get('Status')==='canceled'){raceCancelSid=null;d.status='in-progress';return new Response(JSON.stringify({code:21220}),{status:400});}d.status=p.get('Status');}return json(d);
 }
 throw Error('Unexpected fetch '+url);
};
const response=()=>({setHeader(){},status(n){this.code=n;return this;},send(d){this.data=d;return this;},json(d){this.data=d;return this;},end(){return this;}});
function signed(path,body,secret='test-secret'){let raw=full.ORIGIN+path;for(const k of Object.keys(body).sort())raw+=k+body[k];return {method:'POST',url:path,body,headers:{'content-type':'application/x-www-form-urlencoded','x-twilio-signature':createHmac('sha1',secret).update(raw).digest('base64')}};}
function webhook(kind,l,extra={}){const path='/api/dialer/parallel-events?'+new URLSearchParams({id,kind,leg:l.id});return signed(path,{AccountSid:s.provider_sid,CallSid:l.provider_sid,To:l.phone,From:l.caller_id||s.caller_id,...extra},s.provider_sid===account?'test-secret':'sub-secret');}
(async()=>{reset();assert.equal(parallel.normalize('(202) 555-0124'),'+12025550124');assert.throws(()=>parallel.normalize('911'));const c=full.config(),t=parallel.tokens(s,c);const claims=JSON.parse(Buffer.from(t.token.split('.')[1],'base64url'));assert.equal(claims.exp-claims.iat,3600,'Headset token must outlast a 30-minute call');assert.equal(parallel.alive({...s,state:'connected',heartbeat_at:new Date(Date.now()-60000).toISOString()}),true);assert.equal(parallel.alive({...s,state:'dialing',heartbeat_at:new Date(Date.now()-60000).toISOString()}),false);assert.equal(parallel.alive({...s,state:'connected',heartbeat_at:new Date(Date.now()-95000).toISOString()}),false);assert.equal(parallel.grant(t.callGrant,c).id,id);assert.throws(()=>parallel.grant(t.callGrant+'x',c));
 assert.deepEqual(await parallel.action({body:{action:'access'}},{id:'paid-user',live:true}),{allowed:true,atCost:false});
 await assert.rejects(parallel.action({body:{action:'prepare',id,callerId:s.caller_id,phones:[legs[0].phone],testPhonesConfirmed:false,acceptCharges:true}},{id:owner,sessionId:authSession,live:true}),/Confirm/);
 rateCountry='CA';await assert.rejects(parallel.price(legs[0].phone,s.caller_id,c),/standard-rate US/);rateCountry='US';rate='.09';await assert.rejects(parallel.price(legs[0].phone,s.caller_id,c),/standard-rate US/);rate='0.014';assert.equal(await parallel.price(legs[0].phone,s.caller_id,c),.014);
 let res=response();await parallel.voice(signed('/api/dialer/voice',{AccountSid:account,CallSid:agent,From:'client:vivid_parallel_'+id.replaceAll('-',''),ParallelGrant:t.callGrant}),res);assert.equal(res.code,200);assert.match(res.data,/<Conference/);assert.match(res.data,/maxParticipants="10"/);assert.match(res.data,/timeLimit="120"/);
 res=response();await parallel.events({method:'POST',url:'/api/dialer/parallel-events?id='+id,body:{},headers:{}},res);assert.equal(res.code,403);
 s.state='ready';await parallel.launch(await parallel.get(id));assert.equal(creates,3);await parallel.launch(await parallel.get(id));assert.equal(creates,3,'Repeated launch created extra calls');
 res=response();await parallel.events(webhook('answer',legs[0],{AnsweredBy:'machine_start'}),res);assert.equal(res.code,200);assert(!res.data.includes('<Conference'));
 res=response();await parallel.events(webhook('answer',legs[1],{AnsweredBy:'human'}),res);assert.match(res.data,/<Conference/);assert.equal(s.winner_id,legs[1].id);
 res=response();await parallel.events(webhook('answer',legs[2],{AnsweredBy:'human'}),res);assert(!res.data.includes('<Conference'));assert.match(res.data,/Another test phone/);
 const wrong=webhook('answer',legs[1],{AnsweredBy:'human',To:'+12025550999'});res=response();await parallel.events(wrong,res);assert.equal(res.code,403);
 await parallel.stop(await parallel.get(id));assert.equal(s.state,'complete');for(const call of records.values())assert(['completed','canceled'].includes(call.status));
 reset();s.state='ready';createUncertain=true;await assert.rejects(parallel.launch(await parallel.get(id)),/could not be confirmed/);assert.equal(creates,1,'Uncertain creation retried or placed additional calls');assert.equal(s.state,'stopping');
 reset(exempt);const u={id:exempt,sessionId:authSession,live:true};
 assert.deepEqual(await parallel.action({body:{action:'access'}},u),{allowed:true,atCost:true});
 assert.deepEqual(await parallel.action({body:{action:'access'}},{id:'paid-user',live:true}),{allowed:true,atCost:false});
 access=false;await assert.rejects(parallel.action({body:{action:'options'}},u),/active agent or admin/);access=true;
 const prep={action:'prepare',id,callerId:s.caller_id,phones:[legs[0].phone],testPhonesConfirmed:true,acceptCharges:true};
 entitled=false;await assert.rejects(parallel.action({body:prep},u),/payment and calling setup/);assert.equal(creates,0);entitled=true;
 await assert.rejects(parallel.action({body:{...prep,callerId:'+12025550999'}},u),/belonging to your account/);
 const prepared=await parallel.action({body:prep},u),sc=await provider.context(u);
 assert.equal(JSON.parse(Buffer.from(prepared.token.split('.')[1],'base64url')).sub,subaccount);
 assert.equal(parallel.grant(prepared.callGrant,sc).sub,exempt);assert.throws(()=>parallel.grant(prepared.callGrant,c));
 assert(requests.filter(x=>x.url.includes('pricing.twilio.com')).every(x=>x.authorization==='Basic '+Buffer.from(subaccount+':sub-secret').toString('base64')));
 res=response();await parallel.voice(signed('/api/dialer/voice',{AccountSid:subaccount,CallSid:agent,From:'client:vivid_parallel_'+id.replaceAll('-',''),ParallelGrant:prepared.callGrant},'sub-secret'),res);assert.equal(res.code,200);
 await assert.rejects(parallel.get(id,owner),/unavailable/);
 s.state='ready';await parallel.action({body:{action:'launch',id}},u);assert.equal(creates,3);assert(syncs>=3);
 res=response();await parallel.events(webhook('answer',legs[0],{AnsweredBy:'human',AccountSid:account}),res);assert.equal(res.code,403);assert.equal(s.winner_id,undefined);
 res=response();await parallel.events(webhook('answer',legs[0],{AnsweredBy:'human'}),res);assert.equal(res.code,200);assert.match(res.data,/<Conference/);
 // Access may be revoked while phones are ringing: cleanup must still use the pinned account.
 access=false;exemption.enabled=false;await parallel.action({body:{action:'stop',id}},u);assert.equal(s.state,'complete');for(const call of records.values())assert(['completed','canceled'].includes(call.status));
 await assert.rejects(parallel.storedContext({...s,provider_sid:account}),/ownership mismatch/);
 exemption=null;await assert.rejects(parallel.storedContext({...s}),/ownership mismatch/);
 reset();const fastPrep={action:'prepare',id,callerId:s.caller_id,phones:legs.map(l=>l.phone),connectMode:'fast',testPhonesConfirmed:true,acceptCharges:true};
 const fast=await parallel.action({body:fastPrep},{id:owner,sessionId:authSession,live:true});assert.equal(fast.session.connectMode,'fast');
 s.state='ready';await parallel.launch(await parallel.get(id));assert.equal(creates,3);
 // No human/machine classification is required to connect the first pickup.
 res=response();await parallel.events(webhook('answer',legs[0]),res);assert.equal(res.code,200);assert.match(res.data,/<Conference/);assert.equal(legs[0].answer,'answered');
 res=response();await parallel.events(webhook('answer',legs[1]),res);assert(!res.data.includes('<Conference'));assert.match(res.data,/Another test phone/);
 const snapshot=await parallel.get(id),fastCost=parallel.publicState(snapshot).estimatedUsd,humanCost=parallel.publicState({...snapshot,connect_mode:'human'}).estimatedUsd;assert.equal(Number((humanCost-fastCost).toFixed(4)),.015,'Fast mode charged AMD');
 await parallel.stop(await parallel.get(id));assert.equal(s.state,'complete');
 await assert.rejects(parallel.action({body:{...fastPrep,connectMode:'bad'}},{id:owner,sessionId:authSession,live:true}),/connection mode/);

 // Ordinary paid agents use the root provider account, with their own lead ledger.
 reset();s.kind='leads';s.user_id='77777777-7777-4777-8777-777777777777';s.max_seconds=1800;s.state='ready';s.connect_mode='fast';legs.forEach((leg,i)=>leg.lead_id='55555555-5555-4555-8555-'+String(i+1).padStart(12,'0'));
 await parallel.launch(await parallel.get(id));assert.equal(creates,3);assert.equal(maxInFlight,3,'Power calls were launched serially');
 res=response();await parallel.events(webhook('answer',legs[0]),res);assert.match(res.data,/timeLimit="1860"/);
 res=response();await parallel.events(webhook('answer',legs[1]),res);assert.match(res.data,/Please call/);assert(!res.data.includes('dialer test'));
 const paidUser={id:s.user_id,sessionId:authSession,live:true};const updated=await parallel.action({body:{action:'status',id}},paidUser);assert.equal(updated.leads.length,1);assert.equal(updated.leads[0].id,legs[1].lead_id);assert.match(updated.leads[0].call_notes,/Automatic follow-up note/);
 const ended=await parallel.action({body:{action:'stop',id}},paidUser);assert.equal(s.state,'complete');assert.equal(ended.leads[0].id,legs[1].lead_id);assert.match(ended.leads[0].call_notes,/Automatic follow-up note/);
 // Machines are skipped, but an uncertain pickup is preserved without claiming human detection.
 reset();s.kind='leads';s.max_seconds=1800;s.state='ready';s.connect_mode='human';
 await parallel.launch(await parallel.get(id));assert.equal(creates,3);assert.equal(maxInFlight,3);
 res=response();await parallel.events(webhook('answer',legs[0],{AnsweredBy:'machine_start',MachineDetectionDuration:'2100'}),res);assert.match(res.data,/<Hangup/);assert(!res.data.includes('<Conference'));assert.equal(winner,null);assert.equal(legs[0].outcome,'machine');assert.doesNotMatch(res.data,/<Gather|<Say|press.?1/i);assert.equal(s.state,'dialing');assert.equal(records.get(legs[1].provider_sid).status,'queued','Machine detection stopped another line');
 res=response();await parallel.events(webhook('answer',legs[1],{AnsweredBy:'unknown'}),res);assert.match(res.data,/<Conference/);assert.doesNotMatch(res.data,/<Gather|<Say|press.?1/i);assert.equal(legs[1].answer,'unknown');assert.equal(legs[1].outcome,'connected');assert.equal(winner,legs[1].id);assert.equal(s.state,'connected');
 res=response();await parallel.events(webhook('answer',legs[2],{AnsweredBy:'human'}),res);assert.doesNotMatch(res.data,/<Conference/);assert.equal(s.winner_id,legs[1].id);assert.equal(legs[2].outcome,'second_answer');
 await parallel.stop(await parallel.get(id));assert.equal(s.state,'complete');
 // A definitive invalid-number response must not stop the two other leads.
 reset();s.kind='leads';s.max_seconds=1800;s.state='ready';s.connect_mode='fast';rejectNumber=true;
 await parallel.launch(await parallel.get(id));assert.equal(creates,3);assert.equal(legs[0].outcome,'number_rejected');assert.equal(legs[0].error_code,21211);assert.equal(legs[1].state,'queued');assert.equal(legs[2].state,'queued');
 await parallel.stop(await parallel.get(id));assert.equal(s.state,'complete');

 // An ambiguous POST is never retried. Recovery binds the provider's existing call.
 reset();s.kind='leads';s.max_seconds=1800;s.state='ready';s.connect_mode='fast';createUncertain=true;
 await assert.rejects(parallel.launch(await parallel.get(id)),/could not be confirmed/);assert.equal(creates,3);assert.equal(s.state,'stopping');
 const recovered={sid:'CA'+'9'.repeat(32),account_sid:account,from:s.caller_id,to:legs[0].phone,direction:'outbound-api',date_created:new Date(s.created_at).toUTCString(),status:'ringing',duration:'0',price:null};records.set(recovered.sid,recovered);recoveryRecords=[recovered];
 await parallel.stop(await parallel.get(id));assert.equal(legs[0].provider_sid,recovered.sid);assert.equal(recovered.status,'canceled');assert.equal(creates,3,'Recovery created another call');
 s.created_at=new Date(Date.now()-180000).toISOString();await parallel.stop(await parallel.get(id));assert.equal(s.state,'complete');assert.equal(creates,3);assert(legs.every(l=>l.terminal));
 // A nonwinning phone has already picked up but its AMD webhook is still in flight.
 reset();s.kind='leads';s.max_seconds=1800;s.state='ready';s.connect_mode='human';legs.forEach((l,i)=>l.lead_id='55555555-5555-4555-8555-'+String(i+1).padStart(12,'0'));
 await parallel.launch(await parallel.get(id));res=response();await parallel.events(webhook('answer',legs[0],{AnsweredBy:'human'}),res);
 records.get(legs[1].provider_sid).status='in-progress';
 await parallel.action({body:{action:'status',id}},{id:owner,sessionId:authSession,live:true});
 assert.equal(records.get(legs[1].provider_sid).status,'in-progress','Cleanup hung up a person before AMD finished');assert.equal(records.get(legs[2].provider_sid).status,'canceled','Unanswered phone kept ringing');
 res=response();await parallel.events(webhook('answer',legs[1],{AnsweredBy:'human'}),res);assert.match(res.data,/Please call/);assert.equal(legs[1].outcome,'second_answer');assert.equal(s.winner_id,legs[0].id);
 await parallel.action({body:{action:'status',id}},{id:owner,sessionId:authSession,live:true});assert.equal(records.get(legs[1].provider_sid).status,'in-progress','Cleanup interrupted the overflow message');
 legs[1].followup_noted_at=new Date(Date.now()-31000).toISOString();await parallel.action({body:{action:'status',id}},{id:owner,sessionId:authSession,live:true});assert.equal(records.get(legs[1].provider_sid).status,'completed','Overflow cleanup was unbounded');await parallel.stop(await parallel.get(id));
 // GET says ringing, but a person answers before the cancellation request reaches Twilio.
 reset();s.kind='leads';s.max_seconds=1800;s.state='ready';s.connect_mode='human';await parallel.launch(await parallel.get(id));res=response();await parallel.events(webhook('answer',legs[0],{AnsweredBy:'human'}),res);raceCancelSid=legs[1].provider_sid;
 await parallel.action({body:{action:'status',id}},{id:owner,sessionId:authSession,live:true});assert.equal(records.get(legs[1].provider_sid).status,'in-progress','Cancel race fell back to a forced hangup');
 // Missing AMD results have a bounded grace period and retain evidence of the pickup.
 legs[1].pickup_at=new Date(Date.now()-16000).toISOString();await parallel.action({body:{action:'status',id}},{id:owner,sessionId:authSession,live:true});assert.equal(records.get(legs[1].provider_sid).status,'completed');assert.equal(legs[1].outcome,'answer_unconfirmed');await parallel.stop(await parallel.get(id));
 // Old signed keypress callbacks cannot connect or prompt a recipient after removal.
 reset();s.kind='leads';s.max_seconds=1800;s.state='ready';s.connect_mode='human';await parallel.launch(await parallel.get(id));
 res=response();await parallel.events(webhook('confirm',legs[0],{Digits:'1'}),res);assert.match(res.data,/<Hangup/);assert.doesNotMatch(res.data,/<Gather|<Say|<Conference|press.?1/i);assert.equal(winner,null);assert.equal(legs[0].outcome,undefined);
 await parallel.stop(await parallel.get(id));assert([...records.values()].every(c=>['completed','canceled'].includes(c.status)),'Explicit stop left calls alive');
 reset(exempt);s.caller_pool_id='pool-fixture';s.provider_sid=account;assert.equal((await parallel.storedContext({...s})).TWILIO_ACCOUNT_SID,account);await assert.rejects(parallel.storedContext({...s,caller_pool_id:'wrong-pool'}),/ownership mismatch/);
 // Each shared caller ID is pinned independently through launch, signed events and cleanup.
 reset();s.kind='leads';s.max_seconds=1800;s.state='ready';s.connect_mode='human';
 legs.forEach((l,i)=>l.caller_id='+1313555012'+i);
 await parallel.launch(await parallel.get(id));assert.equal(creates,3);
 for(const leg of legs)assert.equal(records.get(leg.provider_sid).from,leg.caller_id);
 res=response();await parallel.events(webhook('answer',legs[0],{AnsweredBy:'human',From:s.caller_id}),res);assert.equal(res.code,403);
 res=response();await parallel.events(webhook('answer',legs[0],{AnsweredBy:'human'}),res);assert.match(res.data,/<Conference/);
 res=response();await parallel.events(webhook('answer',legs[1],{AnsweredBy:'human'}),res);assert(res.data.includes(legs[1].caller_id.split('').join(' ')));
 await parallel.stop(await parallel.get(id));assert.equal(s.state,'complete');
 console.log('PASS: legacy fast mode, automatic detection without recipient prompts, one winner, pending-AMD cleanup, GET/cancel pickup race, bounded detection/overflow cleanup, no silent loss of pickup evidence, explicit stop, refreshed follow-up notes and billing ownership.');
})().catch(e=>{console.error(e);process.exitCode=1;});
