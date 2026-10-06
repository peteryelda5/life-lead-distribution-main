'use strict';
const {master,MASTER,failure}=require('../../lib/dialer');
const {stripe}=require('../../lib/dialer-billing');
const {PLAN,PURPOSE}=require('../../lib/dialer-plan');
const BASE='https://yfuuigykpihoetgaefmu.supabase.co';
async function subscription(id){
 if(typeof id!=='string'||!/^cs_test_[A-Za-z0-9]{10,240}$/.test(id))throw failure(400,'Complete and check your monthly test subscription first.');
 const s=await stripe('checkout/sessions/'+encodeURIComponent(id));
 if(s.livemode!==false||s.client_reference_id!==MASTER||s.metadata?.purpose!==PURPOSE||s.metadata?.portal_user_id!==MASTER||s.metadata?.plan_id!==PLAN.id||s.mode!=='subscription'||s.currency!==PLAN.currency||s.amount_total!==PLAN.monthlyPriceCents||s.status!=='complete'||s.payment_status!=='paid'||!/^sub_[A-Za-z0-9]{10,240}$/.test(s.subscription||''))throw failure(403,'A completed monthly test subscription is required.');
 const sub=await stripe('subscriptions/'+encodeURIComponent(s.subscription)),items=sub.items?.data||[],price=items[0]?.price;
 if(sub.livemode!==false||sub.status!=='active'||sub.metadata?.portal_user_id!==MASTER||sub.metadata?.purpose!==PURPOSE||sub.metadata?.plan_id!==PLAN.id||items.length!==1||items[0].quantity!==1||price?.currency!==PLAN.currency||price?.unit_amount!==PLAN.monthlyPriceCents||price?.recurring?.interval!=='month'||price?.recurring?.interval_count!==1)throw failure(403,'Your monthly test subscription is not active.');
}
async function available(area,phone){
 const sid=process.env.TWILIO_ACCOUNT_SID,key=process.env.TWILIO_AUTH_TOKEN;
 if(!/^AC[a-f0-9]{32}$/i.test(sid||'')||!key)throw failure(503,'Phone number search is not configured.');
 const q=new URLSearchParams({AreaCode:area,VoiceEnabled:'true',ExcludeAllAddressRequired:'true',PageSize:'10'});
 if(phone)q.set('Contains',phone);
 const r=await fetch('https://api.twilio.com/2010-04-01/Accounts/'+sid+'/AvailablePhoneNumbers/US/Local.json?'+q,{headers:{Authorization:'Basic '+Buffer.from(sid+':'+key).toString('base64')},signal:AbortSignal.timeout(15000)});
 let d;try{d=await r.json()}catch{throw failure(502,'Phone number search returned an invalid response.');}
 if(!r.ok)throw failure(502,'Phone number search unavailable. Try again.');
 return (d.available_phone_numbers||[]).filter(n=>/^\+1[2-9]\d{2}[2-9]\d{6}$/.test(n.phone_number||'')&&n.phone_number.slice(2,5)===area&&n.capabilities?.voice===true&&n.address_requirements==='none').slice(0,10).map(n=>({phoneNumber:n.phone_number,friendlyName:n.friendly_name||n.phone_number,city:n.locality||'',state:n.region||''}));
}
async function preference(body){
 const key=process.env.SUPABASE_SECRET_KEY;if(!/^sb_secret_[A-Za-z0-9_-]+$/.test(key||''))throw failure(503,'Phone preference storage is not configured.');
 const r=await fetch(BASE+'/rest/v1/dialer_number_preferences'+(body?'?on_conflict=user_id':'?user_id=eq.'+MASTER+'&select=phone_number,area_code,updated_at'),{method:body?'POST':'GET',headers:{apikey:key,...(body?{'Content-Type':'application/json',Prefer:'resolution=merge-duplicates,return=representation'}:{})},...(body?{body:JSON.stringify(body)}:{}),signal:AbortSignal.timeout(10000)});
 let d;try{d=await r.json()}catch{throw failure(502,'Phone preference storage returned an invalid response.');}
 if(!r.ok)throw failure(503,'Could not save or load your phone preference. Try again.');
 return d[0]?{phoneNumber:d[0].phone_number,areaCode:d[0].area_code,updatedAt:d[0].updated_at,activated:false,reserved:false}:null;
}
module.exports=async function(req,res){
 res.setHeader('Cache-Control','no-store');
 if(req.method!=='POST'){res.setHeader('Allow','POST');return res.status(405).json({error:'Use POST.'});}
 if(req.headers.origin!=='https://www.lldportal.com')return res.status(403).json({error:'Open the dialer at www.lldportal.com.'});
 try{
  await master(req);
  const b=req.body;if(!b||typeof b!=='object'||Array.isArray(b))throw failure(400,'Invalid request.');
  if(b.action==='current')return res.status(200).json({preference:await preference(),purchaseEnabled:false});
  if(!['search','select'].includes(b.action))throw failure(400,'Unknown phone action.');
  if(typeof b.areaCode!=='string'||! /^[2-9]\d{2}$/.test(b.areaCode))throw failure(400,'Enter a three-digit US area code.');
  await subscription(b.sessionId);
  if(b.action==='search')return res.status(200).json({numbers:await available(b.areaCode),purchaseEnabled:false});
  if(typeof b.phoneNumber!=='string'||!/^\+1[2-9]\d{2}[2-9]\d{6}$/.test(b.phoneNumber)||b.phoneNumber.slice(2,5)!==b.areaCode)throw failure(400,'Choose a number from your area-code search.');
  const numbers=await available(b.areaCode,b.phoneNumber);if(!numbers.some(n=>n.phoneNumber===b.phoneNumber))throw failure(409,'That number is no longer available. Search again.');
  const saved=await preference({user_id:MASTER,phone_number:b.phoneNumber,area_code:b.areaCode,stripe_test_session_id:b.sessionId,updated_at:new Date().toISOString()});
  return res.status(200).json({preference:saved,purchaseEnabled:false});
 }catch(e){return res.status(e.status||503).json({error:e.status?e.message:'Phone number setup unavailable. Please retry.'});}
};

module.exports.verifySubscription=subscription;
