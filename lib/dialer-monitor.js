'use strict';
const {createHmac,randomUUID}=require('node:crypto');
const {rpc,failure,UUID,ORIGIN}=require('./dialer-full');
const parallel=require('./dialer-parallel'),provider=require('./dialer-at-cost-provider');
const {validSignature}=require('./dialer-incoming');
const manage=(action,args={})=>rpc('dialer_monitor_manage',{p_action:action,...args});
const identity=id=>'vivid_monitor_'+id.replace(/-/g,'');
const sign=(h,p,key)=>{const raw=[h,p].map(x=>Buffer.from(JSON.stringify(x)).toString('base64url')).join('.');return raw+'.'+createHmac('sha256',key).update(raw).digest('base64url');};
function token(m,c){const now=Math.floor(Date.now()/1000);return sign({alg:'HS256',typ:'JWT',cty:'twilio-fpa;v=1'},{jti:c.TWILIO_API_KEY_SID+'-'+randomUUID(),iss:c.TWILIO_API_KEY_SID,sub:c.TWILIO_ACCOUNT_SID,iat:now,exp:now+300,grants:{identity:identity(m.id),voice:{outgoing:{application_sid:c.TWILIO_TWIML_APP_SID},incoming:{allow:false}}}},c.TWILIO_API_KEY_SECRET);}
async function finish(m){if(m.call_sid){const s=await parallel.get(m.power_id);const call=await parallel.callProvider(s,'Calls/'+m.call_sid+'.json');if(!['completed','canceled','failed','busy','no-answer'].includes(call?.status))await parallel.callProvider(s,'Calls/'+m.call_sid+'.json',{Status:'completed'});}await manage('finish',{p_id:m.id,p_sid:m.call_sid});}
async function action(req,u){if(!u.live)throw failure(403,'Live listening is available only in production.');const b=req.body,args={p_actor:u.id,p_session:u.sessionId};
 if(b.action==='list')return {calls:await manage('list',args)};
 if(b.action==='prepare'){
  if(!UUID.test(b.powerId||''))throw failure(400,'Choose a connected call.');const m=await manage('prepare',{...args,p_power:b.powerId});
  try{const s=await parallel.get(m.power_id),c=await parallel.storedContext(s);return {id:m.id,token:token(m,c)};}catch(e){await manage('finish',{p_id:m.id}).catch(()=>{});throw e;}
 }
 if(!UUID.test(b.id||''))throw failure(400,'Choose your listener.');
 if(b.action==='heartbeat'){await manage('heartbeat',{...args,p_id:b.id});return {ok:true};}
 if(b.action==='stop'){const m=await manage('stop',{...args,p_id:b.id});await finish(m);return {ok:true};}
 throw failure(400,'Unknown listening action.');
}
function twiml(id,power){return '<Response><Dial timeLimit="1800" record="do-not-record" action="'+ORIGIN+'/api/dialer/monitor-events?id='+id+'" method="POST"><Conference muted="true" beep="false" startConferenceOnEnter="false" endConferenceOnExit="false" maxParticipants="10" record="do-not-record" waitUrl="" participantLabel="monitor_'+id+'">vivid_parallel_'+power.replace(/-/g,'')+'</Conference></Dial><Hangup/></Response>';}
async function voice(req,res){res.setHeader('Content-Type','text/xml; charset=utf-8');res.setHeader('Cache-Control','no-store');try{
 const b=req.body,c=await provider.callbackContext(b?.AccountSid);if(req.method!=='POST'||!validSignature(req,b,c,['/api/dialer/voice'])||b.AccountSid!==c.TWILIO_ACCOUNT_SID||!UUID.test(b.MonitorGrant||'')||b.From!=='client:'+identity(b.MonitorGrant))throw failure(403,'Invalid listening call.');
 const m=await manage('consume',{p_id:b.MonitorGrant,p_sid:b.CallSid}),s=await parallel.get(m.power_id);if(s.provider_sid!==b.AccountSid)throw failure(403,'Provider mismatch.');
 return res.status(200).send(twiml(m.id,m.power_id));
 }catch{return res.status(403).send('<Response><Hangup/></Response>');}}
async function events(req,res){res.setHeader('Content-Type','text/xml');try{const b=req.body,c=await provider.callbackContext(b?.AccountSid);if(req.method!=='POST'||!validSignature(req,b,c,['/api/dialer/monitor-events'])||!UUID.test(req.query?.id||''))throw Error('Invalid callback');await manage('finish',{p_id:req.query.id,p_sid:b.CallSid,p_seconds:Number(b.DialCallDuration)||0});return res.status(200).send('<Response><Hangup/></Response>');}catch{return res.status(403).send('<Response><Hangup/></Response>');}}
async function maintenance(){const rows=await manage('cleanup');let errors=0;for(const m of rows){try{await finish(m);}catch{errors++;}}return {listeners:rows.length,errors};}
module.exports={action,voice,events,maintenance,twiml};
