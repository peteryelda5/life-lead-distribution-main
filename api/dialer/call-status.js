'use strict';
const {createHmac,timingSafeEqual}=require('node:crypto');
const {failure}=require('../../lib/dialer');
const {rpc}=require('../../lib/lead-calling');
const URL='https://www.lldportal.com/api/dialer/call-status';
function signed(req,b,key){
 if(req.url!=='/api/dialer/call-status'||typeof req.headers['x-twilio-signature']!=='string')return false;
 let data=URL;for(const k of Object.keys(b).sort()){if(typeof b[k]!=='string')return false;data+=k+b[k]}
 const expected=createHmac('sha1',key).update(data).digest(),given=Buffer.from(req.headers['x-twilio-signature'],'base64');return expected.length===given.length&&timingSafeEqual(expected,given);
}
module.exports=async function(req,res){
 res.setHeader('Cache-Control','no-store');
 if(req.method!=='POST'){res.setHeader('Allow','POST');return res.status(405).json({error:'Use POST.'});}
 try{
 const b=req.body,key=process.env.TWILIO_AUTH_TOKEN,sid=process.env.TWILIO_ACCOUNT_SID;
 if(!key||!/^AC[a-f0-9]{32}$/i.test(sid||''))throw failure(503,'Call tracking is not configured.');
 if(!/^application\/x-www-form-urlencoded(?:;|$)/i.test(req.headers['content-type']||'')||!b||typeof b!=='object'||Array.isArray(b)||!signed(req,b,key)||b.AccountSid!==sid)throw failure(403,'Invalid Twilio callback.');
 if(!/^CA[a-f0-9]{32}$/i.test(b.CallSid||'')||!/^CA[a-f0-9]{32}$/i.test(b.ParentCallSid||''))throw failure(400,'Invalid call reference.');
 if(!['completed','busy','failed','no-answer','canceled'].includes(b.CallStatus))throw failure(400,'Expected completed call event.');
 let seconds=0;if(b.CallStatus==='completed'){if(!/^\d{1,5}$/.test(b.CallDuration||''))throw failure(400,'Call duration is missing.');seconds=Number(b.CallDuration);if(seconds>7200)throw failure(400,'Invalid call duration.');}
 const result=await rpc('record_master_dialer_usage',{p_parent_sid:b.ParentCallSid,p_child_sid:b.CallSid,p_duration:seconds,p_status:b.CallStatus});
 return res.status(200).json({received:true,recorded:result.recorded});
 }catch(e){return res.status(e.status||503).json({error:e.status?e.message:'Call tracking unavailable. Retry callback.'});}
};
