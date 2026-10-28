'use strict';
const {endpoint,database}=require('../../lib/dialer-full');
module.exports=endpoint(async(req,u)=>{
 const since=new Date(Date.now()-86400000).toISOString();
 const [calls,health,sessions]=await Promise.all([
  database('dialer_calls?'+new URLSearchParams({user_id:'eq.'+u.id,livemode:'eq.true',created_at:'gt.'+since,parent_sid:'not.is.null',select:'call_status,duration_seconds',order:'created_at.desc',limit:'500'})),
  database('dialer_client_health?'+new URLSearchParams({user_id:'eq.'+u.id,updated_at:'gt.'+since,select:'events',order:'updated_at.desc',limit:'500'})),
  database('dialer_parallel_sessions?'+new URLSearchParams({user_id:'eq.'+u.id,created_at:'gt.'+since,select:'id',order:'created_at.desc',limit:'200'}))
 ]);
 const legs=sessions.length?await database('dialer_parallel_legs?'+new URLSearchParams({session_id:'in.('+sessions.map(s=>s.id).join(',')+')',select:'outcome,detection_ms,answer'})):[];
 const detections=legs.map(l=>l.detection_ms).filter(n=>typeof n==='number'&&n>0).sort((a,b)=>a-b);
 const events=health.flatMap(h=>h.events||[]),setup=health.flatMap(h=>(h.events||[]).filter(e=>e.type==='prepared'&&Number.isFinite(e.metrics?.setupMs)).map(e=>e.metrics.setupMs)).sort((a,b)=>a-b),declines=health.filter(h=>(h.events||[]).some(e=>e.code===31603)).length;
 const slow=detections.filter(n=>n>=3000).length,median=detections.length?detections[Math.floor(detections.length/2)]:null;
 const failed=calls.filter(c=>c.call_status==='failed').length,busy=calls.filter(c=>c.call_status==='busy').length,overflow=legs.filter(l=>['second_answer','answer_unconfirmed','answered_not_connected'].includes(l.outcome)).length;
 return {windowHours:24,sampled:calls.length===500||health.length===500||sessions.length===200,calls:calls.length,failed,busy,declines,overflow,detectionSamples:detections.length,medianDetectionMs:median,slowDetections:slow,reconnects:events.filter(e=>e.type==='reconnecting').length,summary:'Last 24 hours (up to 500 calls / 200 batches): '+calls.length+' attempts · '+failed+' failed · '+busy+' busy · '+declines+' calls with decline error · '+overflow+' pickups needing follow-up. '+(median===null?'No detection timing samples.':'Median detection '+(median/1000).toFixed(2)+'s; '+slow+' of '+detections.length+' detections took at least 3s.')+' Detection timing is not a measurement of two-way audio.'+(setup.length?' Median batch preparation: '+(setup[Math.floor(setup.length/2)]/1000).toFixed(2)+'s.':'')};
});
