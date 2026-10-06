'use strict';
const {master,MASTER,failure}=require('../../lib/dialer');
const RETURN='https://www.lldportal.com/dialer-workspace.html';
const {testKey,stripe,checkSession,creditSession,wallet,PURPOSE}=require('../../lib/dialer-billing');
const UUID=/^[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}$/i;
module.exports=async function(req,res){
 res.setHeader('Cache-Control','no-store');
 if(req.method!=='POST'){res.setHeader('Allow','POST');return res.status(405).json({error:'Use POST.'});}
 if(req.headers.origin!=='https://www.lldportal.com')return res.status(403).json({error:'Open the dialer at www.lldportal.com.'});
 try{
  await master(req);
  testKey();
  const b=req.body;if(!b||typeof b!=='object'||Array.isArray(b))throw failure(400,'Invalid request.');
  if(b.action==='wallet')return res.status(200).json(await wallet(req));
  if(b.action==='create'){
   if(!UUID.test(b.requestId||''))throw failure(400,'Invalid checkout request.');
   const p=new URLSearchParams({mode:'payment','payment_method_types[0]':'card','line_items[0][price_data][currency]':'usd','line_items[0][price_data][unit_amount]':'2500','line_items[0][price_data][product_data][name]':'Vivid Life dialer — TEST payment','line_items[0][price_data][product_data][description]':'Adds $25 in test wallet credit. No real money or live calling.','line_items[0][quantity]':'1',client_reference_id:MASTER,'metadata[purpose]':PURPOSE,'metadata[portal_user_id]':MASTER,success_url:RETURN+'?stripe_test_session={CHECKOUT_SESSION_ID}',cancel_url:RETURN+'?stripe_test_cancelled=1'});
   const s=await stripe('checkout/sessions',p,'dialer-test-'+MASTER+'-'+b.requestId);
   checkSession(s);
   let url;try{url=new URL(s.url)}catch{throw failure(502,'Stripe did not provide a checkout link.');}
   if(url.protocol!=='https:'||url.hostname!=='checkout.stripe.com')throw failure(502,'Invalid Stripe checkout link.');
   return res.status(200).json({url:s.url,testMode:true});
  }
  if(b.action==='status'){
   if(typeof b.sessionId!=='string'||!/^cs_test_[A-Za-z0-9]{10,240}$/.test(b.sessionId))throw failure(400,'Invalid test checkout session.');
   const s=await stripe('checkout/sessions/'+encodeURIComponent(b.sessionId));checkSession(s);
   const credit=await creditSession(s);
   return res.status(200).json({testMode:true,paid:s.status==='complete'&&s.payment_status==='paid',status:s.status,amountCents:s.amount_total,walletCredited:!!credit,balanceCents:credit?.balanceCents});
  }
  throw failure(400,'Unknown billing action.');
 }catch(e){return res.status(e.status||503).json({error:e.status?e.message:'Test billing unavailable. Please try again.'});}
};
