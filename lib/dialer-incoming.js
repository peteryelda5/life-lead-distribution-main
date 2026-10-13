'use strict';
const {createHmac,timingSafeEqual}=require('node:crypto');
const {database,rpc,config,ORIGIN,MASTER,mode,failure}=require('./dialer-full');
const provider=require('./dialer-at-cost-provider');
const BASE='https://yfuuigykpihoetgaefmu.supabase.co',BUCKET='dialer-voicemails';
const SID=/^CA[0-9a-f]{32}$/i,RECORDING=/^RE[0-9a-f]{32}$/i;
const escape=value=>String(value).replace(/[&<>"']/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&apos;'}[c]));
function xml(res,body,status=200){res.setHeader('Cache-Control','no-store');res.setHeader('Content-Type','text/xml; charset=utf-8');return res.status(status).send('<?xml version="1.0" encoding="UTF-8"?><Response>'+body+'</Response>');}
function validSignature(req,body,c,paths){
 if(!['GET','POST'].includes(req.method)||!body||typeof body!=='object'||Array.isArray(body))return false;
 if(req.method==='POST'&&!/^application\/x-www-form-urlencoded(?:;|$)/i.test(req.headers['content-type']||''))return false;
 if(Object.values(body).some(v=>typeof v!=='string'))return false;
 const query=(req.url||'').includes('?')?(req.url||'').slice(req.url.indexOf('?')):'';
 return paths.some(path=>{let input=ORIGIN+path+query;if(req.method==='POST')for(const key of Object.keys(body).sort())input+=key+body[key];
  const expected=Buffer.from(createHmac('sha1',c.TWILIO_AUTH_TOKEN).update(input).digest('base64')),given=Buffer.from(req.headers['x-twilio-signature']||'');return expected.length===given.length&&timingSafeEqual(expected,given);});
}
async function signedRequest(req,paths){
 const b=req.method==='GET'?Object.fromEntries(new URL(req.url,ORIGIN).searchParams):req.body;
 if(!b||!SID.test(b.CallSid||'')||!/^AC[0-9a-f]{32}$/i.test(b.AccountSid||''))throw failure(403,'Invalid call.');
 const c=await provider.callbackContext(b.AccountSid);
 if(!validSignature(req,b,c,paths)||c.TWILIO_ACCOUNT_SID!==b.AccountSid)throw failure(403,'Invalid signature.');return {b,c};
}
async function ownedCall(account,parent){if(!SID.test(parent||''))throw failure(403,'Invalid call.');const rows=await database('dialer_callbacks?'+new URLSearchParams({provider_sid:'eq.'+account,parent_sid:'eq.'+parent,select:'*',limit:'1'}));if(rows.length!==1)throw failure(403,'Unknown callback.');return rows[0];}
const event=(b,name,seconds=0)=>rpc('dialer_callback_event',{p_account:b.AccountSid,p_parent:b.ParentCallSid||b.CallSid,p_event:name,p_seconds:seconds});
function voicemail(){return '<Say voice="alice">Please leave your name, number, and a message after the tone.</Say><Record maxLength="120" timeout="5" playBeep="true" trim="trim-silence" action="'+ORIGIN+'/api/dialer/incoming-finish" method="POST" recordingStatusCallback="'+ORIGIN+'/api/dialer/incoming-recording" recordingStatusCallbackMethod="POST" recordingStatusCallbackEvent="completed absent"/><Hangup/>';}
async function incoming(req,res){try{
 const {b,c}=await signedRequest(req,['/dialer-inbound.xml','/api/dialer/incoming']);
 if(!/^\+1[2-9]\d{2}[2-9]\d{6}$/.test(b.To||''))throw failure(403,'Invalid destination.');
 const rows=await database('dialer_numbers?'+new URLSearchParams({phone:'eq.'+b.To,state:'eq.active',select:'user_id,livemode',limit:'2'}));
 let u;if(rows.length===1)u={id:rows[0].user_id,live:rows[0].livemode};
 else if(!rows.length){const legacy=await database('master_dialer_numbers?'+new URLSearchParams({phone_number:'eq.'+b.To,state:'eq.active',user_id:'eq.'+MASTER,select:'user_id',limit:'1'}));if(legacy.length)u={id:MASTER,live:true};}
 if(!u||!u.live||!mode())throw failure(403,'Number unavailable.');
 const expected=provider.eligible(u)?(await provider.row(u)).provider_sid:config().TWILIO_ACCOUNT_SID;
 if(expected!==c.TWILIO_ACCOUNT_SID)throw failure(403,'Number ownership mismatch.');
 const call=await rpc('dialer_callback_start',{p_user:u.id,p_live:u.live,p_account:b.AccountSid,p_parent:b.CallSid,p_from:b.From||'Unknown caller',p_to:b.To});
 if(!call.identity){await event(b,'recording');return xml(res,voicemail());}
 return xml(res,'<Dial timeout="25" timeLimit="1800" answerOnBridge="true" record="do-not-record" action="'+ORIGIN+'/api/dialer/incoming-action" method="POST"><Client statusCallback="'+ORIGIN+'/api/dialer/incoming-status" statusCallbackEvent="answered completed" statusCallbackMethod="POST"><Identity>'+escape(call.identity)+'</Identity><Parameter name="CallbackId" value="'+escape(call.id)+'"/></Client></Dial>');
 }catch(e){console.error('incoming_route_failed',{status:e.status||503});return xml(res,'<Hangup/>',e.status===403?403:503);}}
async function action(req,res){try{const {b}=await signedRequest(req,['/api/dialer/incoming-action']);await ownedCall(b.AccountSid,b.CallSid);
 if(b.DialCallStatus==='completed'){await event(b,'completed',seconds(b.DialCallDuration,7200));return xml(res,'<Hangup/>');}
 await event(b,'missed');await event(b,'recording');return xml(res,voicemail());
 }catch(e){return xml(res,'<Hangup/>',e.status===403?403:503);}}
function seconds(value,max){if(!/^\d+$/.test(String(value??'')))throw failure(400,'Invalid duration.');const n=Number(value);if(n>max)throw failure(400,'Invalid duration.');return n;}
async function status(req,res){res.setHeader('Cache-Control','no-store');try{const {b}=await signedRequest(req,['/api/dialer/incoming-status']);await ownedCall(b.AccountSid,b.ParentCallSid);
 if(b.CallStatus==='in-progress')await event(b,'answered');
 else if(b.CallStatus==='completed')await event(b,'completed',seconds(b.CallDuration,7200));
 else if(['busy','failed','no-answer','canceled'].includes(b.CallStatus))await event(b,'missed');
 return res.status(204).end();}catch(e){return res.status(e.status===403?403:503).end();}}
async function finish(req,res){try{const {b}=await signedRequest(req,['/api/dialer/incoming-finish']);await ownedCall(b.AccountSid,b.CallSid);await event(b,'missed');return xml(res,'<Say voice="alice">Thank you. Goodbye.</Say><Hangup/>');}catch(e){return xml(res,'<Hangup/>',e.status===403?403:503);}}
async function storage(path,options={}){const secret=process.env.SUPABASE_SECRET_KEY;if(!/^sb_secret_[\w-]+$/.test(secret||''))throw Error('Storage unavailable');return fetch(BASE+'/storage/v1/object/'+BUCKET+'/'+path,{...options,headers:{apikey:secret,Authorization:'Bearer '+secret,...options.headers},signal:AbortSignal.timeout(15000)});}
async function boundedAudio(response){if(!response.ok||!/^audio\//.test(response.headers.get('content-type')||''))throw Error('Recording is not ready');if(Number(response.headers.get('content-length'))>3145728)throw Error('Recording is too large');const chunks=[];let size=0;for await(const chunk of response.body){size+=chunk.length;if(size>3145728)throw Error('Recording is too large');chunks.push(Buffer.from(chunk));}if(!size)throw Error('Recording is empty');return Buffer.concat(chunks);}
async function archiveRecording(call,c,recording,duration){
 if(!RECORDING.test(recording)||duration<0||duration>125)throw failure(400,'Invalid recording.');
 if(call.recording_sid&&call.recording_sid!==recording)throw failure(409,'Recording mismatch.');
 const path=call.user_id+'/'+call.id+'/'+recording+'.mp3';
 if(!call.recording_path){
  const base='https://api.twilio.com/2010-04-01/Accounts/'+c.TWILIO_ACCOUNT_SID+'/Recordings/'+recording;
  const metadata=await fetch(base+'.json',{headers:{Authorization:'Basic '+Buffer.from(c.TWILIO_ACCOUNT_SID+':'+c.TWILIO_AUTH_TOKEN).toString('base64')},signal:AbortSignal.timeout(10000)});
  if(!metadata.ok)throw Error('Recording unavailable');const details=await metadata.json();
  if(details.call_sid!==call.parent_sid||details.account_sid!==call.provider_sid||details.source!=='RecordVerb'||details.status!=='completed')throw failure(403,'Recording ownership mismatch.');
  const response=await fetch(base+'.mp3',{headers:{Authorization:'Basic '+Buffer.from(c.TWILIO_ACCOUNT_SID+':'+c.TWILIO_AUTH_TOKEN).toString('base64')},signal:AbortSignal.timeout(15000)});
  const audio=await boundedAudio(response),saved=await storage(path,{method:'POST',headers:{'Content-Type':'audio/mpeg','x-upsert':'true'},body:audio});if(!saved.ok)throw Error('Voicemail storage unavailable');
  await database('dialer_callbacks?id=eq.'+call.id+'&provider_sid=eq.'+call.provider_sid,{recording_sid:recording,recording_path:path,recording_seconds:duration,recording_pending:false,status:'voicemail',completed_at:call.completed_at||new Date().toISOString(),seen_at:null},'PATCH');
 }
 // Remove only this new voicemail's provider copy after the private archive is confirmed.
 try{await provider.scoped({id:call.user_id,live:call.livemode},'Recordings/'+recording+'.json',undefined,'DELETE');}catch(e){if(e.status!==404)throw e;}
 await database('dialer_callbacks?id=eq.'+call.id,{provider_copy_removed:true},'PATCH');
}
async function recording(req,res){res.setHeader('Cache-Control','no-store');try{const {b,c}=await signedRequest(req,['/api/dialer/incoming-recording']);const call=await ownedCall(b.AccountSid,b.CallSid);
 if(['absent','failed'].includes(b.RecordingStatus)){await database('dialer_callbacks?id=eq.'+call.id,{recording_pending:false},'PATCH');return res.status(204).end();}
 if(b.RecordingStatus!=='completed'||b.RecordingSource!=='RecordVerb')throw failure(403,'Invalid recording source.');
 await archiveRecording(call,c,b.RecordingSid,seconds(b.RecordingDuration,125));return res.status(204).end();
 }catch(e){console.error('incoming_recording_failed',{status:e.status||503});return res.status(e.status===403?403:503).end();}}
module.exports={incoming,action,status,finish,recording,archiveRecording,ownedCall,validSignature,voicemail,storage,boundedAudio};
