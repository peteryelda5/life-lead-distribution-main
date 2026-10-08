'use strict';
const {timingSafeEqual}=require('node:crypto');
const {reconcile}=require('../../lib/docusign');
module.exports=async(req,res)=>{res.setHeader('Cache-Control','no-store');if(req.method!=='GET')return res.status(405).json({error:'Use GET.'});const secret=process.env.CRON_SECRET,a=Buffer.from(req.headers.authorization||''),b=Buffer.from('Bearer '+(secret||''));if(!secret||a.length!==b.length||!timingSafeEqual(a,b))return res.status(401).json({error:'Unauthorized.'});try{return res.status(200).json(await reconcile());}catch(e){console.error('docusign_reconcile_error',{status:e.status||503});return res.status(503).json({error:'DocuSign reconciliation unavailable.'});}};
