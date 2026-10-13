'use strict';
const {createHmac,timingSafeEqual,randomUUID}=require('node:crypto');
const {config,rpc,database,twilio,failure,UUID,ORIGIN,MASTER,mode}=require('./dialer-full');
const {validSignature}=require('./dialer-incoming');
const escape=value=>String(value).replace(/[&<>"']/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&apos;'}[c]));
function xml(res,body,status=200){res.setHeader('Content-Type','text/xml; charset=utf-8');res.setHeader('Cache-Control','no-store');return res.status(status).send('<Response>'+body+'</Response>');}
const SID=/^CA[0-9a-f]{32}$/i,PHONE=/^\+1[2-9]\d{2}[2-9]\d{6}$/;
const terminal=new Set(['completed','busy','failed','no-answer','canceled']);
const ROUTE='/api/dialer/parallel-events',AUD='vivid_parallel_pilot_v1';
const hook=(id,kind,leg)=>ORIGIN+ROUTE+'?'+new URLSearchParams({id,kind,...(leg?{leg}:{})});
const event=(id,name,leg=null,sid=null,value=null,seconds=0)=>rpc('dialer_parallel_event',{p_id:id,p_event:name,p_leg:leg,p_sid:sid,p_value:value,p_seconds:seconds});
const identity=id=>'vivid_parallel_'+id.replace(/-/g,'');
function sign(h,p,secret){const raw=[h,p].map(v=>Buffer.from(JSON.stringify(v)).toString('base64url')).join('.');return raw+'.'+createHmac('sha256',secret).update(raw).digest('base64url');}
function tokens(s,c){const t=Math.floor(Date.now()/1000);return {
 token:sign({alg:'HS256',typ:'JWT',cty:'twilio-fpa;v=1'},{jti:c.TWILIO_API_KEY_SID+'-'+randomUUID(),iss:c.TWILIO_API_KEY_SID,sub:c.TWILIO_ACCOUNT_SID,iat:t,nbf:t-5,exp:t+300,grants:{identity:identity(s.id),voice:{outgoing:{application_sid:c.TWILIO_TWIML_APP_SID},incoming:{allow:false}}}},c.TWILIO_API_KEY_SECRET),
 callGrant:sign({alg:'HS256',typ:'JWT'},{aud:AUD,id:s.id,sub:s.user_id,exp:t+60},c.TWILIO_API_KEY_SECRET)
};}
function grant(token,c){if(typeof token!=='string'||token.length>2048)throw failure(403,'Invalid pilot authorization.');const parts=token.split('.');if(parts.length!==3)throw failure(403,'Invalid pilot authorization.');const a=createHmac('sha256',c.TWILIO_API_KEY_SECRET).update(parts.slice(0,2).join('.')).digest(),b=Buffer.from(parts[2],'base64url');if(a.length!==b.length||!timingSafeEqual(a,b))throw failure(403,'Invalid pilot authorization.');let h,p;try{h=JSON.parse(Buffer.from(parts[0],'base64url'));p=JSON.parse(Buffer.from(parts[1],'base64url'));}catch{throw failure(403,'Invalid pilot authorization.');}if(h.alg!=='HS256'||h.typ!=='JWT'||p.aud!==AUD||p.sub!==MASTER||!UUID.test(p.id||'')||!Number.isInteger(p.exp)||p.exp<=Date.now()/1000||p.exp>Date.now()/1000+90)throw failure(403,'Pilot authorization expired.');return p;}
async function get(id,user){if(!UUID.test(id||''))throw failure(400,'Choose a pilot session.');const rows=await database('dialer_parallel_sessions?'+new URLSearchParams({id:'eq.'+id,...(user?{user_id:'eq.'+user}:{}),select:'*'}));if(rows.length!==1)throw failure(404,'Pilot session unavailable.');const s=rows[0];s.legs=await database('dialer_parallel_legs?'+new URLSearchParams({session_id:'eq.'+id,order:'position.asc',select:'*'}));return s;}
function alive(s){return !['stopping','complete'].includes(s.state)&&Date.parse(s.expires_at)>Date.now()&&Date.parse(s.heartbeat_at)>Date.now()-35000;}
function publicState(s){const agentMinutes=Math.ceil((s.agent_seconds||0)/60),phoneCost=s.legs.reduce((n,l)=>n+Math.ceil(l.duration_seconds/60)*Number(l.rate),0),answered=s.legs.filter(l=>l.answer||l.duration_seconds>0).length,winner=s.legs.find(l=>l.id===s.winner_id);return {id:s.id,state:s.state,callerId:s.caller_id,winnerId:s.winner_id,expiresAt:s.expires_at,
 estimatedUsd:Number((phoneCost+answered*0.0075+agentMinutes*0.004+(agentMinutes+Math.ceil((winner?.duration_seconds||0)/60))*0.0018).toFixed(4)),
 legs:s.legs.map(l=>({id:l.id,position:l.position,phone:l.phone,state:l.state,answer:l.answer,outcome:l.outcome,durationSeconds:l.duration_seconds,phoneCostUsd:l.price_usd,detectionMs:l.detection_ms}))};}
async function allowance(user){const rows=await database('dialer_parallel_sessions?'+new URLSearchParams({user_id:'eq.'+user,created_at:'gt.'+new Date(Date.now()-86400000).toISOString(),select:'reserved_cents'}));return {reservedCents:rows.reduce((n,s)=>n+s.reserved_cents,0),limitCents:500,maxTests:10};}
function normalize(value){const raw=String(value||'');if(!/^[+0-9().\s-]+$/.test(raw))throw failure(400,'Enter a valid US test phone number.');let digits=raw.replace(/\D/g,'');if(digits.length===10)digits='1'+digits;const phone='+'+digits;if(!PHONE.test(phone))throw failure(400,'Enter a valid US test phone number.');return phone;}
async function price(phone,caller,c){const r=await fetch('https://pricing.twilio.com/v2/Voice/Numbers/'+encodeURIComponent(phone)+'?'+new URLSearchParams({OriginationNumber:caller}),{headers:{Authorization:'Basic '+Buffer.from(c.TWILIO_ACCOUNT_SID+':'+c.TWILIO_AUTH_TOKEN).toString('base64')},signal:AbortSignal.timeout(8000)});if(!r.ok)throw failure(503,'Could not verify this test number’s calling rate. No calls were placed.');const d=await r.json(),prices=d.outbound_call_prices;if(d.destination_number!==phone||d.iso_country!=='US'||String(d.price_unit).toUpperCase()!=='USD'||!Array.isArray(prices)||!prices.length||prices.some(p=>!/^\d+(\.\d+)?$/.test(String(p.current_price))||Number(p.current_price)<=0||Number(p.current_price)>0.014))throw failure(400,'The pilot accepts standard-rate US test numbers only.');return Math.max(...prices.map(p=>Number(p.current_price)));}
async function options(u){const [numbers,old,sessions,budget]=await Promise.all([database('dialer_numbers?'+new URLSearchParams({user_id:'eq.'+u.id,livemode:'eq.true',state:'eq.active',select:'phone'})),database('master_dialer_numbers?'+new URLSearchParams({user_id:'eq.'+u.id,state:'eq.active',select:'phone_number'})),database('dialer_parallel_sessions?'+new URLSearchParams({user_id:'eq.'+u.id,select:'id,state,created_at,expires_at',order:'created_at.desc',limit:'10'})),allowance(u.id)]);return {numbers:[...new Set([...numbers.map(n=>n.phone),...old.map(n=>n.phone_number)])],sessions,budget};}
async function prepare(u,b){if(b.testPhonesConfirmed!==true||b.acceptCharges!==true)throw failure(400,'Confirm these are consenting test phones and accept the displayed provider charges.');if(!UUID.test(b.id||'')||!Array.isArray(b.phones)||b.phones.length<1||b.phones.length>3||!PHONE.test(b.callerId||''))throw failure(400,'Choose a caller ID and one to three test phones.');const phones=b.phones.map(normalize);if(new Set(phones).size!==phones.length||phones.includes(b.callerId))throw failure(400,'Use distinct test phones, different from your caller ID.');const allowed=await options(u);if(!allowed.numbers.includes(b.callerId))throw failure(403,'Choose an active caller ID belonging to your account.');const c=config(),rates=await Promise.all(phones.map(p=>price(p,b.callerId,c)));await rpc('dialer_parallel_prepare',{p_user:u.id,p_session:u.sessionId,p_id:b.id,p_account:c.TWILIO_ACCOUNT_SID,p_caller:b.callerId,p_phones:phones,p_rates:rates});const s=await get(b.id,u.id);if(s.session_id!==u.sessionId||s.state!=='prepared'||!alive(s))throw failure(409,'This pilot has already started or expired.');return {...tokens(s,c),session:publicState(s),budget:await allowance(u.id)};}
function conference(s,agent){const attributes=agent?' startConferenceOnEnter="true" endConferenceOnExit="true" participantLabel="owner" statusCallback="'+escape(hook(s.id,'conference'))+'" statusCallbackEvent="join leave end" statusCallbackMethod="POST"':' startConferenceOnEnter="true" endConferenceOnExit="true" participantLabel="winner"';return '<Dial timeLimit="120" record="do-not-record"><Conference beep="false" maxParticipants="2" record="do-not-record" waitUrl=""'+attributes+'>'+identity(s.id)+'</Conference></Dial><Hangup/>';}
async function voice(req,res){try{const c=config(),b=req.body;if(req.method!=='POST'||!validSignature(req,b,c,['/api/dialer/voice'])||b.AccountSid!==c.TWILIO_ACCOUNT_SID||!SID.test(b.CallSid||''))throw failure(403,'Invalid signature.');const p=grant(b.ParallelGrant,c),s=await get(p.id,MASTER);if(b.From!=='client:'+identity(s.id)||s.provider_sid!==c.TWILIO_ACCOUNT_SID)throw failure(403,'Pilot ownership mismatch.');const r=await event(s.id,'agent',null,b.CallSid);if(r.result!=='agent')return xml(res,'<Hangup/>');return xml(res,conference(s,true));}catch(e){return xml(res,'<Hangup/>',e.status||503);}}
async function launch(s){if(!alive(s))throw failure(409,'Pilot expired. Start a fresh test.');if((await event(s.id,'launch')).result!=='launch')return;
 for(const leg of s.legs){if((await event(s.id,'claim',leg.id)).result!=='create')continue;let created;
  try{const params=new URLSearchParams({To:leg.phone,From:s.caller_id,Url:hook(s.id,'answer',leg.id),Method:'POST',Timeout:'20',TimeLimit:'90',MachineDetection:'Enable',AsyncAmd:'false',MachineDetectionTimeout:'10',StatusCallback:hook(s.id,'status',leg.id),StatusCallbackMethod:'POST'});for(const status of ['initiated','ringing','answered','completed'])params.append('StatusCallbackEvent',status);
   created=await twilio('Calls.json',params);if(!SID.test(created?.sid||'')||created.account_sid!==s.provider_sid)throw Error('Invalid provider response');await event(s.id,'bind',leg.id,created.sid);
   const fresh=await get(s.id),currentLeg=fresh.legs.find(l=>l.id===leg.id);if(!alive(fresh)||(fresh.winner_id&&fresh.winner_id!==leg.id&&currentLeg?.outcome!=='second_answer'))await stopLeg(fresh,currentLeg);
  }catch{await database('dialer_parallel_legs?id=eq.'+leg.id,{outcome:'creation_uncertain'},'PATCH');await event(s.id,'stop');await stop(await get(s.id));throw failure(503,'The provider did not confirm a test call. The batch was stopped. Check the pilot history before retrying.');}
 }
}
async function stopLeg(s,l){if(!l?.provider_sid)return !l||l.terminal||l.state==='prepared';let call=await twilio('Calls/'+l.provider_sid+'.json');if(call.account_sid!==s.provider_sid||call.to!==l.phone||call.from!==s.caller_id)throw Error('Provider ownership mismatch');if(!terminal.has(call.status)){
  try{call=await twilio('Calls/'+l.provider_sid+'.json',{Status:['queued','ringing'].includes(call.status)?'canceled':'completed'});}catch{call=await twilio('Calls/'+l.provider_sid+'.json');if(!terminal.has(call.status))call=await twilio('Calls/'+l.provider_sid+'.json',{Status:'completed'});}
 }
 if(terminal.has(call.status))await event(s.id,'status',l.id,l.provider_sid,call.status,Number(call.duration)||0);
 if(call.price_unit==='USD'||call.price_unit==='usd'){const p=Number(call.price);if(call.price!==null&&Number.isFinite(p))await database('dialer_parallel_legs?id=eq.'+l.id,{price_usd:Math.abs(p)},'PATCH');}
 return terminal.has(call.status);
}
async function stop(s){await event(s.id,'stop');let errors=0;for(const l of s.legs)try{if(!await stopLeg(s,l))errors++;}catch{errors++;}
 if(s.agent_sid)try{let call=await twilio('Calls/'+s.agent_sid+'.json');if(call.account_sid!==s.provider_sid||call.from!=='client:'+identity(s.id))throw Error('Agent ownership mismatch');if(!terminal.has(call.status))call=await twilio('Calls/'+s.agent_sid+'.json',{Status:'completed'});if(!terminal.has(call.status))errors++;await database('dialer_parallel_sessions?id=eq.'+s.id,{agent_seconds:Number(call.duration)||0},'PATCH');}catch{errors++;}
 if(!errors||Date.parse(s.expires_at)<Date.now()-60000)await event(s.id,'complete');return errors;
}
async function cancelOthers(s){let errors=0;for(const l of s.legs)if(l.id!==s.winner_id&&!l.terminal&&l.outcome!=='second_answer')try{await stopLeg(s,l);}catch{errors++;}return errors;}
async function events(req,res){res.setHeader('Cache-Control','no-store');try{
 const c=config(),b=req.body,url=new URL(req.url,ORIGIN),id=url.searchParams.get('id'),kind=url.searchParams.get('kind'),legId=url.searchParams.get('leg');
 if(req.method!=='POST'||!validSignature(req,b,c,[ROUTE])||b.AccountSid!==c.TWILIO_ACCOUNT_SID||url.pathname!==ROUTE)throw failure(403,'Invalid signature.');
 const s=await get(id,MASTER);if(s.provider_sid!==b.AccountSid)throw failure(403,'Provider mismatch.');
 if(kind==='conference'){
  if(b.FriendlyName!==identity(s.id)||!/^CF[0-9a-f]{32}$/i.test(b.ConferenceSid||'')||(s.conference_sid&&s.conference_sid!==b.ConferenceSid))throw failure(403,'Conference mismatch.');
  if(b.StatusCallbackEvent==='participant-join'&&b.CallSid===s.agent_sid)await event(id,'ready',null,b.CallSid,b.ConferenceSid);
  if(b.StatusCallbackEvent==='conference-end'||(b.StatusCallbackEvent==='participant-leave'&&(b.CallSid===s.agent_sid||s.legs.some(l=>l.id===s.winner_id&&l.provider_sid===b.CallSid))))await stop(s);
  return res.status(204).end();
 }
 const l=s.legs.find(x=>x.id===legId);if(!l||!SID.test(b.CallSid||'')||b.To!==l.phone||b.From!==s.caller_id||(l.provider_sid&&l.provider_sid!==b.CallSid))throw failure(403,'Call ownership mismatch.');
 if(kind==='answer'){
  const answer=b.AnsweredBy==='human'?'human':b.AnsweredBy?.startsWith('machine')?'machine':b.AnsweredBy==='fax'?'fax':'unknown';
  const r=await event(id,'answer',l.id,b.CallSid,answer);if(/^\d+$/.test(b.MachineDetectionDuration||''))await database('dialer_parallel_legs?id=eq.'+l.id,{detection_ms:Math.min(Number(b.MachineDetectionDuration),60000)},'PATCH');
  if(r.result==='winner')return xml(res,conference(s,false));
  if(r.result==='overflow')return xml(res,'<Say>This is a Vivid Life dialer test. Another test phone answered first. This test call will now end.</Say><Hangup/>');
  return xml(res,'<Hangup/>');
 }
 if(kind==='status'){
  await event(id,'status',l.id,b.CallSid,b.CallStatus==='initiated'?'queued':b.CallStatus,Number(b.CallDuration)||0);
  const fresh=await get(id);if(l.id===fresh.winner_id&&terminal.has(b.CallStatus)||fresh.legs.every(x=>x.terminal))await stop(fresh);
  return res.status(204).end();
 }
 throw failure(400,'Unknown event.');
 }catch(e){return xml(res,'<Hangup/>',e.status||503);}
}
async function action(req,u){if(u.id!==MASTER||!u.live)throw failure(403,'Parallel dialing is an owner-only live-account pilot.');const b=req.body;if(b.action==='options')return options(u);if(b.action==='prepare')return prepare(u,b);const s=await get(b.id,u.id);
 if(b.action==='stop'){await stop(s);return {session:publicState(await get(s.id)),budget:await allowance(u.id)};}
 if(b.action==='launch'){if(s.session_id!==u.sessionId)throw failure(403,'Open the pilot in its original signed-in session.');await launch(s);return {session:publicState(await get(s.id))};}
 if(b.action==='status'){
  if(b.heartbeat===true&&s.session_id===u.sessionId&&alive(s))await database('dialer_parallel_sessions?id=eq.'+s.id,{heartbeat_at:new Date().toISOString()},'PATCH');
  if(!alive(s)&&s.state!=='complete')await stop(s);else if(s.winner_id)await cancelOthers(s);
  return {session:publicState(await get(s.id)),budget:await allowance(u.id)};
 }
 throw failure(400,'Unknown pilot action.');
}
async function maintenance(){if(!mode())return {checked:0};const rows=await database('dialer_parallel_sessions?'+new URLSearchParams({state:'neq.complete',select:'id',order:'created_at.asc',limit:'15'}));let errors=0;for(const row of rows)try{const s=await get(row.id);if(!alive(s))errors+=await stop(s);else if(s.winner_id)errors+=await cancelOthers(s);}catch{errors++;}return {checked:rows.length,errors};}
module.exports={action,events,voice,maintenance,normalize,price,grant,tokens,publicState,alive,stop,launch,event,get};
