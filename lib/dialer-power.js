'use strict';
const {rpc,database,failure,UUID}=require('./dialer-full');
const provider=require('./dialer-at-cost-provider');
const {displayLead}=require('./lead-calling');
const SELECT='id,first_name,last_name,phone,email,state,lead_type,agent_status,call_notes,assigned_to,status,csv_headers,csv_values';
async function leads(user,ids){
 const rows=await database('leads?'+new URLSearchParams({id:'in.('+ids.join(',')+')',assigned_to:'eq.'+user,status:'eq.assigned',select:SELECT}));
 return rows.map(l=>({...displayLead(l),csv_headers:l.csv_headers,csv_values:l.csv_values}));
}
async function prepare(u,b){
 const parallel=require('./dialer-parallel');
 if(!UUID.test(b.id||'')||!Array.isArray(b.leadIds)||b.leadIds.length<1||b.leadIds.length>3||b.leadIds.some(id=>!UUID.test(id))||new Set(b.leadIds).size!==b.leadIds.length||!['fast','human'].includes(b.connectMode))throw failure(400,'Choose one to three leads and a connection mode.');
 await require('./dialer-full-billing').ensureFresh(u);
 if(!await rpc('dialer_entitled',{p_user:u.id,p_live:true}))throw failure(403,'Complete your calling setup in Numbers & billing first.');
 const c=await provider.context(u);
 const numbers=await database('dialer_numbers?'+new URLSearchParams({user_id:'eq.'+u.id,livemode:'eq.true',state:'eq.active',phone:'eq.'+b.callerId,select:'phone'}));
 if(numbers.length!==1)throw failure(403,'Activate your caller ID in Numbers & billing first.');
 const checked=await Promise.all(b.leadIds.map(async id=>{try{const phone=await rpc('dialer_lead_phone',{p_user:u.id,p_lead:id});if(phone===b.callerId)throw failure(400,'This lead has the same number as your caller ID.');await require('./dialer-phone').validate(phone,c);return {id,phone,rate:await parallel.price(phone,b.callerId,c)};}catch(e){if(e.status===400||e.status===409)return {id,error:e.message};throw e;}}));
 const valid=[],seen=new Set(),skipped=[];
 for(const item of checked){if(item.error||seen.has(item.phone)){skipped.push({leadId:item.id,reason:item.error||'Duplicate phone number in this batch.'});continue;}seen.add(item.phone);valid.push(item);}
 if(!valid.length)throw failure(400,skipped[0]?.reason||'None of these leads can be called. Choose another lead.');
 const leadIds=valid.map(l=>l.id),phones=valid.map(l=>l.phone),rates=valid.map(l=>l.rate);
 await rpc('dialer_power_prepare',{p_user:u.id,p_session:u.sessionId,p_id:b.id,p_account:c.TWILIO_ACCOUNT_SID,p_caller:b.callerId,p_leads:leadIds,p_phones:phones,p_rates:rates,p_mode:b.connectMode});
 const s=await parallel.get(b.id,u.id);
 if(s.session_id!==u.sessionId||s.kind!=='leads'||s.state!=='prepared'||!parallel.alive(s))throw failure(409,'This batch has already started or expired.');
 return {...parallel.tokens(s,c),session:parallel.publicState(s),leads:await leads(u.id,leadIds),skipped};
}
module.exports={prepare,leads};
