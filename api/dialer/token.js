'use strict';
const {config,master,tokens} = require('../../lib/dialer');
module.exports=async function(req,res){
  res.setHeader('Cache-Control','no-store');
  if(req.method!=='POST'){res.setHeader('Allow','POST');return res.status(405).json({error:'POST required.'});}
  if(req.headers.origin!=='https://www.lldportal.com')return res.status(403).json({error:'Open the test on www.lldportal.com.'});
  try{await master(req);return res.status(200).json(tokens(config()));}
  catch(e){return res.status(e.status||503).json({error:e.status?e.message:'Calling setup could not be checked. Please try again.'});}
};
