'use strict';
const {createHmac,timingSafeEqual,randomUUID}=require('node:crypto');
const {config,rpc,database,failure,UUID,ORIGIN,MASTER,mode}=require('./dialer-full');
const provider=require('./dialer-at-cost-provider');
const {validSignature}=require('./dialer-incoming');
const escape=value=>String(value).replace(/[&<>"']/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&apos;'}[c]));
function xml(res,body,status=200){res.setHeader('Content-Type','text/xml; charset=utf-8');res.setHeader('Cache-Control','no-store');return res.status(status).send('<Response>'+body+'</Response>');}
const SID=/^CA[0-9a-f]{32}$/i,PHONE=/^\+1[2-9]\d{2}[2-9]\d{6}$/;
const terminal=new Set(['completed','busy','failed','no-answer','canceled']);
const followups=new Set(['second_answer','answer_unconfirmed','answered_not_connected']);
const ROUTE='/api/dialer/parallel-events',AUD='vivid_parallel_pilot_v1';
const hook=(id,kind,leg)=>ORIGIN+ROUTE+'?'+new URLSearchParams({id,kind,...(leg?{leg}:{})});
const event=(id,name,leg=null,sid=null,value=null,seconds=0)=>rpc('dialer_parallel_event',{p_id:id,p_event:name,p_leg:leg,p_sid:sid,p_value:value,p_seconds:seconds});
const identity=id=>'vivid_parallel_'+id.replace(/-/g,'');
// Cleanup uses the provider account pinned to the session, even if access was
// revoked after a call began. Never fall back to charging the owner's account.
const contextCache=new WeakMap();
async function storedContext(s){if(!contextCache.has(s))contextCache.set(s,loadStoredContext(s).catch(e=>{contextCache.delete(s);throw e;}));return contextCache.get(s);}
async function loadStoredContext(s){
 const root=config();if(s.user_id===MASTER||(s.kind==='leads'&&!provider.eligible({id:s.user_id,live:true}))){if(s.provider_sid!==root.TWILIO_ACCOUNT_SID)throw failure(403,'Provider ownership mismatch.');return root;}
 if(!/^AC[0-9a-f]{32}$/i.test(s.provider_sid||'')||s.provider_sid===root.TWILIO_ACCOUNT_SID)throw failure(403,'Provider ownership mismatch.');
 const rows=await database('dialer_at_cost?'+new URLSearchParams({user_id:'eq.'+s.user_id,provider_sid:'eq.'+s.provider_sid,select:'user_id,provider_sid,provider_app,provider_key,provider_secret_cipher'}));
 if(rows.length!==1||!rows[0].provider_secret_cipher)throw failure(403,'Provider ownership mismatch.');
 const r=await fetch('https://api.twilio.com/2010-04-01/Accounts/'+s.provider_sid+'.json',{headers:{Authorization:'Basic '+Buffer.from(root.TWILIO_ACCOUNT_SID+':'+root.TWILIO_AUTH_TOKEN).toString('base64')},signal:AbortSignal.timeout(8000)});
 if(!r.ok)throw failure(503,'Your phone account is unavailable.');const account=await r.json(),row=rows[0];
 if(account.sid!==s.provider_sid||account.owner_account_sid!==root.TWILIO_ACCOUNT_SID||typeof account.auth_token!=='string')throw failure(403,'Provider ownership mismatch.');
 return {...root,TWILIO_ACCOUNT_SID:s.provider_sid,TWILIO_AUTH_TOKEN:account.auth_token,TWILIO_API_KEY_SID:row.provider_key,TWILIO_API_KEY_SECRET:provider.unseal(row.provider_secret_cipher,s.user_id),TWILIO_TWIML_APP_SID:row.provider_app};
}
async function callProvider(s,path,body){
 if(!/^Calls(?:\.json(?:\?[^\s]*)?|\/CA[0-9a-f]{32}\.json)$/i.test(path))throw failure(400,'Invalid call operation.');
 const c=await storedContext(s),r=await fetch('https://api.twilio.com/2010-04-01/Accounts/'+c.TWILIO_ACCOUNT_SID+'/'+path,{method:body?'POST':'GET',headers:{Authorization:'Basic '+Buffer.from(c.TWILIO_ACCOUNT_SID+':'+c.TWILIO_AUTH_TOKEN).toString('base64'),...(body?{'Content-Type':'application/x-www-form-urlencoded'}:{})},...(body?{body:new URLSearchParams(body).toString()}:{}),signal:AbortSignal.timeout(12000)});
 const d=await r.json();if(!r.ok){const e=failure(r.status>=400&&r.status<500?400:503,'The phone provider could not confirm this call operation.');e.providerCode=Number(d.code)||null;e.definitive=r.status>=400&&r.status<500;throw e;}if(Array.isArray(d.calls)?d.calls.some(x=>x.account_sid!==s.provider_sid):d.account_sid!==s.provider_sid)throw failure(403,'Provider ownership mismatch.');return d;
}
function sign(h,p,secret){const raw=[h,p].map(v=>Buffer.from(JSON.stringify(v)).toString('base64url')).join('.');return raw+'.'+createHmac('sha256',secret).update(raw).digest('base64url');}
function tokens(s,c){const t=Math.floor(Date.now()/1000);return {
 token:sign({alg:'HS256',typ:'JWT',cty:'twilio-fpa;v=1'},{jti:c.TWILIO_API_KEY_SID+'-'+randomUUID(),iss:c.TWILIO_API_KEY_SID,sub:c.TWILIO_ACCOUNT_SID,iat:t,nbf:t-5,exp:t+3600,grants:{identity:identity(s.id),voice:{outgoing:{application_sid:c.TWILIO_TWIML_APP_SID},incoming:{allow:false}}}},c.TWILIO_API_KEY_SECRET),
 callGrant:sign({alg:'HS256',typ:'JWT'},{aud:AUD,id:s.id,sub:s.user_id,exp:t+60},c.TWILIO_API_KEY_SECRET)
};}
function grant(token,c){if(typeof token!=='string'||token.length>2048)throw failure(403,'Invalid pilot authorization.');const parts=token.split('.');if(parts.length!==3)throw failure(403,'Invalid pilot authorization.');const a=createHmac('sha256',c.TWILIO_API_KEY_SECRET).update(parts.slice(0,2).join('.')).digest(),b=Buffer.from(parts[2],'base64url');if(a.length!==b.length||!timingSafeEqual(a,b))throw failure(403,'Invalid pilot authorization.');let h,p;try{h=JSON.parse(Buffer.from(parts[0],'base64url'));p=JSON.parse(Buffer.from(parts[1],'base64url'));}catch{throw failure(403,'Invalid pilot authorization.');}if(h.alg!=='HS256'||h.typ!=='JWT'||p.aud!==AUD||!UUID.test(p.sub||'')||!UUID.test(p.id||'')||!Number.isInteger(p.exp)||p.exp<=Date.now()/1000||p.exp>Date.now()/1000+90)throw failure(403,'Pilot authorization expired.');return p;}
async function get(id,user){if(!UUID.test(id||''))throw failure(400,'Choose a pilot session.');const [rows,legs]=await Promise.all([database('dialer_parallel_sessions?'+new URLSearchParams({id:'eq.'+id,...(user?{user_id:'eq.'+user}:{}),select:'*'})),database('dialer_parallel_legs?'+new URLSearchParams({session_id:'eq.'+id,order:'position.asc',select:'*'}))]);if(rows.length!==1)throw failure(404,'Pilot session unavailable.');return {...rows[0],legs};}
function alive(s){return !['stopping','complete'].includes(s.state)&&Date.parse(s.expires_at)>Date.now()&&Date.parse(s.heartbeat_at)>Date.now()-(s.state==='connected'?90000:35000);}
function publicState(s){const agentMinutes=Math.ceil((s.agent_seconds||0)/60),phoneCost=s.legs.reduce((n,l)=>n+Math.ceil(l.duration_seconds/60)*Number(l.rate),0),answered=s.legs.filter(l=>l.answer||l.duration_seconds>0).length,winner=s.legs.find(l=>l.id===s.winner_id);return {id:s.id,kind:s.kind||'test',maxSeconds:s.max_seconds||90,state:s.state,connectMode:s.connect_mode||'human',callerId:s.caller_id,winnerId:s.winner_id,expiresAt:s.expires_at,
 estimatedUsd:Number((phoneCost+(s.connect_mode==='fast'?0:answered*0.0075)+agentMinutes*0.004+(agentMinutes+Math.ceil((winner?.duration_seconds||0)/60))*0.0018).toFixed(4)),
 legs:s.legs.map(l=>({id:l.id,leadId:l.lead_id,errorCode:l.error_code,position:l.position,phone:l.phone,state:l.state,answer:l.confirmed_at?'confirmed':l.answer,pickedUp:!!l.pickup_at,outcome:l.outcome,durationSeconds:l.duration_seconds,phoneCostUsd:l.price_usd,detectionMs:l.detection_ms}))};}
async function leadUpdates(s,user,details=false){const ids=s.kind==='leads'?s.legs.filter(l=>details||followups.has(l.outcome)).map(l=>l.lead_id).filter(Boolean):[];return ids.length?require('./dialer-power').leads(user,ids):[];}
async function allowance(user){const rows=await database('dialer_parallel_sessions?'+new URLSearchParams({user_id:'eq.'+user,created_at:'gt.'+new Date(Date.now()-86400000).toISOString(),select:'reserved_cents'}));return {reservedCents:rows.reduce((n,s)=>n+s.reserved_cents,0),limitCents:500,maxTests:10};}
function normalize(value){const raw=String(value||'');if(!/^[+0-9().\s-]+$/.test(raw))throw failure(400,'Enter a valid US phone number.');let digits=raw.replace(/\D/g,'');if(digits.length===10)digits='1'+digits;const phone='+'+digits;if(!PHONE.test(phone))throw failure(400,'Enter a valid US phone number.');return phone;}
async function price(phone,caller,c){const r=await fetch('https://pricing.twilio.com/v2/Voice/Numbers/'+encodeURIComponent(phone)+'?'+new URLSearchParams({OriginationNumber:caller}),{headers:{Authorization:'Basic '+Buffer.from(c.TWILIO_ACCOUNT_SID+':'+c.TWILIO_AUTH_TOKEN).toString('base64')},signal:AbortSignal.timeout(8000)});if(!r.ok)throw failure(503,'Could not verify this number’s calling rate. No calls were placed.');const d=await r.json(),prices=d.outbound_call_prices;if(d.destination_number!==phone||d.iso_country!=='US'||String(d.price_unit).toUpperCase()!=='USD'||!Array.isArray(prices)||!prices.length||prices.some(p=>!/^\d+(\.\d+)?$/.test(String(p.current_price))||Number(p.current_price)<=0||Number(p.current_price)>0.014))throw failure(400,'Power Dialer accepts standard-rate US numbers only.');return Math.max(...prices.map(p=>Number(p.current_price)));}
async function options(u){await require('./dialer-full-billing').ensureFresh(u);const [numbers,old,sessions,budget]=await Promise.all([database('dialer_numbers?'+new URLSearchParams({user_id:'eq.'+u.id,livemode:'eq.true',state:'eq.active',select:'phone'})),database('master_dialer_numbers?'+new URLSearchParams({user_id:'eq.'+u.id,state:'eq.active',select:'phone_number'})),database('dialer_parallel_sessions?'+new URLSearchParams({user_id:'eq.'+u.id,select:'id,state,kind,created_at,expires_at',order:'created_at.desc',limit:'10'})),allowance(u.id)]);return {canCall:!!await rpc('dialer_entitled',{p_user:u.id,p_live:true}),numbers:[...new Set([...numbers.map(n=>n.phone),...old.map(n=>n.phone_number)])],sessions,budget};}
async function prepare(u,b){if(u.id!==MASTER&&!provider.eligible(u))throw failure(403,'Use Power Dialer with your assigned leads.');if(b.testPhonesConfirmed!==true||b.acceptCharges!==true)throw failure(400,'Confirm these are consenting test phones and accept the displayed provider charges.');if(!UUID.test(b.id||'')||!Array.isArray(b.phones)||b.phones.length<1||b.phones.length>3||!PHONE.test(b.callerId||''))throw failure(400,'Choose a caller ID and one to three test phones.');const connectMode=b.connectMode??'human';if(!['fast','human'].includes(connectMode))throw failure(400,'Choose a connection mode.');const phones=b.phones.map(normalize);if(new Set(phones).size!==phones.length||phones.includes(b.callerId))throw failure(400,'Use distinct test phones, different from your caller ID.');const allowed=await options(u);if(!allowed.numbers.includes(b.callerId))throw failure(403,'Choose an active caller ID belonging to your account.');if(u.id!==MASTER){await require('./dialer-full-billing').sync(u);if(!await rpc('dialer_entitled',{p_user:u.id,p_live:true}))throw failure(403,'Complete your actual-cost payment and calling setup in Numbers & billing first.');}const c=await provider.context(u),rates=await Promise.all(phones.map(p=>price(p,b.callerId,c)));await rpc('dialer_parallel_prepare_mode',{p_user:u.id,p_session:u.sessionId,p_id:b.id,p_account:c.TWILIO_ACCOUNT_SID,p_caller:b.callerId,p_phones:phones,p_rates:rates,p_mode:connectMode});const s=await get(b.id,u.id);if(s.session_id!==u.sessionId||s.state!=='prepared'||!alive(s))throw failure(409,'This pilot has already started or expired.');return {...tokens(s,c),session:publicState(s),budget:await allowance(u.id)};}
function conference(s,agent){const attributes=agent?' startConferenceOnEnter="true" endConferenceOnExit="true" participantLabel="agent" statusCallback="'+escape(hook(s.id,'conference'))+'" statusCallbackEvent="join leave end" statusCallbackMethod="POST"':' startConferenceOnEnter="true" endConferenceOnExit="true" participantLabel="winner"';return '<Dial timeLimit="'+(s.kind==='leads'?(s.max_seconds||1800)+60:120)+'" record="do-not-record"><Conference beep="false" maxParticipants="2" record="do-not-record" waitUrl=""'+attributes+'>'+identity(s.id)+'</Conference></Dial><Hangup/>';}
async function voice(req,res){try{const b=req.body,c=await provider.callbackContext(b?.AccountSid);if(req.method!=='POST'||!validSignature(req,b,c,['/api/dialer/voice'])||b.AccountSid!==c.TWILIO_ACCOUNT_SID||!SID.test(b.CallSid||''))throw failure(403,'Invalid signature.');const p=grant(b.ParallelGrant,c),s=await get(p.id,p.sub);if(b.From!=='client:'+identity(s.id)||s.provider_sid!==c.TWILIO_ACCOUNT_SID)throw failure(403,'Pilot ownership mismatch.');const r=await event(s.id,'agent',null,b.CallSid);if(r.result!=='agent')return xml(res,'<Hangup/>');return xml(res,conference(s,true));}catch(e){return xml(res,'<Hangup/>',e.status||503);}}
async function launch(s){if(!alive(s))throw failure(409,'Batch expired. Start a new batch.');if((await event(s.id,'launch')).result!=='launch')return;
 const create=async leg=>{if((await event(s.id,'claim',leg.id)).result!=='create')return;let created;
  try{const params=new URLSearchParams({To:leg.phone,From:s.caller_id,Url:hook(s.id,'answer',leg.id),Method:'POST',Timeout:'20',TimeLimit:String(s.kind==='leads'?s.max_seconds:90),StatusCallback:hook(s.id,'status',leg.id),StatusCallbackMethod:'POST'});if(s.connect_mode!=='fast'){params.set('MachineDetection','Enable');params.set('AsyncAmd','false');params.set('MachineDetectionTimeout','10');}for(const status of ['initiated','ringing','answered','completed'])params.append('StatusCallbackEvent',status);
   created=await callProvider(s,'Calls.json',params);if(!SID.test(created?.sid||'')||created.account_sid!==s.provider_sid)throw Error('Invalid provider response');await event(s.id,'bind',leg.id,created.sid);
   const fresh=await get(s.id),currentLeg=fresh.legs.find(l=>l.id===leg.id);if(!alive(fresh))await stopLeg(fresh,currentLeg);else if(fresh.winner_id&&fresh.winner_id!==leg.id)await stopLeg(fresh,currentLeg,true);
  }catch(e){if(!created&&e.definitive){await event(s.id,'reject',leg.id,null,null,e.providerCode||0);return;}await database('dialer_parallel_legs?id=eq.'+leg.id,{outcome:'creation_uncertain'},'PATCH');await event(s.id,'stop');throw failure(503,'A call could not be confirmed. The batch is stopping; check Recent batches before trying again.');}
 };
 const results=s.kind==='leads'?await Promise.allSettled(s.legs.map(create)):await (async()=>{const result=[];for(const leg of s.legs){try{await create(leg);result.push({status:'fulfilled'});}catch(reason){result.push({status:'rejected',reason});break;}}return result;})();
 const rejected=results.find(r=>r.status==='rejected');const fresh=await get(s.id);
 if(rejected||fresh.legs.every(l=>l.terminal)){await stop(fresh);if(rejected)throw rejected.reason;}
}

async function stopLeg(s,l,winnerCleanup=false){if(l&&s.kind==='leads'&&l.state==='creating'&&!l.provider_sid){
 const d=await callProvider(s,'Calls.json?'+new URLSearchParams({To:l.phone,From:s.caller_id,PageSize:'1000'}));
 if(d.next_page_uri)throw Error('Call recovery needs another page');
 const candidates=(d.calls||[]).filter(c=>c.to===l.phone&&c.from===s.caller_id&&c.direction==='outbound-api'&&Date.parse(c.date_created)>=Math.floor(Date.parse(s.created_at)/1000)*1000&&Date.parse(c.date_created)<=Date.parse(s.created_at)+120000);
 const recorded=candidates.length?await database('dialer_calls?'+new URLSearchParams({user_id:'eq.'+s.user_id,or:'(parent_sid.in.('+candidates.map(c=>c.sid).join(',')+'),child_sid.in.('+candidates.map(c=>c.sid).join(',')+'))',select:'id,parent_sid,child_sid'})):[];
 const matches=candidates.filter(c=>!recorded.some(row=>row.id!==l.id&&(row.parent_sid===c.sid||row.child_sid===c.sid)));
 if(matches.length===1){await event(s.id,'bind',l.id,matches[0].sid);l={...l,provider_sid:matches[0].sid};}
 else if(!matches.length&&Date.now()-Date.parse(s.created_at)>120000){await event(s.id,'reject',l.id,null,null,0);return true;}
 else return false;
 }
 if(!l?.provider_sid)return !l||l.terminal||l.state==='prepared';let call=await callProvider(s,'Calls/'+l.provider_sid+'.json');if(call.account_sid!==s.provider_sid||call.to!==l.phone||call.from!==s.caller_id)throw Error('Provider ownership mismatch');
 if(winnerCleanup&&await preservePickup(s,l,call))return false;
 if(!terminal.has(call.status)){
  try{call=await callProvider(s,'Calls/'+l.provider_sid+'.json',{Status:['queued','ringing'].includes(call.status)?'canceled':'completed'});}catch{
   call=await callProvider(s,'Calls/'+l.provider_sid+'.json');
   // A recipient may pick up between GET and cancel. Do not turn that race into a hangup.
   if(winnerCleanup&&await preservePickup(s,l,call))return false;
   if(!terminal.has(call.status))call=await callProvider(s,'Calls/'+l.provider_sid+'.json',{Status:'completed'});
  }
 }
 if(terminal.has(call.status))await event(s.id,'status',l.id,l.provider_sid,call.status,Number(call.duration)||0);
 if(call.price_unit==='USD'||call.price_unit==='usd'){const p=Number(call.price);if(call.price!==null&&Number.isFinite(p))await database('dialer_parallel_legs?id=eq.'+l.id,{price_usd:Math.abs(p)},'PATCH');}
 return terminal.has(call.status);
}
async function preservePickup(s,l,call){
 if(call.status!=='in-progress')return false;
 if(!l.pickup_at)await event(s.id,'status',l.id,l.provider_sid,'in-progress');
 const fresh=await get(s.id),leg=fresh.legs.find(x=>x.id===l.id);
 if(!alive(fresh))return false;if(fresh.winner_id===leg.id)return true;
 const deadline=leg.outcome==='second_answer'?Date.parse(leg.confirmed_at||leg.followup_noted_at||leg.pickup_at)+30000
  :!leg.answer?Date.parse(leg.pickup_at)+15000:0;
 return Date.now()<deadline;
}
async function stop(s){await event(s.id,'stop');let errors=0;for(const l of s.legs)try{if(!await stopLeg(s,l))errors++;}catch{errors++;}
 if(s.agent_sid)try{let call=await callProvider(s,'Calls/'+s.agent_sid+'.json');if(call.account_sid!==s.provider_sid||call.from!=='client:'+identity(s.id))throw Error('Agent ownership mismatch');if(!terminal.has(call.status))call=await callProvider(s,'Calls/'+s.agent_sid+'.json',{Status:'completed'});if(!terminal.has(call.status))errors++;await database('dialer_parallel_sessions?id=eq.'+s.id,{agent_seconds:Number(call.duration)||0},'PATCH');}catch{errors++;}
 if(!errors||(s.kind!=='leads'&&Date.parse(s.expires_at)<Date.now()-60000))await event(s.id,'complete');return errors;
}
async function cancelOthers(s){let errors=0;for(const l of s.legs)if(l.id!==s.winner_id&&!l.terminal)try{await stopLeg(s,l,true);}catch{errors++;}return errors;}
function answerResponse(res,s,l,result){
 if(result==='winner')return xml(res,conference(s,false));
 if(result==='overflow')return xml(res,s.kind==='leads'?'<Say>We are sorry we could not connect you to your insurance agent. Please call '+escape(s.caller_id.split('').join(' '))+' to reach your agent or leave a message. Thank you.</Say><Hangup/>':'<Say>This is a Vivid Life dialer test. Another test phone answered first. This test call will now end.</Say><Hangup/>');
 return xml(res,'<Hangup/>');
}
async function events(req,res){res.setHeader('Cache-Control','no-store');try{
 const b=req.body,url=new URL(req.url,ORIGIN),id=url.searchParams.get('id'),kind=url.searchParams.get('kind'),legId=url.searchParams.get('leg');
 const s=await get(id);if(b?.AccountSid!==s.provider_sid)throw failure(403,'Provider mismatch.');const c=await storedContext(s);
 if(req.method!=='POST'||!validSignature(req,b,c,[ROUTE])||b.AccountSid!==c.TWILIO_ACCOUNT_SID||url.pathname!==ROUTE)throw failure(403,'Invalid signature.');
 if(s.provider_sid!==b.AccountSid)throw failure(403,'Provider mismatch.');
 if(kind==='conference'){
  if(b.FriendlyName!==identity(s.id)||!/^CF[0-9a-f]{32}$/i.test(b.ConferenceSid||'')||(s.conference_sid&&s.conference_sid!==b.ConferenceSid))throw failure(403,'Conference mismatch.');
  if(b.StatusCallbackEvent==='participant-join'&&b.CallSid===s.agent_sid)await event(id,'ready',null,b.CallSid,b.ConferenceSid);
  if(b.StatusCallbackEvent==='conference-end'||(b.StatusCallbackEvent==='participant-leave'&&(b.CallSid===s.agent_sid||s.legs.some(l=>l.id===s.winner_id&&l.provider_sid===b.CallSid))))await stop(s);
  return res.status(204).end();
 }
 const l=s.legs.find(x=>x.id===legId);if(!l||!SID.test(b.CallSid||'')||b.To!==l.phone||b.From!==s.caller_id||(l.provider_sid&&l.provider_sid!==b.CallSid))throw failure(403,'Call ownership mismatch.');
 if(kind==='answer'){
  const answer=s.connect_mode==='fast'?'answered':b.AnsweredBy==='human'?'human':b.AnsweredBy?.startsWith('machine')?'machine':b.AnsweredBy==='fax'?'fax':'unknown';
  const detectionMs=s.connect_mode!=='fast'&&/^\d+$/.test(b.MachineDetectionDuration||'')?Math.min(Number(b.MachineDetectionDuration),60000):0;const r=await event(id,'answer',l.id,b.CallSid,answer,detectionMs);
  return answerResponse(res,s,l,r.result);
 }
 // Retired callbacks must never play a prompt or connect a call.
 if(kind==='confirm')return xml(res,'<Hangup/>');
 if(kind==='status'){
  await event(id,'status',l.id,b.CallSid,b.CallStatus==='initiated'?'queued':b.CallStatus,Number(b.CallDuration)||0);
  const fresh=await get(id);if(l.id===fresh.winner_id&&terminal.has(b.CallStatus)||fresh.legs.every(x=>x.terminal))await stop(fresh);
  return res.status(204).end();
 }
 throw failure(400,'Unknown event.');
 }catch(e){return xml(res,'<Hangup/>',e.status||503);}
}
async function allowed(u){return !!(u.live&&await rpc('dialer_parallel_allowed',{p_user:u.id}));}
async function action(req,u){const b=req.body,enabled=await allowed(u);if(b.action==='access')return {allowed:enabled,atCost:enabled&&provider.eligible(u)};if(!u.live||(!enabled&&!['stop','status'].includes(b.action)))throw failure(403,'Power Dialer requires an active agent or admin account.');if(b.action==='options')return options(u);if(b.action==='prepareLeads')return require('./dialer-power').prepare(u,b);if(b.action==='prepare')return prepare(u,b);const s=await get(b.id,u.id);
 if(b.action==='stop'){await stop(s);if(u.onboardingRestricted)return {stopped:true};const fresh=await get(s.id);return {session:publicState(fresh),leads:await leadUpdates(fresh,u.id),budget:await allowance(u.id)};}
 if(b.action==='launch'){await require('./dialer-full-billing').ensureFresh(u);if(!await rpc('dialer_entitled',{p_user:u.id,p_live:true}))throw failure(403,'Your calling access needs attention. Check Numbers & billing.');if(s.session_id!==u.sessionId)throw failure(403,'Open the pilot in its original signed-in session.');await launch(s);return {session:publicState(await get(s.id))};}
 if(b.action==='status'){
  if(s.kind==='leads'&&enabled&&alive(s))await require('./dialer-full-billing').ensureFresh(u);
  if(enabled&&b.heartbeat===true&&s.session_id===u.sessionId&&alive(s))await database('dialer_parallel_sessions?id=eq.'+s.id,{heartbeat_at:new Date().toISOString()},'PATCH');
  if((!enabled||!alive(s))&&s.state!=='complete')await stop(s);else if(s.winner_id)await cancelOthers(s);
  const fresh=await get(s.id);return {session:publicState(fresh),leads:await leadUpdates(fresh,u.id,b.details===true),budget:await allowance(u.id)};
 }
 throw failure(400,'Unknown pilot action.');
}
async function maintenance(){if(!mode())return {checked:0};const rows=await database('dialer_parallel_sessions?'+new URLSearchParams({state:'neq.complete',select:'id',order:'created_at.asc',limit:'15'}));let errors=0;for(const row of rows)try{const s=await get(row.id);if(!alive(s))errors+=await stop(s);else if(s.winner_id)errors+=await cancelOthers(s);}catch{errors++;}return {checked:rows.length,errors};}
async function reconcileUsage(u,start){if(!u.live)return;
 const rows=await database('dialer_parallel_sessions?'+new URLSearchParams({user_id:'eq.'+u.id,kind:'eq.leads',state:'neq.complete',select:'id',limit:'20'}));
 for(const row of rows){const s=await get(row.id);if(!alive(s))await stop(s);}
 if(start){const outstanding=await database('dialer_calls?'+new URLSearchParams({user_id:'eq.'+u.id,livemode:'eq.'+u.live,period_start:'eq.'+start,call_kind:'eq.power',finished:'eq.false',select:'id',limit:'1'}));if(outstanding.length)throw failure(503,'Power Dialer usage is awaiting provider confirmation.');}
}
module.exports={reconcileUsage,storedContext,callProvider,allowed,action,events,voice,maintenance,normalize,price,grant,tokens,publicState,alive,stop,launch,event,get};
