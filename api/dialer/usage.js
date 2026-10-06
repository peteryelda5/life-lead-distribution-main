'use strict';
const {master}=require('../../lib/dialer');
const {rpc}=require('../../lib/lead-calling');
module.exports=async function(req,res){
 res.setHeader('Cache-Control','no-store');
 if(req.method!=='POST'){res.setHeader('Allow','POST');return res.status(405).json({error:'Use POST.'});}
 if(req.headers.origin!=='https://www.lldportal.com')return res.status(403).json({error:'Open the dialer at www.lldportal.com.'});
 try{await master(req);return res.status(200).json(await rpc('master_dialer_month_usage',{}));}catch(e){return res.status(e.status||503).json({error:e.status?e.message:'Usage tracking unavailable. Try again.'});}
};
