'use strict';
const {displayLead}=require('../../lib/lead-calling');
const {authenticate,failure,database}=require('../../lib/dialer-full');
const BASE='https://yfuuigykpihoetgaefmu.supabase.co';
const KEY='sb_publishable_6O3XhhYJrjhN_5U1cFxz2g_fYI-3uE6';
const UUID=/^[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}$/i;
const SELECT='id,first_name,last_name,phone,email,state,lead_type,agent_status,call_notes,assigned_to,status,updated_at,csv_headers,csv_values';
async function data(req,path,body){
 const r=await fetch(BASE+'/rest/v1/'+path,{method:body===undefined?'GET':'POST',headers:{apikey:KEY,Authorization:req.headers.authorization,'Content-Type':'application/json'},...(body===undefined?{}:{body:JSON.stringify(body)}),signal:AbortSignal.timeout(10000)});
 const text=await r.text();let result;try{result=text?JSON.parse(text):null}catch{throw failure(502,'Lead service returned an invalid response.')}
 if(!r.ok)throw failure(r.status===401?401:400,result?.message||'Could not load or save leads.');
 return result;
}
function clientLead(l){return {...displayLead(l),csv_headers:l.csv_headers,csv_values:l.csv_values};}
function params(userId){return new URLSearchParams({select:SELECT,assigned_to:'eq.'+userId,status:'eq.assigned',order:'assigned_at.desc,id.desc'});}
module.exports=async function(req,res){
 res.setHeader('Cache-Control','no-store');
 if(req.method!=='POST'){res.setHeader('Allow','POST');return res.status(405).json({error:'Use POST.'});}
 if(req.headers.origin!=='https://www.lldportal.com')return res.status(403).json({error:'Open the workspace at www.lldportal.com.'});
 try{
  const u=await authenticate(req);const b=req.body;
  if(!b||typeof b!=='object'||Array.isArray(b))throw failure(400,'Invalid request.');
  if(b.action==='profile'){const profiles=await data(req,'profiles?id=eq.'+u.id+'&select=full_name,division');const profile=profiles[0]||{},division=profile.division==='owner'?'vivid_life':profile.division;const p=new URLSearchParams({select:'id,title,lead_type,body,division',division:'eq.'+division,order:'created_at.desc',limit:'100'});return res.status(200).json({profile,scripts:division?await data(req,'sales_scripts?'+p):[]});}
  if(b.action==='history'){if(!Number.isInteger(b.offset)||b.offset<0||b.offset>1000000)throw failure(400,'Invalid history page.');return res.status(200).json({calls:await database('dialer_calls?'+new URLSearchParams({select:'id,created_at,phone,duration_seconds,used_minutes,finished,call_status,lead_id',user_id:'eq.'+u.id,livemode:'eq.'+u.live,parent_sid:'not.is.null',order:'created_at.desc,id.desc',limit:'50',offset:String(b.offset)}))});}
  if(b.action==='folders')return res.status(200).json({folders:await data(req,'rpc/my_lead_folders',{})});
  if(b.action==='leads'){
   if(!Number.isInteger(b.offset)||b.offset<0||b.offset>1000000)throw failure(400,'Invalid lead page.');
   const p=params(u.id);p.set('limit','500');p.set('offset',String(b.offset));
   if(b.folder!==undefined){if(b.folder!==null&&(typeof b.folder!=='string'||b.folder.length>1000))throw failure(400,'Invalid folder.');p.set('lead_type',b.folder===null?'is.null':'eq.'+b.folder);}
   return res.status(200).json({leads:(await data(req,'leads?'+p)).map(clientLead)});
  }
  if(b.action==='save'){
   if(!UUID.test(b.leadId||'')||!['appointment_follow_up','call_back','not_interested','dead_number'].includes(b.status)||typeof b.notes!=='string'||b.notes.length>10000)throw failure(400,'Choose a valid lead outcome and notes under 10,000 characters.');
   const p=params(u.id);p.set('id','eq.'+b.leadId);p.set('limit','1');
   const rows=await data(req,'leads?'+p);if(rows.length!==1)throw failure(409,'This lead is no longer assigned to you. Reload your folder.');
   if(b.expectedNotes!==rows[0].call_notes||b.expectedStatus!==rows[0].agent_status)throw failure(409,'This lead changed in another window. Reload before saving.');
   await data(req,'rpc/save_dialer_lead_outcome',{p_lead_id:b.leadId,p_status:b.status,p_notes:b.notes,p_expected_status:b.expectedStatus,p_expected_notes:b.expectedNotes});
   const updated=await data(req,'leads?'+p);if(updated.length!==1)throw failure(409,'The lead assignment changed. Reload your folder.');
   return res.status(200).json({lead:clientLead(updated[0])});
  }
  throw failure(400,'Unknown workspace action.');
 }catch(e){return res.status(e.status||503).json({error:e.status?e.message:'Workspace unavailable. Please try again.'});}
};
