'use strict';
const {timingSafeEqual}=require('node:crypto');
const {database}=require('../../lib/dialer-full');
const provider=require('../../lib/dialer-at-cost-provider');
const {archiveRecording}=require('../../lib/dialer-incoming');
module.exports=async(req,res)=>{res.setHeader('Cache-Control','no-store');const secret=process.env.CRON_SECRET,a=Buffer.from(req.headers.authorization||''),b=Buffer.from('Bearer '+secret);
 if(req.method!=='GET'||!secret||a.length!==b.length||!timingSafeEqual(a,b))return res.status(401).end();
 try{
  const rows=await database('dialer_callbacks?'+new URLSearchParams({select:'*',livemode:'eq.true',created_at:'lt.'+new Date(Date.now()-180000).toISOString(),or:'(recording_pending.eq.true,status.eq.ringing,and(recording_path.not.is.null,provider_copy_removed.eq.false))',order:'created_at.asc',limit:'20'}));let errors=0;
  for(const call of rows)try{
   const u={id:call.user_id,live:call.livemode},c=await provider.callbackContext(call.provider_sid);
   if(call.recording_path){await archiveRecording(call,c,call.recording_sid,call.recording_seconds);continue;}
   const recordings=await provider.scoped(u,'Calls/'+call.parent_sid+'/Recordings.json?PageSize=20');
   const recording=(recordings.recordings||[]).find(r=>r.call_sid===call.parent_sid&&r.source==='RecordVerb'&&r.status==='completed');
   if(recording){await archiveRecording(call,c,recording.sid,Number(recording.duration));continue;}
   const state=await provider.scoped(u,'Calls/'+call.parent_sid+'.json');
   if(['completed','busy','failed','no-answer','canceled'].includes(state.status))await database('dialer_callbacks?id=eq.'+call.id,{recording_pending:false,...(call.status==='ringing'?{status:'missed'}:{}),completed_at:call.completed_at||new Date().toISOString()},'PATCH');
  }catch{errors++;}
  return res.status(errors?503:200).json({checked:rows.length,errors});
 }catch{return res.status(503).json({error:'Callback recovery could not finish.'});}
};
module.exports.config={maxDuration:300};
