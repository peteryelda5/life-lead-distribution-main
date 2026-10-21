'use strict';
const {timingSafeEqual}=require('node:crypto');
module.exports=async(req,res)=>{
 res.setHeader('Cache-Control','no-store');
 if(req.method!=='GET')return res.status(405).end();
 const secret=process.env.CRON_SECRET,a=Buffer.from(req.headers.authorization||''),b=Buffer.from('Bearer '+secret);
 if(!secret||a.length!==b.length||!timingSafeEqual(a,b))return res.status(401).end();
 try{const result=await require('../../lib/dialer-call-diagnostics').maintenance();return res.status(result.errors?503:200).json(result);}
 catch{console.error('dialer_health_collection_failed');return res.status(503).json({error:'Call diagnostics unavailable.'});}
};
module.exports.config={maxDuration:300};
