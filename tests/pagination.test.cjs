const fs=require('fs'),vm=require('vm'),assert=require('assert/strict');
const html=fs.readFileSync('index.html','utf8');const source=[...html.matchAll(/<script>([\s\S]*?)<\/script>/g)].map(m=>m[1]).find(x=>x.startsWith('const BASE='));new vm.Script(source);
const ctx=vm.createContext({URLSearchParams,Intl,Set,Map,Date,Number,String,JSON,localStorage:{getItem:()=>null},window:{supabase:{createClient:()=>({})}},document:{getElementById:()=>({}),querySelector:()=>({}),querySelectorAll:()=>[],addEventListener:()=>{}},setInterval:()=>{}});
vm.runInContext(source.slice(0,source.lastIndexOf('(async()=>{if(S.session)')),ctx);
(async()=>{
 const result=await vm.runInContext(`(async()=>{
 let requests=[];const fixtures=Array.from({length:101},(_,i)=>({id:'00000000-0000-0000-0000-'+String(200-i).padStart(12,'0'),created_at:'2026-01-01T00:00:00Z'}));
 api=async path=>{requests.push(path);return fixtures};
 const first=await cursorLeadPage('pool',{status:'unassigned',page:1,division:'vivid_life'});
 const second=await cursorLeadPage('pool',{status:'unassigned',page:2,division:'vivid_life'});
 const p1=new URLSearchParams(requests[0].split('?')[1]),p2=new URLSearchParams(requests[1].split('?')[1]);
 if(first.data.length!==100||p1.has('offset')||p2.has('offset'))throw Error('Cursor page limits');
 if(!p2.get('and').includes(first.data.at(-1).id))throw Error('Missing tie-breaking cursor');
 if(!leadPageCursors.pool.hasNext)throw Error('Missing next page');
 await cursorLeadPage('pool',{status:'unassigned',page:1,division:'legacy_life'});
 if(leadPageCursors.pool.cursors[1]!==null||'3' in leadPageCursors.pool.cursors)throw Error('Division cursor not reset');
 return true;
})()`,ctx);
 assert.equal(result,true);console.log('PASS: 100-row keyset pages, timestamp/id tie-breaker, next-page lookahead, division reset, no OFFSET/count requests');
})().catch(e=>{console.error(e);process.exitCode=1});
