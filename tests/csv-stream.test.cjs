const assert=require('node:assert/strict');
const {CsvStream,fingerprint,readCsv}=require('../csv-worker.js');
const {openSync,readSync,closeSync,writeSync,unlinkSync}=require('node:fs');
const {performance}=require('node:perf_hooks');
function diskFile(path,size){const fd=openSync(path,'r');return {size,close:()=>closeSync(fd),slice:(start,end)=>({arrayBuffer:async()=>{const b=Buffer.alloc(Math.max(0,Math.min(end,size)-start));readSync(fd,b,0,b.length,start);return b.buffer.slice(b.byteOffset,b.byteOffset+b.byteLength);}})};}
(async()=>{
 const content='\ufeffName,Notes,City\r\n"José 😀","line 1\r\nline 2, ""quoted""",Detroit\r\nJane,done,Paris';
 const file=new Blob([content]);const rows=[];
 for await(const row of readCsv(file,0,1))rows.push(row);
 assert.deepEqual(rows.map(r=>r.values),[['Name','Notes','City'],['José 😀','line 1\r\nline 2, "quoted"','Detroit'],['Jane','done','Paris']]);
 for(const row of rows){const resumed=[];for await(const r of readCsv(file,row.offset,3))resumed.push(r.values);assert.deepEqual(resumed,rows.slice(rows.indexOf(row)+1).map(r=>r.values));}
 const p=new CsvStream();assert.throws(()=>[...p.feed('"unfinished',true)],/quoted/);
 assert.throws(()=>[...new CsvStream().feed('bad"quote',true)],/quote/);
 assert.throws(()=>[...new CsvStream().feed('x'.repeat(524289),true)],/512 KB/);
 assert.equal(await fingerprint(file),await fingerprint(new Blob([content])));
 assert.notEqual(await fingerprint(file),await fingerprint(new Blob([content.replace('Jane','Jake')])));
 const path='/tmp/lld-million-leads-test.csv',fd=openSync(path,'w');
 const header='First Name,Last Name,Phone,Email,State,Notes\n';writeSync(fd,header);
 const row='Test,Lead,5550000000,example@example.invalid,MI,"A multiline\ncomment, with a comma"\n';
 const block=row.repeat(10000);for(let i=0;i<100;i++)writeSync(fd,block);closeSync(fd);
 const size=Buffer.byteLength(header)+Buffer.byteLength(block)*100;const source=diskFile(path,size);
 global.gc?.();const baseline=process.memoryUsage().heapUsed;let peak=baseline,count=0,batch=[],maxBatch=0;const start=performance.now();
 for await(const r of readCsv(source)){if(!count&&r.values[0]==='First Name'){count=-1;continue;}batch.push(r.values);maxBatch=Math.max(maxBatch,batch.length);if(batch.length===500){batch=[];peak=Math.max(peak,process.memoryUsage().heapUsed);}count++;}
 source.close();unlinkSync(path);assert.equal(count+1,1000000);assert.equal(maxBatch,500);
 console.log(JSON.stringify({passed:true,rows:count+1,fileMB:Number((size/1e6).toFixed(1)),seconds:Number(((performance.now()-start)/1000).toFixed(2)),maxBufferedRows:maxBatch,observedHeapGrowthMB:Number(((peak-baseline)/1e6).toFixed(1)),scope:'Parser only; excludes database upload and browser rendering'}));
})().catch(e=>{console.error(e);process.exitCode=1;});
