'use strict';
const {master,MASTER,failure}=require('../../lib/dialer');
const {rpc,UUID}=require('../../lib/lead-calling');
const {verifySubscription}=require('./phone-setup');
async function twilio(path,body){
 const sid=process.env.TWILIO_ACCOUNT_SID,key=process.env.TWILIO_AUTH_TOKEN;
 if(!/^AC[a-f0-9]{32}$/i.test(sid||'')||!key)throw failure(503,'Twilio number setup is unavailable.');
 const r=await fetch('https://api.twilio.com/2010-04-01/Accounts/'+sid+'/'+path,{method:body?'POST':'GET',headers:{Authorization:'Basic '+Buffer.from(sid+':'+key).toString('base64'),...(body?{'Content-Type':'application/x-www-form-urlencoded'}:{})},...(body?{body:body.toString()}:{}),signal:AbortSignal.timeout(20000)});
 let d;try{d=await r.json()}catch{throw failure(502,'Twilio response unavailable. Check activation status before retrying.');}
 if(!r.ok)throw failure(502,'Twilio number activation failed. Check status before retrying.');return d;
}
module.exports=async function(req,res){
 res.setHeader('Cache-Control','no-store');
 if(req.method!=='POST'){res.setHeader('Allow','POST');return res.status(405).json({error:'Use POST.'});}
 if(req.headers.origin!=='https://www.lldportal.com')return res.status(403).json({error:'Open the dialer at www.lldportal.com.'});
 try{
 await master(req);const b=req.body;
 if(!b||typeof b!=='object'||Array.isArray(b))throw failure(400,'Invalid request.');
 const slot=b.slot===undefined?1:b.slot;if(!Number.isInteger(slot)||slot<1||slot>3)throw failure(400,'Choose one of three included number slots.');
 if(b.action==='status')return res.status(200).json(await rpc('master_number_activation_status',{p_slot:slot}));
 if(b.action!=='activate'||b.acceptTwilioCharges!==true)throw failure(400,'Confirm the real Twilio number charge before activation.');
 if(!/^\+1[2-9]\d{2}[2-9]\d{6}$/.test(b.phoneNumber||''))throw failure(400,'Load your saved preferred number first.');
 await verifySubscription(b.sessionId);
 const claims=JSON.parse(Buffer.from(req.headers.authorization.slice(7).split('.')[1],'base64url'));if(!UUID.test(claims.session_id||''))throw failure(403,'Sign in again before activating.');
 const n=await rpc('begin_master_number_activation',{p_session_id:claims.session_id,p_expected_phone:b.phoneNumber,p_slot:slot});
 if(n.state==='active')return res.status(200).json(await rpc('master_number_activation_status',{p_slot:slot}));
 const tag='Vivid Master '+n.purchaseKey;
 const list=await twilio('IncomingPhoneNumbers.json?'+new URLSearchParams({PhoneNumber:n.phoneNumber,PageSize:'10'}));
 let owned=(list.incoming_phone_numbers||[]).find(x=>x.phone_number===n.phoneNumber&&x.friendly_name===tag);
 if(!owned){
  if((list.incoming_phone_numbers||[]).some(x=>x.phone_number===n.phoneNumber))throw failure(409,'This number already exists under another setup. Contact the Master administrator.');
  if(!await rpc('claim_master_number_purchase',{p_key:n.purchaseKey}))throw failure(409,'Activation is pending. Click Activate again to check recovery. No second purchase will be attempted.');
  owned=await twilio('IncomingPhoneNumbers.json',new URLSearchParams({PhoneNumber:n.phoneNumber,FriendlyName:tag,VoiceUrl:'https://www.lldportal.com/dialer-inbound.xml',VoiceMethod:'GET'}));
 }
 if(owned.account_sid!==process.env.TWILIO_ACCOUNT_SID||owned.phone_number!==n.phoneNumber||owned.friendly_name!==tag||!/^PN[a-f0-9]{32}$/i.test(owned.sid||'')||owned.capabilities?.voice!==true)throw failure(502,'Purchased number needs verification. Check activation status; do not buy another number.');
 await rpc('finish_master_number_activation',{p_key:n.purchaseKey,p_phone:n.phoneNumber,p_sid:owned.sid});
 return res.status(200).json(await rpc('master_number_activation_status',{p_slot:slot}));
 }catch(e){return res.status(e.status||503).json({error:e.status?e.message:'Activation could not be confirmed. Check status before retrying; no additional purchase will be attempted.'});}
};
