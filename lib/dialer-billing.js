'use strict';
const {MASTER,failure}=require('./dialer');
const BASE='https://yfuuigykpihoetgaefmu.supabase.co';
const PUBLIC_KEY='sb_publishable_6O3XhhYJrjhN_5U1cFxz2g_fYI-3uE6';
const PURPOSE='dialer_checkout_connection_test';
function testKey(){const k=process.env.STRIPE_SECRET_KEY;if(typeof k!=='string'||!/^sk_test_[A-Za-z0-9]+$/.test(k))throw failure(503,'Add a Stripe test secret key in Vercel. Live payments are disabled.');return k;}
async function stripe(path,body,idempotency){
 const response=await fetch('https://api.stripe.com/v1/'+path,{method:body?'POST':'GET',headers:{Authorization:'Bearer '+testKey(),...(body?{'Content-Type':'application/x-www-form-urlencoded'}:{}),...(idempotency?{'Idempotency-Key':idempotency}:{})},...(body?{body:body.toString()}:{}),signal:AbortSignal.timeout(15000)});
 let result;try{result=await response.json()}catch{throw failure(502,'Stripe returned an invalid response.');}
 if(!response.ok)throw failure(502,'Stripe test connection failed. Check the test key in Vercel.');return result;
}
function checkSession(s){if(s.livemode!==false||s.client_reference_id!==MASTER||s.metadata?.purpose!==PURPOSE||s.metadata?.portal_user_id!==MASTER||s.currency!=='usd'||s.amount_total!==2500||s.mode!=='payment')throw failure(403,'This checkout does not belong to your dialer test.');}
async function rpc(name,body,headers){
 const r=await fetch(BASE+'/rest/v1/rpc/'+name,{method:'POST',headers:{...headers,'Content-Type':'application/json'},body:JSON.stringify(body),signal:AbortSignal.timeout(10000)});
 let d;try{d=await r.json()}catch{throw failure(502,'Wallet service returned an invalid response.');}
 if(!r.ok)throw failure(503,'Wallet service unavailable. Your payment will not be credited twice; try again.');return d;
}
async function wallet(req){return rpc('my_dialer_test_wallet',{},{apikey:PUBLIC_KEY,Authorization:req.headers.authorization});}
async function creditSession(s){
 checkSession(s);if(s.status!=='complete'||s.payment_status!=='paid')return null;
 if(typeof s.payment_intent!=='string'||!/^pi_[A-Za-z0-9]{10,240}$/.test(s.payment_intent))throw failure(502,'Stripe payment reference is missing.');
 const k=process.env.SUPABASE_SECRET_KEY;
 if(typeof k!=='string'||!/^sb_secret_[A-Za-z0-9_-]+$/.test(k))throw failure(503,'Payment confirmed, but wallet setup needs SUPABASE_SECRET_KEY in Vercel.');
 return rpc('credit_dialer_test_wallet',{p_session_id:s.id,p_payment_intent_id:s.payment_intent},{apikey:k});
}
module.exports={testKey,stripe,checkSession,creditSession,wallet,PURPOSE};
