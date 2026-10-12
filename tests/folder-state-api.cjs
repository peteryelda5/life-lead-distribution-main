'use strict';
const vm=require('node:vm'),fs=require('node:fs'),assert=require('node:assert/strict');
const calls=[];const mod={exports:{}};
const ctx=vm.createContext({module:mod,URLSearchParams,AbortSignal,require:name=>name.endsWith('lead-calling')?{displayLead:l=>l}:{authenticate:async()=>({id:'authenticated-user'}),failure:(status,message)=>Object.assign(Error(message),{status})},fetch:async(url,options)=>{calls.push({url,options,body:JSON.parse(options.body)});return{ok:true,text:async()=>JSON.stringify({data:[{id:'lead',state:'TX'}],count:501,states:[{state:'TX',lead_count:501}]})};}});
vm.runInContext(fs.readFileSync(__dirname+'/../api/dialer/workspace-v2.js','utf8'),ctx);
async function invoke(body){const res={setHeader(){},status(n){this.code=n;return this;},json(data){this.data=data;return this;}};await mod.exports({method:'POST',headers:{origin:'https://www.lldportal.com',authorization:'Bearer user-jwt'},body},res);return res;}
(async()=>{let r=await invoke({action:'leads',offset:500,folder:'Pro5',states:['TX','FL']});assert.equal(r.code,200);assert.equal(r.data.count,501);assert.deepEqual(calls.at(-1).body,{p_folder:true,p_lead_type:'Pro5',p_page:2,p_limit:500,p_states:['TX','FL']});assert.ok(calls.at(-1).url.endsWith('/rpc/my_assigned_leads_filtered'));assert.equal(calls.at(-1).options.headers.Authorization,'Bearer user-jwt');
 await invoke({action:'leads',offset:0,folder:null,states:['']});assert.equal(calls.at(-1).body.p_folder,true);assert.equal(calls.at(-1).body.p_lead_type,null);
 await invoke({action:'leads',offset:0});assert.equal(calls.at(-1).body.p_folder,false);assert.deepEqual(calls.at(-1).body.p_states,[]);
 for(const patch of [{offset:1},{offset:-500},{states:'TX'},{states:[null]},{states:Array(101).fill('TX')},{states:['X'.repeat(101)]},{folder:{}}]){const before=calls.length;r=await invoke({action:'leads',offset:0,...patch});assert.equal(r.code,400);assert.equal(calls.length,before);}
 console.log('PASS: authenticated folder/state RPC, multi-state pagination, unlabeled/unknown states, all-state defaults, invalid input rejected before database access.');})().catch(e=>{console.error(e);process.exitCode=1;});
