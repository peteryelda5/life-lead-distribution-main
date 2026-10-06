'use strict';
const {timingSafeEqual}=require('node:crypto');
const {database,mode,stripe,MASTER}=require('../../lib/dialer-full');
const {sync,reconcile,overage,settleFinal,webhookSetup}=require('../../lib/dialer-full-billing');
const {release}=require('../../lib/dialer-full-numbers');
function authorized(req){const secret=process.env.CRON_SECRET;if(!secret)return false;const a=Buffer.from(req.headers.authorization||''),b=Buffer.from('Bearer '+secret);return a.length===b.length&&timingSafeEqual(a,b);}
module.exports=async(req,res)=>{res.setHeader('Cache-Control','no-store');if(req.method!=='GET')return res.status(405).end();if(!authorized(req))return res.status(401).end();try{await webhookSetup();const rows=await database('dialer_accounts?livemode=eq.'+mode()+'&select=user_id,livemode&limit=100');let completed=0,errors=0;for(const a of rows){try{const u={id:a.user_id,live:a.livemode},current=await sync(u);if(u.live||u.id===MASTER)await reconcile(u);const invoices=await stripe('invoices?customer='+current.customer_id+'&status=draft&limit=100');for(const invoice of invoices.data||[])await overage(u,invoice);if(current.subscription_status==='canceled'&&new Date(current.period_end).getTime()<=Date.now()){await settleFinal(u,current);await release(u);}completed++;}catch{errors++;}}return res.status(errors?503:200).json({completed,errors});}catch{return res.status(503).json({error:'Maintenance unavailable.'});}};
module.exports.config={maxDuration:300};
