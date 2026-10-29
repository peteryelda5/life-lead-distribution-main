'use strict';
const assert=require('node:assert/strict'),{createHash}=require('node:crypto');
const full=require('../lib/dialer-full');const id='11111111-1111-4111-8111-111111111111',grant='a'.repeat(64),sid='MT'+'b'.repeat(32);
let row={id,user_id:full.MASTER,phone:'+12482383969',provider_sid:'AC'+'a'.repeat(32),call_sid:'CA'+'c'.repeat(32),state:'starting',grant_hash:createHash('sha256').update(grant).digest('hex'),grant_expires_at:new Date(Date.now()+60000).toISOString(),stream_sid:null};
full.database=async(path,body)=>{if(!body)return [row];if(row.state!=='starting')return [];row={...row,...body};return [row];};
const archive=require('../lib/dialer-recordings');const start={accountSid:row.provider_sid,callSid:row.call_sid,streamSid:sid,customParameters:{recordingId:id,grant},mediaFormat:{encoding:'audio/x-mulaw',sampleRate:8000,channels:1},tracks:['inbound','outbound']};
(async()=>{
 await assert.rejects(()=>archive.consume({...start,callSid:'CA'+'d'.repeat(32)}));
 await assert.rejects(()=>archive.consume({...start,customParameters:{recordingId:id,grant:'b'.repeat(64)}}));
 await assert.rejects(()=>archive.consume({...start,tracks:['inbound']}));
 const result=await archive.consume(start);assert.equal(result.stream_sid,sid);await assert.rejects(()=>archive.consume(start));
 await assert.rejects(()=>archive.action({body:{action:'start',consent:true}},{id:'another',live:true}));
 await assert.rejects(()=>archive.action({body:{action:'start'}},{id:full.MASTER,live:true}));
 console.log('PASS call/account-bound one-use grants, both-track validation, non-owner restriction, explicit consent');
})().catch(e=>{console.error(e);process.exit(1)});
