'use strict';
const {endpoint,rpc,UUID,failure}=require('../../lib/dialer-full');
const {displayLead}=require('../../lib/lead-calling');
module.exports=endpoint(async(req,u)=>{
 const b=req.body,args={p_user:u.id,p_live:u.live};
 if(b.action==='presence'){
  if(!UUID.test(b.browserId||'')||!['idle','dialing','on_call','wrap'].includes(b.activity)||b.mode!==undefined&&!['ready','break','offline'].includes(b.mode))throw failure(400,'Invalid agent status.');
  return rpc('dialer_workspace_presence',{...args,p_session:u.sessionId,p_browser:b.browserId,p_activity:b.activity,p_visible:b.visible===true,p_mode:b.mode??null});
 }
 if(b.action==='priority'){
  const d=await rpc('dialer_priority_list',args);
  return {...d,tasks:(d.tasks||[]).map(t=>({...t,matches:(t.matches||[]).map(l=>({...displayLead(l),csv_headers:l.csv_headers,csv_values:l.csv_values}))}))};
 }
 if(b.action==='schedule'){
  if(!UUID.test(b.id||'')||!UUID.test(b.leadId||'')||typeof b.dueAt!=='string'||!Number.isFinite(Date.parse(b.dueAt))||typeof b.note!=='string'||b.note.length>1000)throw failure(400,'Choose a lead, callback time, and a note under 1,000 characters.');
  return rpc('dialer_priority_schedule',{...args,p_id:b.id,p_lead:b.leadId,p_due:new Date(b.dueAt).toISOString(),p_note:b.note});
 }
 if(b.action==='resolve'){
  if(!UUID.test(b.id||''))throw failure(400,'Choose a callback.');
  return rpc('dialer_priority_resolve',{...args,p_id:b.id});
 }
 if(b.action==='supervisor')return rpc('dialer_supervisor_workspace',args);
 throw failure(400,'Unknown workspace action.');
});
