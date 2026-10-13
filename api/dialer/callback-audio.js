'use strict';
const {authenticate,database,UUID,ORIGIN}=require('../../lib/dialer-full');
const {storage,boundedAudio}=require('../../lib/dialer-incoming');
module.exports=async(req,res)=>{res.setHeader('Cache-Control','no-store');try{
 if(req.method!=='POST'||req.headers.origin!==ORIGIN)return res.status(403).end();
 const u=await authenticate(req),id=req.body?.id;if(!UUID.test(id||''))return res.status(400).end();
 const rows=await database('dialer_callbacks?'+new URLSearchParams({id:'eq.'+id,user_id:'eq.'+u.id,livemode:'eq.'+u.live,select:'recording_sid,recording_path'}));
 const c=rows[0],path=c?.recording_sid?u.id+'/'+id+'/'+c.recording_sid+'.mp3':null;
 if(!path||c.recording_path!==path)return res.status(404).end();
 const audio=await boundedAudio(await storage(path));res.setHeader('Content-Type','audio/mpeg');res.setHeader('Content-Length',audio.length);return res.status(200).send(audio);
 }catch(e){return res.status(e.status||503).json({error:'Voicemail could not load. Please retry.'});}};
