'use strict';
const assert=require('node:assert/strict');
const ago=ms=>new Date(Date.now()-ms).toISOString();
const unused={id:'unused',call_kind:'lead',finished:false,parent_sid:null,child_sid:null,duration_seconds:0,expires_at:ago(3600000)};
const rows=[unused,{...unused,id:'provider-bound',parent_sid:'CA-bound'},{...unused,id:'child-bound',child_sid:'CA-child'},{...unused,id:'power',call_kind:'power'},{...unused,id:'not-expired',expires_at:ago(-60000)},{...unused,id:'recent-expiry',expires_at:ago(5000)},{...unused,id:'duration-evidence',duration_seconds:4}];
require.cache[require.resolve('../lib/dialer-full')]={exports:{database:async(path,patch,method)=>{
 assert.equal(method,'PATCH');const params=new URL('https://fixture/'+path).searchParams;
 const matches=rows.filter(row=>[...params].filter(([key])=>key!=='select').every(([key,filter])=>{
  const dot=filter.indexOf('.'),op=filter.slice(0,dot),value=filter.slice(dot+1);
  if(op==='eq')return String(row[key])===value;if(op==='is')return row[key]===null&&value==='null';
  if(op==='in')return value.slice(1,-1).split(',').includes(row[key]);if(op==='lt')return Date.parse(row[key])<Date.parse(value);throw Error(op);
 }));matches.forEach(row=>Object.assign(row,patch));return matches.map(r=>({id:r.id}));
}}};
(async()=>{const app=require('../lib/dialer-reservations');assert.deepEqual(await app.cleanup(),{unusedReservationsClosed:1});assert.equal(unused.call_status,'canceled');assert(rows.slice(1).every(r=>r.finished===false));assert.deepEqual(await app.cleanup(),{unusedReservationsClosed:0});console.log('PASS: unused expired grants close once; bound calls, Power Dialer, recent grants and duration evidence are preserved.');})().catch(e=>{console.error(e);process.exitCode=1;});
