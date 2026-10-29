'use strict';
const RATE=8000,WINDOW=80000,MAX=RATE*600;
function decodeMuLaw(byte){const u=(~byte)&255;let n=((u&15)<<3)+132;n<<=(u&112)>>4;return (u&128)?132-n:n-132;}
function wav(pcm){const h=Buffer.alloc(44);h.write('RIFF');h.writeUInt32LE(pcm.length+36,4);h.write('WAVEfmt ',8);h.writeUInt32LE(16,16);h.writeUInt16LE(1,20);h.writeUInt16LE(2,22);h.writeUInt32LE(RATE,24);h.writeUInt32LE(RATE*4,28);h.writeUInt16LE(4,32);h.writeUInt16LE(16,34);h.write('data',36);h.writeUInt32LE(pcm.length,40);return Buffer.concat([h,pcm]);}
// Timestamp alignment keeps agent/client tracks synchronized. Hold one extra
// window so interleaved inbound/outbound messages can arrive at different times.
class AudioAssembler {
 constructor(emit){this.emit=emit;this.windows=new Map();this.next=0;this.end=0;this.trackEnd={inbound:0,outbound:0};this.partial=false;this.has={inbound:false,outbound:false};}
 add(media){
  if(!media||!['inbound','outbound'].includes(media.track)||!/^\d+$/.test(String(media.timestamp))||typeof media.payload!=='string'||media.payload.length>22000||!/^[A-Za-z0-9+/]+={0,2}$/.test(media.payload))throw Error('Invalid media');
  const data=Buffer.from(media.payload,'base64'),start=Number(media.timestamp)*8,end=start+data.length;
  if(!data.length||!Number.isSafeInteger(start)||end>MAX)throw Error('Recording limit reached');
  if(start<this.next*WINDOW){this.partial=true;return;}
  const previous=this.trackEnd[media.track];if(this.has[media.track]&&start>previous+160)this.partial=true;
  this.has[media.track]=true;this.trackEnd[media.track]=Math.max(previous,end);this.end=Math.max(this.end,end);
  for(let i=0;i<data.length;i++){const sample=start+i,index=Math.floor(sample/WINDOW);let buf=this.windows.get(index);if(!buf){buf=Buffer.alloc(WINDOW*4);this.windows.set(index,buf);}buf.writeInt16LE(decodeMuLaw(data[i]),(sample%WINDOW)*4+(media.track==='inbound'?0:2));}
  while((this.next+2)*WINDOW<this.end)this.flush(WINDOW);
 }
 flush(samples){const index=this.next++,buf=this.windows.get(index)||Buffer.alloc(WINDOW*4);this.windows.delete(index);this.emit(index,wav(buf.subarray(0,samples*4)),samples);}
 finish(){while(this.next*WINDOW<this.end)this.flush(Math.min(WINDOW,this.end-this.next*WINDOW));return {partial:this.partial||!this.has.inbound||!this.has.outbound,durationMs:this.end/8};}
}
module.exports={AudioAssembler,wav,decodeMuLaw};
