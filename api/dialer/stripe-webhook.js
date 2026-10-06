'use strict';
const {createHmac,timingSafeEqual}=require('node:crypto');
const {stripe,creditSession,PURPOSE,testKey}=require('../../lib/dialer-billing');
const {MASTER,failure}=require('../../lib/dialer');
async function raw(req){let size=0,chunks=[];for await(const chunk of req){const b=Buffer.isBuffer(chunk)?chunk:Buffer.from(chunk);size+=b.length;if(size>262144)throw failure(413,'Event too large.');chunks.push(b)}return Buffer.concat(chunks);}
function verify(body,header,secret){
 if(typeof header!=='string'||header.length>2000)return false;
 const parts=header.split(','),times=parts.filter(p=>p.startsWith('t=')).map(p=>p.slice(2));
 if(times.length!==1||!/^\d+$/.test(times[0])||Math.abs(Date.now()/1000-Number(times[0]))>300)return false;
 const expected=createHmac('sha256',secret).update(times[0]+'.').update(body).digest();
 return parts.filter(p=>p.startsWith('v1=')).some(p=>{const h=p.slice(3);return /^[a-f0-9]{64}$/i.test(h)&&timingSafeEqual(expected,Buffer.from(h,'hex'))});
}
module.exports=async function(req,res){
 res.setHeader('Cache-Control','no-store');
 if(req.method!=='POST'){res.setHeader('Allow','POST');return res.status(405).json({error:'Use POST.'});}
 try{
  const secret=process.env.STRIPE_WEBHOOK_SECRET;if(typeof secret!=='string'||!/^whsec_[A-Za-z0-9]+$/.test(secret))throw failure(503,'Webhook signing secret is not configured.');
  const body=await raw(req);if(!verify(body,req.headers['stripe-signature'],secret))throw failure(400,'Invalid Stripe signature.');
  let event;try{event=JSON.parse(body.toString('utf8'))}catch{throw failure(400,'Invalid event.');}
  if(event.livemode!==false)throw failure(400,'Live events are disabled.');testKey();
  if(!['checkout.session.completed','checkout.session.async_payment_succeeded'].includes(event.type))return res.status(200).json({received:true,ignored:true});
  const s=event.data?.object;if(s?.metadata?.purpose!==PURPOSE||s?.metadata?.portal_user_id!==MASTER)return res.status(200).json({received:true,ignored:true});
  if(typeof s.id!=='string'||!/^cs_test_[A-Za-z0-9]{10,240}$/.test(s.id))throw failure(400,'Invalid test session.');
  const confirmed=await stripe('checkout/sessions/'+encodeURIComponent(s.id));
  const result=await creditSession(confirmed);return res.status(200).json({received:true,credited:result?.credited||false});
 }catch(e){return res.status(e.status||503).json({error:e.status?e.message:'Webhook processing unavailable. Please retry.'});}
};
module.exports.config={api:{bodyParser:false}};
