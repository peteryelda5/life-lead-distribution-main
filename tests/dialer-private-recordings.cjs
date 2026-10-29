'use strict';
const assert=require('node:assert/strict'),{createHmac}=require('node:crypto'),{once}=require('node:events');
const {AudioAssembler,decodeMuLaw}=require('../lib/dialer-recording-audio');
const parts=[],a=new AudioAssembler((i,b,n)=>parts.push({i,b,n}));
for(let t=0;t<22000;t+=20){for(const track of ['inbound','outbound'])a.add({track,timestamp:String(t),payload:Buffer.alloc(160,track==='inbound'?0:128).toString('base64')});}
assert.equal(a.finish().partial,false);assert.equal(parts.length,3);assert.equal(parts[0].b.toString('ascii',0,4),'RIFF');assert.equal(parts[0].b.readInt16LE(44),decodeMuLaw(0));assert.equal(parts[0].b.readInt16LE(46),decodeMuLaw(128));assert.equal(parts.reduce((n,p)=>n+p.n,0),176000);
assert.throws(()=>new AudioAssembler(()=>{}).add({track:'inbound',timestamp:'600001',payload:'AAAA'}));
const gap=new AudioAssembler(()=>{});gap.add({track:'inbound',timestamp:'0',payload:'AAAA'});gap.add({track:'inbound',timestamp:'500',payload:'AAAA'});assert.equal(gap.finish().partial,true);
Object.assign(process.env,{TWILIO_ACCOUNT_SID:'AC'+'a'.repeat(32),TWILIO_AUTH_TOKEN:'test',TWILIO_API_KEY_SID:'SK'+'a'.repeat(32),TWILIO_API_KEY_SECRET:'test',TWILIO_TWIML_APP_SID:'AP'+'a'.repeat(32),TWILIO_PHONE_NUMBER:'+12025550123',TWILIO_TEST_PHONE_NUMBER:'+12025550124',SUPABASE_SECRET_KEY:'sb_secret_test',STRIPE_SECRET_KEY:'sk_live_test',DIALER_LIVE_BILLING_ENABLED:'true'});
const archive=require('../lib/dialer-recordings'),full=require('../lib/dialer-full');
const saved=[],finished=[];archive.consume=async s=>{assert.equal(s.customParameters.grant,'valid');return {id:'test',stream_sid:'MT'+'b'.repeat(32)};};archive.savePart=async(r,i,b,n)=>saved.push({i,b,n});archive.finish=async(r,partial)=>finished.push(partial);
const server=require('../api/dialer/recording-stream'),{WebSocket}=require('ws');
(async()=>{
 await new Promise(resolve=>server.listen(0,'127.0.0.1',resolve));const url='ws://127.0.0.1:'+server.address().port+'/api/dialer/recording-stream';
 const bad=new WebSocket(url);let rejected=false;bad.on('error',()=>{rejected=true;});await new Promise(resolve=>bad.on('close',resolve));assert(rejected,'Unsigned upgrade denied');
 const signature=createHmac('sha1','test').update(full.ORIGIN.replace('https:','wss:')+'/api/dialer/recording-stream').digest('base64');
 const ws=new WebSocket(url,{headers:{'x-twilio-signature':signature}});await once(ws,'open');let seq=1;const sid='MT'+'b'.repeat(32);const send=m=>ws.send(JSON.stringify({sequenceNumber:String(seq++),streamSid:sid,...m}));
 send({event:'start',start:{customParameters:{grant:'valid'}}});
 for(const track of ['inbound','outbound'])send({event:'media',media:{track,timestamp:'0',payload:Buffer.alloc(160,0).toString('base64')}});
 send({event:'stop'});await once(ws,'close');assert.equal(saved.length,1);assert.equal(saved[0].n,160);assert.deepEqual(finished,[false]);
 await assert.rejects(()=>archive.provider({provider_sid:process.env.TWILIO_ACCOUNT_SID},'Calls/CA'+'a'.repeat(32)+'/Recordings.json',{Record:'true'}),/Forbidden/);
 await new Promise(resolve=>server.close(resolve));console.log('PASS stereo timestamps, chunk persistence, limits/gaps, signed WebSocket, clean stop, Twilio recording creation forbidden');
})().catch(e=>{console.error(e);server.close();process.exit(1)});
