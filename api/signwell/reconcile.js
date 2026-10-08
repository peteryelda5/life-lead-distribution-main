'use strict';
const {timingSafeEqual}=require('node:crypto');
module.exports=async(req,res)=>{res.setHeader('Cache-Control','no-store');const expected=process.env.CRON_SECRET?'Bearer '+process.env.CRON_SECRET:'',actual=req.headers.authorization||'';if(!expected||actual.length!==expected.length||!timingSafeEqual(Buffer.from(actual),Buffer.from(expected)))return res.status(401).json({error:'Unauthorized'});try{return res.status(200).json(await require('../../lib/signwell').reconcile());}catch{return res.status(503).json({error:'Reconciliation unavailable'});}};
