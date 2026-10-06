'use strict';
const {master,MASTER,failure}=require('../../lib/dialer');
const {testKey,stripe}=require('../../lib/dialer-billing');
const {PLAN,PURPOSE}=require('../../lib/dialer-plan');
const RETURN='https://www.lldportal.com/dialer-workspace.html';
const UUID=/^[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}$/i;
function check(s){
 if(s.livemode!==false||s.client_reference_id!==MASTER||s.metadata?.purpose!==PURPOSE||s.metadata?.portal_user_id!==MASTER||s.metadata?.plan_id!==PLAN.id||s.mode!=='subscription'||s.currency!==PLAN.currency||s.amount_total!==PLAN.monthlyPriceCents)throw failure(403,'This subscription checkout does not belong to your test plan.');
}
module.exports=async function(req,res){
 res.setHeader('Cache-Control','no-store');
 if(req.method!=='POST'){res.setHeader('Allow','POST');return res.status(405).json({error:'Use POST.'});}
 if(req.headers.origin!=='https://www.lldportal.com')return res.status(403).json({error:'Open the dialer at www.lldportal.com.'});
 try{
  await master(req);testKey();
  const b=req.body;if(!b||typeof b!=='object'||Array.isArray(b))throw failure(400,'Invalid request.');
  if(b.action==='plan')return res.status(200).json({plan:PLAN,testMode:true,agentRolloutEnabled:false,usageTrackingEnabled:true});
  if(b.action==='create'){
   if(!UUID.test(b.requestId||''))throw failure(400,'Invalid checkout request.');
   const p=new URLSearchParams({mode:'subscription','payment_method_types[0]':'card',
    'line_items[0][price_data][currency]':PLAN.currency,'line_items[0][price_data][unit_amount]':String(PLAN.monthlyPriceCents),
    'line_items[0][price_data][recurring][interval]':PLAN.interval,
    'line_items[0][price_data][product_data][name]':PLAN.name+' — TEST subscription',
    'line_items[0][price_data][product_data][description]':'Monthly plan: three US local numbers, 5,000 minutes, then $0.03/min. Sandbox subscription only; number provisioning and usage billing are not enabled.',
    'line_items[0][quantity]':'1',client_reference_id:MASTER,
    'metadata[purpose]':PURPOSE,'metadata[portal_user_id]':MASTER,'metadata[plan_id]':PLAN.id,
    'subscription_data[metadata][purpose]':PURPOSE,'subscription_data[metadata][portal_user_id]':MASTER,'subscription_data[metadata][plan_id]':PLAN.id,
    success_url:RETURN+'?dialer_subscription_session={CHECKOUT_SESSION_ID}',cancel_url:RETURN+'?dialer_subscription_cancelled=1'});
   const s=await stripe('checkout/sessions',p,'dialer-subscription-test-'+MASTER+'-'+b.requestId);check(s);
   let u;try{u=new URL(s.url)}catch{throw failure(502,'Stripe did not provide a checkout link.');}
   if(u.protocol!=='https:'||u.hostname!=='checkout.stripe.com')throw failure(502,'Invalid Stripe checkout link.');
   return res.status(200).json({url:s.url,testMode:true});
  }
  if(b.action==='status'){
   if(typeof b.sessionId!=='string'||!/^cs_test_[A-Za-z0-9]{10,240}$/.test(b.sessionId))throw failure(400,'Invalid subscription test session.');
   const s=await stripe('checkout/sessions/'+encodeURIComponent(b.sessionId));check(s);
   if(s.status!=='complete'||s.payment_status!=='paid')return res.status(200).json({testMode:true,paid:false,status:s.status,plan:PLAN});
   if(typeof s.subscription!=='string'||!/^sub_[A-Za-z0-9]{10,240}$/.test(s.subscription))throw failure(502,'Subscription reference is missing.');
   const sub=await stripe('subscriptions/'+encodeURIComponent(s.subscription)),items=sub.items?.data||[],price=items[0]?.price;
   if(sub.livemode!==false||sub.metadata?.portal_user_id!==MASTER||sub.metadata?.purpose!==PURPOSE||sub.metadata?.plan_id!==PLAN.id||items.length!==1||items[0].quantity!==1||price?.currency!==PLAN.currency||price?.unit_amount!==PLAN.monthlyPriceCents||price?.recurring?.interval!==PLAN.interval||price?.recurring?.interval_count!==1)throw failure(403,'Subscription does not match your monthly test plan.');
   return res.status(200).json({testMode:true,paid:true,status:sub.status,plan:PLAN,agentRolloutEnabled:false,usageTrackingEnabled:true});
  }
  throw failure(400,'Unknown subscription action.');
 }catch(e){return res.status(e.status||503).json({error:e.status?e.message:'Subscription test unavailable. Please try again.'});}
};
