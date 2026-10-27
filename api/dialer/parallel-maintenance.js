'use strict';
const {timingSafeEqual}=require('node:crypto');
module.exports=async(req,res)=>{res.setHeader('Cache-Control','no-store');const secret=process.env.CRON_SECRET,a=Buffer.from(req.headers.authorization||''),b=Buffer.from('Bearer '+secret);if(req.method!=='GET'||!secret||a.length!==b.length||!timingSafeEqual(a,b))return res.status(401).end();try{const reservations=await require('../../lib/dialer-reservations').cleanup();const result=await require('../../lib/dialer-parallel').maintenance();const monitors=await require('../../lib/dialer-monitor').maintenance();return res.status(result.errors||monitors.errors?503:200).json({...result,monitors,...reservations});}catch{return res.status(503).json({error:'Pilot cleanup could not finish.'});}};
module.exports.config={maxDuration:300};
