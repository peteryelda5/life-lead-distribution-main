'use strict';
const {config,verifyGrant,validWebhook,IDENTITY} = require('../../lib/dialer');
module.exports=async function(req,res){
  res.setHeader('Cache-Control','no-store');
  res.setHeader('Content-Type','text/xml; charset=utf-8');
  if(req.method!=='POST'){res.setHeader('Allow','POST');return res.status(405).send('<Response><Hangup/></Response>');}
  try{
    const c=config(),b=req.body;
    if(!/^application\/x-www-form-urlencoded(?:;|$)/i.test(req.headers['content-type']||'')||!b||typeof b!=='object'||Array.isArray(b)||!validWebhook(req,b,c)||b.AccountSid!==c.TWILIO_ACCOUNT_SID||b.From!=='client:'+IDENTITY) return res.status(403).send('<Response><Hangup/></Response>');
    const grant=verifyGrant(b.CallGrant,c);
    return res.status(200).send('<Response><Dial callerId="'+c.TWILIO_PHONE_NUMBER+'" timeout="25" timeLimit="120" answerOnBridge="true" record="do-not-record"><Number>'+grant.to+'</Number></Dial></Response>');
  }catch{return res.status(403).send('<Response><Hangup/></Response>');}
};
