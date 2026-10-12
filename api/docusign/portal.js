'use strict';
const recovery=require('../../lib/recovery-onboarding');
const {ORIGIN}=require('../../lib/docusign');
module.exports=async(req,res)=>{
 res.setHeader('Cache-Control','no-store');
 if(req.method!=='POST')return res.status(405).json({error:'Use POST.'});
 if(req.headers.origin!==ORIGIN)return res.status(403).json({error:'Open onboarding from the recovery portal.'});
 try{if(!req.body||typeof req.body!=='object'||Array.isArray(req.body))return res.status(400).json({error:'Invalid request.'});return res.status(200).json(await recovery.action(req));}
 catch(e){console.error('recovery_onboarding_request_failed',{action:req.body?.action,status:e.status||503});return res.status(e.status||503).json({error:e.status?e.message:'Recovered onboarding is temporarily unavailable. Please retry.'});}
};
