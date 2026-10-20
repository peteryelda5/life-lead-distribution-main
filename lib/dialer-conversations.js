'use strict';
const {database,rpc,failure,UUID,ORIGIN,MASTER}=require('./dialer-full');
const provider=require('./dialer-at-cost-provider');
const {validSignature}=require('./dialer-incoming');
const ROUTE='/api/dialer/conversation-events',SERVICE='lld-agent-conversations-v1';
const sid=(prefix,value)=>new RegExp('^'+prefix+'[a-f0-9]{32}$','i').test(value||'');
const sourceQuery=(u,b)=>new URLSearchParams({user_id:'eq.'+u.id,livemode:'eq.'+u.live,kind:'eq.'+b.kind,source_id:'eq.'+b.id,expires_at:'gt.'+new Date().toISOString(),select:'*',limit:'1'});
async function ci(c,path,body,method){
 const r=await fetch('https://intelligence.twilio.com/v2/'+path,{method:method||(body?'POST':'GET'),headers:{Authorization:'Basic '+Buffer.from(c.TWILIO_ACCOUNT_SID+':'+c.TWILIO_AUTH_TOKEN).toString('base64'),...(body?{'Content-Type':'application/x-www-form-urlencoded'}:{})},...(body?{body:new URLSearchParams(body).toString()}:{}),signal:AbortSignal.timeout(10000)});
 if(r.status===204)return null;let d;try{d=await r.json();}catch{throw failure(502,'Twilio AI returned an invalid response.');}
 if(!r.ok){const e=failure(r.status===404?404:503,'Twilio transcription / summaries are unavailable'+(Number(d.code)?' (code '+Number(d.code)+')':'')+'.');e.providerCode=Number(d.code)||r.status;throw e;}return d;
}
async function service(c,create=false){
 let s;try{s=await ci(c,'Services/'+SERVICE);}catch(e){if(e.status!==404)throw e;if(!create)return null;
  try{s=await ci(c,'Services',{UniqueName:SERVICE,FriendlyName:'LLD agent transcripts and summaries',LanguageCode:'en-US',AutoTranscribe:'false',DataLogging:'false',AutoRedaction:'true'});}catch(error){s=await ci(c,'Services/'+SERVICE);}
 }
 if(!sid('GA',s.sid)||s.account_sid!==c.TWILIO_ACCOUNT_SID||s.unique_name!==SERVICE||s.auto_transcribe!==false||s.data_logging!==false)throw failure(503,'Conversation service settings need administrator review.');
 const list=await ci(c,'Operators/PreBuilt?LanguageCode=en-US&PageSize=1000');
 const operators=list.prebuilt_operators||list.operators||[];
 const candidates=operators.filter(o=>/^(?:(?:call|conversation)[ -])?summar(?:y|i[sz]ation)$/i.test(o.friendly_name||'')&&!['retired','internal'].includes(o.availability)&&sid('LY',o.sid));
 if(candidates.length!==1){console.warn('dialer_summary_operator_unavailable',JSON.stringify({responseKeys:Object.keys(list),operators:operators.map(o=>({name:o.friendly_name,type:o.operator_type,availability:o.availability}))}));throw failure(503,'Twilio summary operator is not available for this account.');}
 const op=candidates[0];
 if(!(s.read_only_attached_operator_sids||[]).includes(op.sid)){
  if(!create)return null;await ci(c,'Services/'+s.sid+'/Operators/'+op.sid,{});
 }
 return {service_sid:s.sid,operator_sid:op.sid};
}
async function resolve(u,b){
 let result,c;
 if(b.kind==='power'){
  const parallel=require('./dialer-parallel'),s=await parallel.get(b.id,u.id),l=s.legs.find(x=>x.id===s.winner_id);
  if(s.session_id!==u.sessionId||s.state!=='connected'||!parallel.alive(s)||!l?.provider_sid||l.terminal)throw failure(409,'Connect to a client before starting the transcript.');
  c=await parallel.storedContext(s);result={lead_id:l.lead_id,phone:l.phone,call_sid:l.provider_sid,inbound_speaker:'client'};
 }else if(b.kind==='call'){
  const rows=await database('dialer_calls?'+new URLSearchParams({id:'eq.'+b.id,user_id:'eq.'+u.id,livemode:'eq.'+u.live,call_kind:'neq.power',finished:'eq.false',select:'*',limit:'1'}));const call=rows[0];
  if(!call?.parent_sid||call.session_id!==u.sessionId)throw failure(409,'Connect to a client before starting the transcript.');
  c=await provider.context(u);
  const list=await provider.scoped(u,'Calls.json?'+new URLSearchParams({ParentCallSid:call.parent_sid,PageSize:'100'}));
  const children=(list.calls||[]).filter(x=>x.parent_call_sid===call.parent_sid&&x.account_sid===c.TWILIO_ACCOUNT_SID&&x.to===call.phone&&x.status==='in-progress');
  if(children.length!==1||list.next_page_uri)throw failure(409,'Wait until the client answers, then start the transcript.');
  result={lead_id:call.lead_id,phone:call.phone,call_sid:children[0].sid,inbound_speaker:'client'};
 }else{
  const rows=await database('dialer_callbacks?'+new URLSearchParams({id:'eq.'+b.id,user_id:'eq.'+u.id,livemode:'eq.'+u.live,status:'eq.answered',completed_at:'is.null',select:'*',limit:'1'}));const call=rows[0];
  if(!call)throw failure(409,'Answer the callback before starting the transcript.');
  c=await provider.callbackContext(call.provider_sid);result={lead_id:null,phone:call.caller_phone,call_sid:call.parent_sid,inbound_speaker:'client'};
 }
 if(!sid('CA',result.call_sid))throw failure(409,'Call is not ready.');
 const actual=await provider.scoped(u,'Calls/'+result.call_sid+'.json');
 if(actual.account_sid!==c.TWILIO_ACCOUNT_SID||actual.status!=='in-progress'||(b.kind==='incoming'?actual.from:actual.to)!==result.phone)throw failure(409,'This call is no longer connected.');
 if(result.lead_id){const assigned=await database('leads?'+new URLSearchParams({id:'eq.'+result.lead_id,assigned_to:'eq.'+u.id,status:'eq.assigned',select:'id'}));if(assigned.length!==1)throw failure(403,'This lead is no longer assigned to you.');}
 return {c,...result,provider_sid:c.TWILIO_ACCOUNT_SID};
}
async function owned(u,b){const rows=await database('dialer_conversations?'+sourceQuery(u,b));return rows[0]||null;}
async function refreshSummary(row){
 if(row.summary||!row.transcription_sid||!['stopped','error'].includes(row.state)||Date.parse(row.summary_checked_at)>Date.now()-15000)return row;
 await database('dialer_conversations?id=eq.'+row.id,{summary_checked_at:new Date().toISOString()},'PATCH');
 try{
  const c=await provider.callbackContext(row.provider_sid),d=await ci(c,'Transcripts/'+row.transcription_sid+'/OperatorResults?Redacted=false&PageSize=100');
  const result=(d.operator_results||[]).find(r=>r.operator_sid===row.operator_sid&&r.transcript_sid===row.transcription_sid);
  const summary=result?.text_generation_results?.result;
  if(typeof summary==='string'&&summary.trim()&&summary.length<=16000){await database('dialer_conversations?id=eq.'+row.id,{summary},'PATCH');return {...row,summary};}
 }catch(e){if(e.status!==404&&e.status!==503)throw e;}return row;
}
async function reconcile(row,u){
 if(!['starting','live'].includes(row.state))return row;
 if(Date.parse(row.created_at)>Date.now()-15000||Date.parse(row.provider_checked_at)>Date.now()-15000)return row;
 await database('dialer_conversations?id=eq.'+row.id,{provider_checked_at:new Date().toISOString()},'PATCH');
 const name=row.transcription_sid||'lld_'+row.id.replace(/-/g,'');
 try{const t=await provider.scoped(u,'Calls/'+row.call_sid+'/Transcriptions/'+name+'.json');
  if(t.account_sid!==row.provider_sid||t.call_sid!==row.call_sid||!sid('GT',t.sid)||(row.transcription_sid&&row.transcription_sid!==t.sid))throw failure(403,'Transcript ownership mismatch.');
  const patch={transcription_sid:t.sid,...(t.status==='stopped'?{state:'stopped',stopped_at:row.stopped_at||new Date().toISOString()}:{} )};
  const saved=await database('dialer_conversations?id=eq.'+row.id,patch,'PATCH');return saved[0]||row;
 }catch(e){if(e.status===404&&Date.parse(row.created_at)<Date.now()-60000){const saved=await database('dialer_conversations?id=eq.'+row.id,{state:'error',error_code:'start_unconfirmed',stopped_at:new Date().toISOString()},'PATCH');return saved[0]||row;}throw e;}
}
async function view(row){
 if(!row)return {conversation:null,lines:[]};
 const lines=await database('dialer_conversation_lines?'+new URLSearchParams({conversation_id:'eq.'+row.id,select:'sequence,speaker,spoken_at,content',order:'spoken_at.desc,sequence.desc',limit:'250'}));
 return {conversation:{id:row.id,kind:row.kind,sourceId:row.source_id,leadId:row.lead_id,phone:row.phone,state:row.state,createdAt:row.created_at,stoppedAt:row.stopped_at,summary:row.summary,errorCode:row.error_code,expiresAt:row.expires_at},lines:lines.reverse()};
}
async function action(req,u){
 const b=req.body;if(!u.live)throw failure(403,'Conversation tools require live calling access.');
 if(b.action==='setup'){if(u.id!==MASTER)throw failure(403,'Master access required.');return {ready:!!await service(await provider.context(u),true)};}
 if(b.action==='list'){
  const rows=await database('dialer_conversations?'+new URLSearchParams({user_id:'eq.'+u.id,livemode:'eq.'+u.live,expires_at:'gt.'+new Date().toISOString(),select:'kind,source_id,phone,created_at,state',order:'created_at.desc',limit:'30'}));return {conversations:rows};
 }
 if(!['power','call','incoming'].includes(b.kind)||!UUID.test(b.id||''))throw failure(400,'Choose a conversation.');
 let row=await owned(u,b);
 if(b.action==='start'){
  if(b.consent!==true||b.acceptCharges!==true)throw failure(400,'Confirm the client agreed to transcription and the usage charges.');
  if(row)return view(row);
  const resolved=await resolve(u,b),configured=await service(resolved.c,true);
  const claim=await rpc('dialer_conversation_claim',{p_data:{user_id:u.id,livemode:u.live,kind:b.kind,source_id:b.id,lead_id:resolved.lead_id,phone:resolved.phone,provider_sid:resolved.provider_sid,call_sid:resolved.call_sid,inbound_speaker:resolved.inbound_speaker,...configured}});row=claim.conversation;
  if(claim.created){
   try{
    const t=await provider.scoped(u,'Calls/'+row.call_sid+'/Transcriptions.json',{Name:'lld_'+row.id.replace(/-/g,''),Track:'both_tracks',InboundTrackLabel:'Client',OutboundTrackLabel:'Agent',PartialResults:'false',LanguageCode:'en-US',TranscriptionEngine:'google',SpeechModel:'telephony',EnableAutomaticPunctuation:'true',IntelligenceService:row.service_sid,StatusCallbackUrl:ORIGIN+ROUTE+'?id='+row.id,StatusCallbackMethod:'POST'});
    if(!sid('GT',t.sid)||t.account_sid!==row.provider_sid||t.call_sid!==row.call_sid)throw Error('Invalid transcription');
    await rpc('dialer_conversation_event',{p_id:row.id,p_account:row.provider_sid,p_call:row.call_sid,p_transcription:t.sid,p_event:'transcription-started',p_sequence:0,p_track:null,p_content:null,p_time:null,p_error:null});
   }catch(e){
    // Never retry a creation with an uncertain response: the provider may already be billing it.
    await database('dialer_conversations?id=eq.'+row.id,{error_code:String(e.providerCode||'start_unconfirmed')},'PATCH');
   }
  }
  return view(await owned(u,b));
 }
 if(b.action==='stop'){
  if(!row)throw failure(404,'No transcript was started for this call.');
  if(['starting','live'].includes(row.state)){
   const name=row.transcription_sid||'lld_'+row.id.replace(/-/g,'');const t=await provider.scoped(u,'Calls/'+row.call_sid+'/Transcriptions/'+name+'.json',{Status:'stopped'});
   if(t.account_sid!==row.provider_sid||t.call_sid!==row.call_sid||t.status!=='stopped')throw failure(503,'Transcript stop is not yet confirmed. Retry Stop.');
   await database('dialer_conversations?id=eq.'+row.id,{state:'stopped',stopped_at:new Date().toISOString(),transcription_sid:t.sid},'PATCH');row=await owned(u,b);
  }
 }else if(b.action!=='state')throw failure(400,'Unknown conversation action.');
 if(row){row=await reconcile(row,u);row=await refreshSummary(row);}return view(row);
}
async function events(req,res){res.setHeader('Cache-Control','no-store');try{
 const b=req.body,url=new URL(req.url,ORIGIN),id=url.searchParams.get('id');
 if(req.method!=='POST'||url.pathname!==ROUTE||!UUID.test(id||'')||!sid('AC',b?.AccountSid)||!sid('CA',b?.CallSid)||!sid('GT',b?.TranscriptionSid))throw failure(403,'Invalid event.');
 const c=await provider.callbackContext(b.AccountSid);if(!validSignature(req,b,c,[ROUTE]))throw failure(403,'Invalid signature.');
 const rows=await database('dialer_conversations?'+new URLSearchParams({id:'eq.'+id,provider_sid:'eq.'+b.AccountSid,call_sid:'eq.'+b.CallSid,select:'id,transcription_sid'}));
 if(rows.length!==1||(rows[0].transcription_sid&&rows[0].transcription_sid!==b.TranscriptionSid))throw failure(403,'Transcript ownership mismatch.');
 const content=b.TranscriptionEvent==='transcription-content';let line=null,time=null;
 if(content){if(b.Final!=='true')return res.status(204).end();let d;try{d=JSON.parse(b.TranscriptionData);}catch{throw failure(400,'Invalid transcript.');}line=d.transcript;time=b.Timestamp;if(typeof line!=='string'||!line.trim()||line.length>8000||!Number.isFinite(Date.parse(time))||!['inbound_track','outbound_track'].includes(b.Track))throw failure(400,'Invalid transcript.');}
 if(!/^\d{1,6}$/.test(b.SequenceId||'')||Number(b.SequenceId)>100000)throw failure(400,'Invalid sequence.');
 await rpc('dialer_conversation_event',{p_id:id,p_account:b.AccountSid,p_call:b.CallSid,p_transcription:b.TranscriptionSid,p_event:b.TranscriptionEvent,p_sequence:Number(b.SequenceId),p_track:content?b.Track:null,p_content:line,p_time:time,p_error:/^[0-9]{1,10}$/.test(b.ErrorCode||'')?b.ErrorCode:null});
 return res.status(204).end();
 }catch(e){return res.status(e.status||503).end();}}
async function maintenance(){
 let errors=0,removed=0;
 const expired=await database('dialer_conversations?'+new URLSearchParams({expires_at:'lte.'+new Date().toISOString(),select:'id,provider_sid,transcription_sid',limit:'25',order:'expires_at.asc'}));
 for(const row of expired)try{
  if(row.transcription_sid){const c=await provider.callbackContext(row.provider_sid);try{await ci(c,'Transcripts/'+row.transcription_sid,undefined,'DELETE');}catch(e){if(e.status!==404)throw e;}}
  await database('dialer_conversations?id=eq.'+row.id,undefined,'DELETE');removed++;
 }catch{errors++;}
 const pending=await database('dialer_conversations?'+new URLSearchParams({state:'in.(starting,live,stopped)',summary:'is.null',created_at:'gt.'+new Date(Date.now()-7200000).toISOString(),select:'*',order:'created_at.asc',limit:'20'}));
 for(const row of pending)try{const fresh=await reconcile(row,{id:row.user_id,live:row.livemode});await refreshSummary(fresh);}catch{errors++;}
 return {checked:pending.length,removed,errors};
}
module.exports={action,events,service,ci,resolve,refreshSummary,reconcile,maintenance};
