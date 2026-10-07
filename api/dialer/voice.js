'use strict';
const {verify:verifyLead,rpc}=require('../../lib/lead-calling');
const {config,verifyGrant,validWebhook,IDENTITY} = require('../../lib/dialer');
module.exports=async function(req,res){
  res.setHeader('Cache-Control','no-store');
  res.setHeader('Content-Type','text/xml; charset=utf-8');
  if(req.method!=='POST'){res.setHeader('Allow','POST');return res.status(405).send('<Response><Hangup/></Response>');}
  try{
    const c=config(),b=req.body;
    let audience;try{audience=JSON.parse(Buffer.from(String(b?.CallGrant).split(".")[1],"base64url")).aud}catch{}
    if(audience==="vivid_dialer_full_v1")return require("../../lib/dialer-full-voice")(req,res,await require("../../lib/dialer-at-cost-provider").callbackContext(b?.AccountSid));
    if(!/^application\/x-www-form-urlencoded(?:;|$)/i.test(req.headers['content-type']||'')||!b||typeof b!=='object'||Array.isArray(b)||!validWebhook(req,b,c)||b.AccountSid!==c.TWILIO_ACCOUNT_SID||b.From!=='client:'+IDENTITY) return res.status(403).send('<Response><Hangup/></Response>');
    let grant,limit=120,track=false;
    try{grant=verifyGrant(b.CallGrant,c);}catch{grant=verifyLead(b.CallGrant,c);const phone=await rpc('consume_master_dialer_grant',{p_call_id:grant.callId,p_twilio_sid:b.CallSid});if(phone!==grant.to)throw Error('Phone changed');let activeNumber=grant.callerId;if(activeNumber&&activeNumber!==c.TWILIO_PHONE_NUMBER&&!await rpc('master_dialer_number_active',{p_phone:activeNumber}))throw Error('Caller ID is not active');if(!activeNumber)activeNumber=await rpc('active_master_dialer_number',{});if(activeNumber){if(!/^\+1[2-9]\d{2}[2-9]\d{6}$/.test(activeNumber)||activeNumber===grant.to)throw Error('Invalid caller ID');c.TWILIO_PHONE_NUMBER=activeNumber;}limit=1800;track=true;}
    return res.status(200).send( '<Response><Dial callerId="'+c.TWILIO_PHONE_NUMBER+'" timeout="25" timeLimit="'+limit+'" answerOnBridge="true" record="do-not-record"><Number'+(track?' statusCallback="https://www.lldportal.com/api/dialer/call-status" statusCallbackEvent="completed" statusCallbackMethod="POST"':'')+'>'+grant.to+'</Number></Dial></Response>');
  }catch{return res.status(403).send('<Response><Hangup/></Response>');}
};

