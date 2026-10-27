'use strict';
const BASE='https://yfuuigykpihoetgaefmu.supabase.co',KEY='sb_publishable_6O3XhhYJrjhN_5U1cFxz2g_fYI-3uE6';
const fail=(status,message)=>Object.assign(new Error(message),{status});
async function request(path,key,authorization,method='GET',body){
 const r=await fetch(BASE+path,{method,headers:{apikey:key,Authorization:authorization,'Content-Type':'application/json',Prefer:'return=minimal'},...(body===undefined?{}:{body:JSON.stringify(body)}),signal:AbortSignal.timeout(12000)});
 const text=await r.text();let data;try{data=text?JSON.parse(text):null;}catch{throw fail(502,'Account service returned an invalid response.');}
 return {ok:r.ok,status:r.status,data};
}
module.exports=async(req,res)=>{
 res.setHeader('Cache-Control','no-store');
 try{
  if(req.method!=='POST')throw fail(405,'Use POST.');
  if(!['https://www.lldportal.com','https://lldportal.com'].includes(req.headers.origin))throw fail(403,'Open this action from the portal.');
  if(process.env.VERCEL_ENV&&process.env.VERCEL_ENV!=='production')throw fail(503,'Password changes are available on the live portal.');
  const auth=req.headers.authorization||'';if(!/^Bearer [A-Za-z0-9_.-]+$/.test(auth))throw fail(401,'Sign in again.');
  const u=await request('/auth/v1/user',KEY,auth);if(!u.ok||!u.data?.id)throw fail(401,'Sign in again.');
  const m=await request('/rest/v1/rpc/require_portal_mfa',KEY,auth,'POST',{});if(!m.ok||m.data!==true)throw fail(403,'Complete two-step verification first.');
  const p=await request('/rest/v1/profiles?select=role,active,archived,is_super_admin&id=eq.'+encodeURIComponent(u.data.id),KEY,auth);
  const owner=p.data?.[0];if(!p.ok||owner?.role!=='admin'||!owner.active||owner.archived||!owner.is_super_admin)throw fail(403,'Only the portal owner can change agent passwords.');
  const {agent_id,password}=req.body||{};
  if(typeof agent_id!=='string'||!/^[a-f0-9-]{36}$/i.test(agent_id)||typeof password!=='string'||password.length<12||password.length>128)throw fail(400,'Choose an agent and use a password between 12 and 128 characters.');
  const key=process.env.SUPABASE_SECRET_KEY;if(!/^sb_secret_[\w-]+$/.test(key||''))throw fail(503,'Password management is temporarily unavailable.');
  const service='Bearer '+key;
  const t=await request('/rest/v1/profiles?select=id,role,active,archived,is_super_admin&id=eq.'+agent_id,key,service);
  if(!t.ok||t.data?.[0]?.role!=='agent'||t.data[0].archived||!t.data[0].active||t.data[0].is_super_admin)throw fail(404,'Active agent not found.');
  const recent=await request('/rest/v1/audit_logs?select=id&actor_id=eq.'+u.data.id+'&action=eq.agent_password_reset_requested&created_at=gte.'+encodeURIComponent(new Date(Date.now()-60000).toISOString())+'&limit=5',key,service);
  if(!recent.ok)throw fail(503,'Could not verify reset availability.');if(recent.data.length>=5)throw fail(429,'Wait a minute before changing another password.');
  const audit={actor_id:u.data.id,action:'agent_password_reset_requested',entity_type:'profile',entity_id:agent_id,details:{method:'owner_set_password'}};
  const logged=await request('/rest/v1/audit_logs',key,service,'POST',audit);if(!logged.ok)throw fail(503,'Could not record the password change request.');
  const result=await request('/auth/v1/admin/users/'+agent_id,key,service,'PUT',{password});
  if(!result.ok)throw fail(result.status===422||result.status===400?400:503,'Password could not be changed. Use a different strong password or try again.');
  const done=await request('/rest/v1/audit_logs',key,service,'POST',{...audit,action:'agent_password_reset'}).catch(()=>({ok:false}));
  return res.status(200).json({ok:true,audit_recorded:done.ok});
 }catch(e){return res.status(e.status||503).json({error:e.status?e.message:'Password service is temporarily unavailable. Try again.'});}
};
