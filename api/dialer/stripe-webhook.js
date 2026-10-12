'use strict';
module.exports=async(req,res)=>{res.setHeader('Cache-Control','no-store');return res.status(403).json({error:'Recovery test: provider calls, billing, webhooks, and scheduled jobs are disabled.'});};
