'use strict';

const {createHash}=require('node:crypto');
const DATABASE_URL='https://yfuuigykpihoetgaefmu.supabase.co/rest/v1/rpc/submitted_deals_api_read';
const PERIODS=new Set(['today','week','month','previous']);
const DATE=/^\d{4}-\d{2}-01$/;

const UUID=/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
// Explicit allowlist at both database and HTTP boundaries.
function publicResult(data){
 if(!data||!Array.isArray(data.deals)||!PERIODS.has(data.period?.key))throw Error('Invalid result');
 const string=value=>{if(typeof value!=='string')throw Error('Invalid text');return value;};
 const id=value=>{if(!UUID.test(string(value)))throw Error('Invalid ID');return value;};
 const amount=value=>{if(value===null)return null;if(typeof value!=='number'||!Number.isFinite(value))throw Error('Invalid amount');return value;};
 return {version:1,timezone:'America/Detroit',currency:'USD',as_of:string(data.as_of),
  period:{key:data.period.key,start:string(data.period.start),end_exclusive:string(data.period.end_exclusive)},
  deals:data.deals.map(row=>({deal_id:id(row.deal_id),agent_id:id(row.agent_id),agent_name:string(row.agent_name),
   agency:'Vivid Life Advisors',monthly_premium:amount(row.monthly_premium),annual_premium:amount(row.annual_premium),submitted_at:string(row.submitted_at)})),
  next_after:data.next_after===null?null:id(data.next_after)};
}

module.exports=async(req,res)=>{
 res.setHeader('Cache-Control','private, no-store, max-age=0');
 res.setHeader('CDN-Cache-Control','no-store');
 res.setHeader('Vercel-CDN-Cache-Control','no-store');
 res.setHeader('Vary','Authorization');
 res.setHeader('X-Content-Type-Options','nosniff');
 if(req.method!=='GET'){res.setHeader('Allow','GET');return res.status(405).json({error:'This API is read-only. Use GET.'});}
 const auth=req.headers.authorization;
 if(typeof auth!=='string'||!/^Bearer vllb_[A-Za-z0-9_-]{43}$/.test(auth))return res.status(401).json({error:'A valid leaderboard API key is required.'});
 let params;
 try{params=new URL(req.url,'https://www.lldportal.com').searchParams;}catch{return res.status(400).json({error:'Invalid request.'});}
 if([...params.keys()].some(name=>!['period','month','after','limit'].includes(name)||params.getAll(name).length!==1))return res.status(400).json({error:'Only period, month, after and limit parameters are allowed.'});
 const period=params.get('period')??'month',month=params.get('month');
 if(!PERIODS.has(period)||(period==='previous'?(!month||!DATE.test(month)||Number(month.slice(5,7))<1||Number(month.slice(5,7))>12):month!==null))return res.status(400).json({error:'Use today, week, month, or previous with month=YYYY-MM-01.'});
 const after=params.get('after'),limit=params.get('limit')??'200';
 if((after!==null&&!UUID.test(after))||! /^[1-9][0-9]{0,2}$/.test(limit)||Number(limit)>500)return res.status(400).json({error:'Use a UUID after cursor and limit between 1 and 500.'});
 const secret=process.env.SUPABASE_SECRET_KEY;
 if(!/^sb_secret_[A-Za-z0-9_-]+$/.test(secret||''))return res.status(503).json({error:'Submitted deals temporarily unavailable.'});
 try{
  const response=await fetch(DATABASE_URL,{
   method:'POST',headers:{apikey:secret,'Content-Type':'application/json'},
   body:JSON.stringify({p_key_hash:createHash('sha256').update(auth.slice(7)).digest('hex'),p_period:period,p_month:month,p_after:after,p_limit:Number(limit)}),
   signal:AbortSignal.timeout(10000)
  });
  if(!response.ok)throw Error('Database unavailable');
  const data=await response.json();
  if(data?.status===401)return res.status(401).json({error:'Invalid, expired, or revoked leaderboard API key.'});
  if(data?.status===400)return res.status(400).json({error:'Choose a valid period; previous months must be before the current month.'});
  if(data?.status===429){res.setHeader('Retry-After','60');return res.status(429).json({error:'Rate limit reached. Try again in 60 seconds.'});}
  if(data?.status!==200)throw Error('Invalid database result');
  return res.status(200).json(publicResult(data.data));
 }catch{
  // Do not log tokens, upstream response bodies, request headers, or credentials.
  return res.status(503).json({error:'Submitted deals temporarily unavailable.'});
 }
};
