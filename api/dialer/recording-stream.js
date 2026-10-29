'use strict';
const http=require('node:http');
const {WebSocketServer}=require('ws');
const {config,ORIGIN}=require('../../lib/dialer-full');
const {createHmac,timingSafeEqual}=require('node:crypto');
function signed(req){const given=Buffer.from(req.headers['x-twilio-signature']||'');return [ORIGIN,ORIGIN.replace('https:','wss:')].some(origin=>['','/'].some(suffix=>{const value=Buffer.from(createHmac('sha1',config().TWILIO_AUTH_TOKEN).update(origin+'/api/dialer/recording-stream'+suffix).digest('base64'));return value.length===given.length&&timingSafeEqual(value,given);}));}
const archive=require('../../lib/dialer-recordings');
const {AudioAssembler}=require('../../lib/dialer-recording-audio');
const server=http.createServer((req,res)=>{res.writeHead(426,{'Cache-Control':'no-store'});res.end('WebSocket required');});
const wss=new WebSocketServer({noServer:true,maxPayload:32768,perMessageDeflate:false});
server.on('upgrade',(req,socket,head)=>{
 try{if(req.url!=='/api/dialer/recording-stream'||!signed(req))throw Error('Signature');
  wss.handleUpgrade(req,socket,head,ws=>wss.emit('connection',ws));
 }catch{socket.write('HTTP/1.1 403 Forbidden\r\nConnection: close\r\n\r\n');socket.destroy();}
});
wss.on('connection',ws=>{
 let row=null,assembler=null,chain=Promise.resolve(),writes=Promise.resolve(),pending=0,queued=0,ending=false,broken=false,lastSequence=0;
 const finish=async(normal=false)=>{if(ending)return;ending=true;clearTimeout(handshake);clearTimeout(limit);clearInterval(ping);try{if(assembler){const result=assembler.finish();await writes;await archive.finish(row,!normal||broken||result.partial);}}catch{console.error('private_recording_finalize_failed');}finally{ws.close();}};
 const handshake=setTimeout(()=>{if(!row)ws.close(1008,'Start required');},10000);
 const limit=setTimeout(()=>{broken=true;finish(false);},600000);
 const ping=setInterval(()=>{if(ws.readyState===1)ws.ping();},20000);
 ws.on('message',raw=>{
  if(ending)return;if(++queued>250){broken=true;ws.close(1008,'Backpressure');return;}
  chain=chain.then(async()=>{
   queued--;if(ending)return;const m=JSON.parse(raw.toString());
   if(m.event==='connected')return;
   const seq=Number(m.sequenceNumber);if(!Number.isSafeInteger(seq)||seq<=lastSequence)throw Error('Invalid media sequence');if(lastSequence&&seq!==lastSequence+1)broken=true;lastSequence=seq;
   if(m.event==='start'){
    if(row)throw Error('Duplicate start');row=await archive.consume(m.start);clearTimeout(handshake);
    assembler=new AudioAssembler((index,audio,samples)=>{
     if(++pending>6)throw Error('Storage backpressure');
     writes=writes.then(()=>archive.savePart(row,index,audio,samples)).finally(()=>pending--);
     writes.catch(()=>{broken=true;});
    });return;
   }
   if(!row||m.streamSid!==row.stream_sid)throw Error('Stream mismatch');
   if(m.event==='media')assembler.add(m.media);
   else if(m.event==='stop')await finish(true);
  }).catch(()=>{broken=true;finish(false);});
 });
 ws.on('close',()=>{chain.then(()=>finish(false));});ws.on('error',()=>{broken=true;chain.then(()=>finish(false));});
});
module.exports=server;
