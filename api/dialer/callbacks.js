'use strict';
const {createHmac,randomUUID}=require('node:crypto');
const {endpoint,rpc,database,UUID,failure}=require('../../lib/dialer-full');
const {sync,args}=require('../../lib/dialer-full-billing');
module.exports=endpoint(async(req,u)=>{
 const b=req.body;
 if(b.action==='list')return rpc('dialer_callback_list',{...args(u),p_offset:Number.isInteger(b.offset)?Math.max(0,b.offset):0,p_id:UUID.test(b.id||'')?b.id:null});
 if(b.action==='seen'){if(!UUID.test(b.id||''))throw failure(400,'Choose a callback.');await database('dialer_callbacks?'+new URLSearchParams({id:'eq.'+b.id,user_id:'eq.'+u.id,livemode:'eq.'+u.live}),{seen_at:new Date().toISOString()},'PATCH');return {saved:true};}
 if(!['token','presence'].includes(b.action)||!UUID.test(b.browserId||''))throw failure(400,'Unknown callback action.');
 if(b.action==='token'){
  if(!u.live)throw failure(403,'Incoming calls are available in the live portal.');
  await sync(u);if(!await rpc('dialer_entitled',args(u)))throw failure(403,'Your dialer account needs active calling access.');
  const c=await require('../../lib/dialer-at-cost-provider').context(u),identity='vivid_in_'+u.id.replace(/-/g,'')+'_'+b.browserId.replace(/-/g,'');
  const t=Math.floor(Date.now()/1000),parts=[{alg:'HS256',typ:'JWT',cty:'twilio-fpa;v=1'},{jti:c.TWILIO_API_KEY_SID+'-'+randomUUID(),iss:c.TWILIO_API_KEY_SID,sub:c.TWILIO_ACCOUNT_SID,iat:t,nbf:t-5,exp:t+3600,grants:{identity,voice:{incoming:{allow:true}}}}].map(v=>Buffer.from(JSON.stringify(v)).toString('base64url')).join('.');
  return {token:parts+'.'+createHmac('sha256',c.TWILIO_API_KEY_SECRET).update(parts).digest('base64url')};
 }
 return rpc('dialer_callback_presence',{...args(u),p_session:u.sessionId,p_browser:b.browserId,p_ready:b.ready===true,p_busy:b.busy!==false});
});
