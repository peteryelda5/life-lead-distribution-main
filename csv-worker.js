/* Streaming UTF-8 CSV parser. Memory is bounded by one input block and one batch. */
class CsvStream {
  constructor(offset=0) { this.offset=offset; this.rowStart=offset; this.cell=''; this.row=[]; this.mode='plain'; this.skipLF=false; }
  *feed(text, final=false) {
    for (const ch of text) {
      const code=ch.codePointAt(0); const width=code<128?1:code<2048?2:code<65536?3:4;
      const first=this.offset===0; this.offset+=width;
      if(first&&ch==='\ufeff')continue;
      if(this.offset-this.rowStart>524288)throw Error('A CSV row exceeds 512 KB. Split oversized cells before importing.');
      if(this.skipLF){this.skipLF=false;if(ch==='\n'){this.rowStart=this.offset;continue;}}
      if(this.mode==='quoted') { if(ch==='"')this.mode='after';else this.cell+=ch;continue; }
      if(this.mode==='after'&&ch==='"'){this.cell+='"';this.mode='quoted';continue;}
      if(ch===','||ch==='\n'||ch==='\r') {
        this.row.push(this.cell);this.cell='';this.mode='plain';
        if(this.row.length>256)throw Error('CSV rows must contain at most 256 columns.');
        if(ch!==','){const values=this.row;this.row=[];this.rowStart=this.offset;this.skipLF=ch==='\r';if(values.some(v=>v.trim()!==''))yield {values,offset:this.offset};}
      } else if(ch==='"'&&this.mode==='plain'&&!this.cell){this.mode='quoted';}
      else {if(this.mode==='after')throw Error('Unexpected text after a quoted CSV field.');if(ch==='"')throw Error('Unexpected quote in an unquoted CSV field.');this.cell+=ch;}
    }
    if(final){if(this.mode==='quoted')throw Error('CSV ends inside a quoted field.');if(this.cell!==''||this.row.length){this.row.push(this.cell);if(this.row.length>256)throw Error('CSV rows must contain at most 256 columns.');if(this.row.some(v=>v.trim()!==''))yield {values:this.row,offset:this.offset};this.row=[];this.cell='';}}
  }
}
async function fingerprint(file,progress=()=>{}) {
  let hash=new Uint8Array(32);const size=1024*1024;
  for(let start=0;start<file.size;start+=size){const block=new Uint8Array(await file.slice(start,start+size).arrayBuffer());const input=new Uint8Array(32+block.length);input.set(hash);input.set(block,32);hash=new Uint8Array(await crypto.subtle.digest('SHA-256',input));progress(Math.min(file.size,start+size));}
  return [...hash].map(x=>x.toString(16).padStart(2,'0')).join('');
}
async function* readCsv(file,offset=0,blockSize=262144) {
  const parser=new CsvStream(offset),decoder=new TextDecoder('utf-8',{fatal:true,ignoreBOM:true});
  for(let pos=offset;pos<file.size;pos+=blockSize){const block=await file.slice(pos,pos+blockSize).arrayBuffer();yield* parser.feed(decoder.decode(block,{stream:true}));}
  yield* parser.feed(decoder.decode(),true);
}
if(typeof module!=='undefined')module.exports={CsvStream,fingerprint,readCsv};
if(typeof self!=='undefined'&&typeof self.postMessage==='function'){
 let wake;
 const exchange=message=>new Promise(resolve=>{wake=resolve;self.postMessage(message);});
 self.onmessage=async({data})=>{
  if(data.type==='ack'){const fn=wake;wake=null;if(fn)fn(data);return;}
  if(data.type!=='start')return;
  try{
   const file=data.file;
   const hash=await fingerprint(file,bytes=>self.postMessage({type:'hashing',bytes,total:file.size}));
   const resume=await exchange({type:'fingerprint',hash});
   let rows=[],offset=resume.offset||0,batchBytes=0;
   for await(const record of readCsv(file,offset)){
    rows.push(record.values);batchBytes+=JSON.stringify(record.values).length;
    if(rows.length>=500||batchBytes>=262144){await exchange({type:'batch',rows,offset:record.offset});rows=[];batchBytes=0;}
   }
   if(rows.length)await exchange({type:'batch',rows,offset:file.size});
   self.postMessage({type:'done',offset:file.size});
  }catch(error){self.postMessage({type:'error',message:error.message});}
 };
}
