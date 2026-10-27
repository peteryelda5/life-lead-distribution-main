'use strict';
const {database,mode,identity}=require('./dialer-full');
const provider=require('./dialer-at-cost-provider');
const SID=/^CA[0-9a-f]{32}$/i,ACCOUNT=/^AC[0-9a-f]{32}$/i;
const numeric=value=>value!==null&&value!==''&&value!==undefined&&Number.isFinite(Number(value))?Number(value):null;
const label=value=>typeof value==='string'&&/^[a-zA-Z0-9_. :/-]{1,100}$/.test(value)?value:null;
const date=value=>typeof value==='string'&&Number.isFinite(Date.parse(value))?new Date(value).toISOString():null;
const errorInfo=e=>({httpStatus:Number(e.httpStatus)||null,code:Number(e.providerCode)||null,reason:e.ownership?'ownership_mismatch':'provider_unavailable'});
function mismatch(){return Object.assign(Error('Provider ownership mismatch'),{ownership:true});}
async function get(c,url){
 const u=new URL(url);
 if(!ACCOUNT.test(c.TWILIO_ACCOUNT_SID)||!['api.twilio.com','monitor.twilio.com','insights.twilio.com'].includes(u.hostname)||u.protocol!=='https:')throw mismatch();
 const r=await fetch(url,{method:'GET',redirect:'error',headers:{Authorization:'Basic '+Buffer.from(c.TWILIO_ACCOUNT_SID+':'+c.TWILIO_AUTH_TOKEN).toString('base64')},signal:AbortSignal.timeout(10000)});
 const d=await r.json();if(!r.ok)throw Object.assign(Error('Provider diagnostics unavailable'),{httpStatus:r.status,providerCode:numeric(d.code)});return d;
}
function callFields(d){return {status:label(d.status),durationSeconds:numeric(d.duration),answeredBy:label(d.answered_by),queueMs:numeric(d.queue_time),startAt:date(d.start_time),endAt:date(d.end_time)};}
function insightFields(d){
 const p=d.properties||{},edges={};
 for(const key of ['sdk_edge','client_edge','carrier_edge','sip_edge'])if(d[key]){
  const edge=d[key],metrics={};
  for(const direction of ['inbound','outbound'])if(edge.metrics?.[direction]){
   const stream=edge.metrics[direction],safe={};
   for(const metric of ['jitter','rtt','latency','mos','packets','packet_loss']){
    const value=stream[metric];
    if(value&&typeof value==='object')safe[metric]=Object.fromEntries(Object.entries(value).filter(([k,v])=>['min','max','avg','total','lost','loss_percentage'].includes(k)&&numeric(v)!==null).map(([k,v])=>[k,numeric(v)]));
    else if(numeric(value)!==null)safe[metric]=numeric(value);
   }metrics[direction]=safe;
  }
  edges[key]={disconnectedBy:label(edge.properties?.disconnected_by),metrics};
 }
 return {state:label(d.processing_state),callState:label(d.call_state),answeredBy:label(d.answered_by),disconnectedBy:label(p.disconnected_by),sipResponse:numeric(p.last_sip_response_num),postDialDelayMs:numeric(p.pdd_ms),queueMs:numeric(p.queue_time),tags:Array.isArray(d.tags)?d.tags.map(label).filter(Boolean).slice(0,25):[],edges};
}
async function accountDiagnostics(c,since){
 const result={alerts:[],alertsComplete:false,insightsEnabled:false,errors:{}};
 const values=await Promise.allSettled([
  get(c,'https://monitor.twilio.com/v1/Alerts?'+new URLSearchParams({StartDate:since,PageSize:'1000'})),
  get(c,'https://insights.twilio.com/v1/Voice/Settings')
 ]);
 if(values[0].status==='fulfilled'){
  const d=values[0].value;if(!Array.isArray(d.alerts)||d.alerts.some(a=>a.account_sid!==c.TWILIO_ACCOUNT_SID))throw mismatch();
  result.alerts=d.alerts;result.alertsComplete=!d.meta?.next_page_url;
 }else result.errors.alerts=errorInfo(values[0].reason);
 if(values[1].status==='fulfilled'){
  const d=values[1].value;if(d.account_sid!==c.TWILIO_ACCOUNT_SID)throw mismatch();result.insightsEnabled=d.advanced_features===true;
 }else result.errors.settings=errorInfo(values[1].reason);
 return result;
}
async function collect(row,c,account){
 const base='https://api.twilio.com/2010-04-01/Accounts/'+c.TWILIO_ACCOUNT_SID;
 const details={version:1,insightsEnabled:account.insightsEnabled,alertsComplete:account.alertsComplete,accountErrors:account.errors,legs:{}};
 const specs=row.call_kind==='power'?[['recipient',row.parent_sid]]:[['agent',row.parent_sid],['recipient',row.child_sid]];
 let complete=true;
 for(const [role,sid] of specs){
  if(!sid)continue;if(!SID.test(sid))throw mismatch();
  const leg={};details.legs[role]=leg;
  try{
   const call=await get(c,base+'/Calls/'+sid+'.json');
   if(call.sid!==sid||call.account_sid!==c.TWILIO_ACCOUNT_SID)throw mismatch();
   if(role==='recipient'&&(call.to!==row.phone||call.from!==row.caller_id||row.call_kind!=='power'&&call.parent_call_sid!==row.parent_sid))throw mismatch();
   if(role==='agent'&&call.from!=='client:'+identity(row.user_id))throw mismatch();
   Object.assign(leg,callFields(call));
   leg.alerts=account.alerts.filter(a=>a.resource_sid===sid).slice(0,20).map(a=>({code:numeric(a.error_code),level:label(a.log_level),at:date(a.date_generated||a.date_created)}));
   if(account.insightsEnabled){
    try{
     const summary=await get(c,'https://insights.twilio.com/v1/Voice/'+sid+'/Summary');
     if(summary.call_sid!==sid||summary.account_sid!==c.TWILIO_ACCOUNT_SID)throw mismatch();
     leg.insights=insightFields(summary);
    }catch(e){if(e.ownership)throw e;leg.insightsError=errorInfo(e);complete=false;}
   }
  }catch(e){if(e.ownership)throw e;leg.error=errorInfo(e);complete=false;}
 }
 return {call_id:row.id,checked_at:new Date().toISOString(),state:complete?'complete':'partial',details};
}
function selectPending(rows,checked,now=Date.now()){
 const known=new Map(checked.map(r=>[r.call_id,r]));
 const pending=rows.filter(r=>{
  if(!r.finished||!SID.test(r.parent_sid||'')||Date.parse(r.finished_at||r.created_at)>now-120000)return false;
  const previous=known.get(r.id);return !previous||(previous.state!=='complete'&&Date.parse(previous.checked_at)<now-3600000);
 });
 const priority=r=>r.call_status==='failed'?0:r.call_status==='completed'&&r.duration_seconds<=5?1:r.call_kind==='power'?2:3;
 pending.sort((a,b)=>priority(a)-priority(b)||Date.parse(b.created_at)-Date.parse(a.created_at));
 // Keep one high-priority sample per agent before filling the remaining batch.
 const chosen=[],users=new Set();for(const r of pending)if(!users.has(r.user_id)){chosen.push(r);users.add(r.user_id);if(chosen.length===12)break;}
 const ids=new Set(chosen.map(r=>r.id));for(const r of pending)if(chosen.length<12&&!ids.has(r.id)){chosen.push(r);ids.add(r.id);}
 return chosen;
}
async function maintenance(){
 if(!mode())return {checked:0,errors:0};
 const since=new Date(Date.now()-7*86400000).toISOString(),rows=await database('dialer_calls?'+new URLSearchParams({livemode:'eq.true',finished:'eq.true',parent_sid:'not.is.null',created_at:'gt.'+since,select:'id,user_id,phone,caller_id,parent_sid,child_sid,call_kind,call_status,created_at,finished_at,duration_seconds,finished',order:'created_at.desc',limit:'1000'}));
 const known=await database('dialer_call_diagnostics?'+new URLSearchParams({select:'call_id,state,checked_at',checked_at:'gt.'+since,limit:'10000'}));
 const queue=selectPending(rows,known),contexts=new Map(),accounts=new Map();let checked=0,errors=0;
 const context=async user=>{if(!contexts.has(user))contexts.set(user,provider.context({id:user,live:true}));return contexts.get(user);};
 const worker=async()=>{while(queue.length){const row=queue.shift();try{
  let c;if(row.call_kind==='power'){const legs=await database('dialer_parallel_legs?'+new URLSearchParams({id:'eq.'+row.id,select:'session_id'}));if(legs.length!==1)throw mismatch();const parallel=require('./dialer-parallel'),session=await parallel.get(legs[0].session_id,row.user_id);c=await parallel.storedContext(session);}else c=await context(row.user_id);if(!accounts.has(c.TWILIO_ACCOUNT_SID))accounts.set(c.TWILIO_ACCOUNT_SID,accountDiagnostics(c,since));
  const result=await collect(row,c,await accounts.get(c.TWILIO_ACCOUNT_SID));
  // Idempotent replacement; only this service-only diagnostics table is writable here.
  const old=known.some(r=>r.call_id===row.id);await database('dialer_call_diagnostics'+(old?'?call_id=eq.'+row.id:''),result,old?'PATCH':'POST');checked++;
 }catch(e){errors++;console.error('dialer_health_call_unavailable',JSON.stringify({callId:row.id,...errorInfo(e)}));}}};
 await Promise.all([worker(),worker(),worker()]);
 return {checked,errors};
}
module.exports={maintenance,collect,accountDiagnostics,selectPending,insightFields};
