'use strict';
const {randomUUID,randomBytes,createHash,timingSafeEqual}=require('node:crypto');
const {database,rpc,failure,UUID,MASTER,ORIGIN,config}=require('./dialer-full');
const parallel=require('./dialer-parallel');
const {wav}=require('./dialer-recording-audio');
const BASE='https://yfuuigykpihoetgaefmu.supabase.co',BUCKET='dialer-recordings',PHONE='+12482383969';
const digest=v=>createHash('sha256').update(v).digest('hex');
const patch=(id,body,filter='')=>database('dialer_private_recordings?id=eq.'+id+filter,body,'PATCH');
async function get(id){if(!UUID.test(id||''))throw failure(400,'Invalid recording');return (await database('dialer_private_recordings?id=eq.'+id+'&select=*'))[0];}
async function storage(path,options={}){
 const key=process.env.SUPABASE_SECRET_KEY;if(!/^sb_secret_[\w-]+$/.test(key||''))throw failure(503,'Private storage unavailable');
 return fetch(BASE+'/storage/v1/'+path,{...options,headers:{apikey:key,Authorization:'Bearer '+key,...options.headers},signal:AbortSignal.timeout(20000)});
}
async function upload(path,audio){const r=await storage('object/'+BUCKET+'/'+path,{method:'POST',headers:{'Content-Type':'audio/wav','x-upsert':'true','Cache-Control':'no-store'},body:audio});if(!r.ok)throw Error('Private audio upload failed');}
async function provider(r,path,body){
 // Deliberately no API that creates a Twilio Recording. Only Streams and reads.
 if(!/^Calls\/CA[0-9a-f]{32}\/((Streams(?:\/MT[0-9a-f]{32})?\.json)|(Recordings\.json))$/i.test(path)||path.includes('Recordings')&&body)throw Error('Forbidden provider operation');
 const c=config();if(r.provider_sid!==c.TWILIO_ACCOUNT_SID)throw Error('Unsupported test provider');
 const response=await fetch('https://api.twilio.com/2010-04-01/Accounts/'+c.TWILIO_ACCOUNT_SID+'/'+path,{method:body?'POST':'GET',headers:{Authorization:'Basic '+Buffer.from(c.TWILIO_ACCOUNT_SID+':'+c.TWILIO_AUTH_TOKEN).toString('base64'),...(body?{'Content-Type':'application/x-www-form-urlencoded'}:{})},...(body?{body:new URLSearchParams(body)}:{}),signal:AbortSignal.timeout(15000)});
 if(!response.ok)throw Error('Streaming provider request failed');return response.json();
}
async function candidates(u){if(u.id!==MASTER||!u.live)return [];
 const sessions=await database('dialer_parallel_sessions?'+new URLSearchParams({user_id:'eq.'+u.id,session_id:'eq.'+u.sessionId,state:'eq.connected',select:'id',limit:'3'}));const result=[];
 for(const row of sessions){const s=await parallel.get(row.id,u.id),winner=s.legs.find(l=>l.id===s.winner_id);if(winner?.phone===PHONE&&!winner.terminal&&parallel.alive(s))result.push({id:s.id,phone:PHONE,label:'Peters main phone'});}return result;
}
async function action(req,u){
 const b=req.body;
 if(b.action==='list')return {recordings:await rpc('dialer_recordings_access',{p_actor:u.id,p_session:u.sessionId}),testAllowed:u.id===MASTER&&u.live,candidates:await candidates(u)};
 if(b.action==='play'){
  if(!UUID.test(b.id||''))throw failure(400,'Choose a recording');
  const r=await rpc('dialer_recordings_access',{p_actor:u.id,p_session:u.sessionId,p_id:b.id}),path=r.user_id+'/'+r.id+'/conversation.wav';
  if(!['ready','partial'].includes(r.state)||r.audio_path!==path)throw failure(409,'Audio is still being saved');
  const response=await storage('object/sign/'+BUCKET+'/'+path,{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({expiresIn:900})});
  if(!response.ok)throw failure(503,'Playback unavailable');const d=await response.json(),signed=d.signedURL||d.signedUrl;
  if(typeof signed!=='string'||!signed.startsWith('/object/sign/'+BUCKET+'/'))throw Error('Invalid playback URL');
  return {url:BASE+'/storage/v1'+signed};
 }
 if(u.id!==MASTER||!u.live)throw failure(403,'Recording is limited to the owner test');
 if(b.action==='start'){
  if(b.consent!==true)throw failure(400,'Confirm everyone on the test call agrees to recording');
  if(!UUID.test(b.powerId||'')||!(await candidates(u)).some(s=>s.id===b.powerId))throw failure(409,'Connect a Power Dialer call to Peters main phone first');
  const s=await parallel.get(b.powerId,u.id),winner=s.legs.find(l=>l.id===s.winner_id);
  if(s.provider_sid!==config().TWILIO_ACCOUNT_SID||!/^CA[a-f0-9]{32}$/i.test(s.agent_sid||''))throw failure(409,'Call not ready');
  const existing=await database('dialer_private_recordings?power_id=eq.'+s.id+'&select=id');if(existing.length)throw failure(409,'This call already has a recording attempt. Use a new test call.');
  const state=await parallel.callProvider(s,'Calls/'+s.agent_sid+'.json');if(state.status!=='in-progress')throw failure(409,'Call has ended');
  const id=randomUUID(),grant=randomBytes(32).toString('hex'),r={id,user_id:u.id,power_id:s.id,lead_id:winner.lead_id,phone:PHONE,client_name:'Peters main phone',provider_sid:s.provider_sid,call_sid:s.agent_sid,grant_hash:digest(grant)};
  await database('dialer_private_recordings',r);
  try{
   const stream=await provider(r,'Calls/'+s.agent_sid+'/Streams.json',{Url:ORIGIN.replace('https:','wss:')+'/api/dialer/recording-stream',Track:'both_tracks',Name:'portal_'+id,'Parameter1.Name':'recordingId','Parameter1.Value':id,'Parameter2.Name':'grant','Parameter2.Value':grant});
   if(!/^MT[a-f0-9]{32}$/i.test(stream.sid||''))throw Error('Stream was not confirmed');
   // The websocket can consume the grant before this request returns.
   await patch(id,{stream_sid:stream.sid},'&stream_sid=is.null');return {id};
  }catch{await patch(id,{issue:'Stream start could not be confirmed. Check recording status before trying another call.'});throw failure(503,'Stream start could not be confirmed. The call continues normally.');}
 }
 if(b.action==='stop'){
  const r=await get(b.id);if(!r||r.user_id!==u.id)throw failure(404,'Recording unavailable');
  if(r.stream_sid&&['starting','streaming'].includes(r.state))await provider(r,'Calls/'+r.call_sid+'/Streams/'+r.stream_sid+'.json',{Status:'stopped'});
  return {ok:true};
 }
 throw failure(400,'Unknown recording action');
}
async function consume(start){
 const id=start?.customParameters?.recordingId,grant=start?.customParameters?.grant;
 if(!UUID.test(id||'')||!/^([a-f0-9]{64})$/.test(grant||''))throw Error('Invalid stream grant');
 const r=await get(id);if(!r||r.user_id!==MASTER||r.phone!==PHONE||r.provider_sid!==start.accountSid||r.call_sid!==start.callSid||r.state!=='starting'||Date.parse(r.grant_expires_at)<=Date.now()||!/^MT[a-f0-9]{32}$/i.test(start.streamSid||'')||(r.stream_sid&&r.stream_sid!==start.streamSid))throw Error('Stream access denied');
 const actual=Buffer.from(digest(grant)),expected=Buffer.from(r.grant_hash);if(actual.length!==expected.length||!timingSafeEqual(actual,expected))throw Error('Invalid stream grant');
 if(start.mediaFormat?.encoding!=='audio/x-mulaw'||start.mediaFormat.sampleRate!==8000||start.mediaFormat.channels!==1||!start.tracks?.includes('inbound')||!start.tracks?.includes('outbound'))throw Error('Unsupported audio format');
 const claimed=await patch(id,{state:'streaming',stream_sid:start.streamSid,heartbeat_at:new Date().toISOString()},'&state=eq.starting');if(claimed.length!==1)throw Error('Stream already consumed');return {...r,stream_sid:start.streamSid};
}
async function savePart(r,position,audio,samples){
 const path=r.user_id+'/'+r.id+'/parts/'+String(position).padStart(3,'0')+'.wav';await upload(path,audio);
 await database('dialer_recording_parts',{recording_id:r.id,position,path,samples,sha256:digest(audio)});
 await patch(r.id,{heartbeat_at:new Date().toISOString()});
}
async function finish(r,partial,issue){
 await patch(r.id,{state:'processing',stopped_at:new Date().toISOString(),...(partial?{issue:issue||'Recording interrupted; saved audio may be incomplete.'}:{issue:null})},'&state=in.(starting,streaming)');
 return finalize(await get(r.id));
}
async function finalize(r){
 if(!r||r.state!=='processing')return;
 const parts=await database('dialer_recording_parts?'+new URLSearchParams({recording_id:'eq.'+r.id,order:'position.asc',select:'*'}));
 if(!parts.length){await patch(r.id,{state:'failed',issue:'No audio was received. No call recording was saved.'});return;}
 const pcm=[];let samples=0;
 for(let i=0;i<parts.length;i++){
  const p=parts[i],path=r.user_id+'/'+r.id+'/parts/'+String(i).padStart(3,'0')+'.wav';if(p.position!==i||p.path!==path)throw Error('Audio parts incomplete');
  const response=await storage('object/authenticated/'+BUCKET+'/'+path);if(!response.ok)throw Error('Audio part unavailable');
  const audio=Buffer.from(await response.arrayBuffer());if(audio.length!==44+p.samples*4||digest(audio)!==p.sha256)throw Error('Audio integrity check failed');pcm.push(audio.subarray(44));samples+=p.samples;if(samples>4800000)throw Error('Audio exceeds test limit');
 }
 const path=r.user_id+'/'+r.id+'/conversation.wav';await upload(path,wav(Buffer.concat(pcm)));
 // Verify no saved Twilio recording exists on either side of this test.
 let checked=false;try{const s=await parallel.get(r.power_id),winner=s.legs.find(l=>l.id===s.winner_id);const calls=[r.call_sid,winner?.provider_sid].filter(Boolean);checked=calls.length===2;for(const sid of calls){const d=await provider(r,'Calls/'+sid+'/Recordings.json');if(!Array.isArray(d.recordings)||d.recordings.length||d.next_page_uri)checked=false;}}catch{checked=false;}
 await patch(r.id,{audio_path:path,duration_ms:samples/8,state:r.issue?'partial':'ready',provider_recordings_checked:checked});
}
async function maintenance(){
 const rows=await database('dialer_private_recordings?'+new URLSearchParams({or:'(state.eq.processing,and(state.in.(starting,streaming),heartbeat_at.lt.'+new Date(Date.now()-90000).toISOString()+'))',order:'created_at.asc',limit:'5'}));let errors=0;
 for(const r of rows)try{if(r.state==='processing')await finalize(r);else await finish(r,true,'Stream ended unexpectedly. Previously saved audio recovered.');}catch{errors++;}
 return {checked:rows.length,errors};
}
module.exports={action,consume,savePart,finish,maintenance,provider,get};
