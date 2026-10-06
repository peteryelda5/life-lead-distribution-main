'use strict';
const {randomUUID}=require('node:crypto');
const {endpoint,rpc,UUID,failure,config,callTokens}=require('../../lib/dialer-full');
const {sync,reconcile,args}=require('../../lib/dialer-full-billing');
module.exports=endpoint(async(req,u)=>{const b=req.body;if(!UUID.test(b.leadId||'')||!Number.isInteger(b.callerSlot)||b.callerSlot<1||b.callerSlot>3)throw failure(400,'Choose a lead and an activated caller ID.');await sync(u);await reconcile(u);const id=randomUUID(),c=config(),call=await rpc('dialer_create_call',{...args(u),p_session:u.sessionId,p_lead:b.leadId,p_call:id,p_slot:b.callerSlot});return {...callTokens(u,id,c),callerId:call.callerId,destination:call.to,maxSeconds:call.maxSeconds};});
