'use strict';
const {rpc,ORIGIN}=require('../../lib/dialer-full');
const {signedRequest}=require('../../lib/dialer-incoming');
const PHONE=/^\+1[2-9]\d{2}[2-9]\d{6}$/;
module.exports=async(req,res)=>{
 res.setHeader('Content-Type','text/xml; charset=utf-8');res.setHeader('Cache-Control','no-store');
 try{
  const {b}=await signedRequest(req,['/api/dialer/pool-incoming']);
  if(!PHONE.test(b.To||''))throw Error('Invalid shared number');
  const route=await rpc('dialer_pool_callback_route',{p_account:b.AccountSid,p_to:b.To,p_from:b.From||'Unknown caller'});
  if(!PHONE.test(route.phone||'')||route.phone===b.To)throw Error('Invalid callback route');
  // Twilio preserves the original inbound caller ID during Dial forwarding.
  // Anonymous callers use the owned shared number so forwarding can proceed.
  const caller=PHONE.test(b.From||'')?'':' callerId="'+b.To+'"';
  return res.status(200).send('<Response><Dial'+caller+' timeout="30" timeLimit="1800" answerOnBridge="true" record="do-not-record"><Number>'+route.phone+'</Number></Dial><Hangup/></Response>');
 }catch(e){console.error('dialer_pool_callback_failed',JSON.stringify({status:e.status||503}));return res.status(e.status||503).send('<Response><Hangup/></Response>');}
};
