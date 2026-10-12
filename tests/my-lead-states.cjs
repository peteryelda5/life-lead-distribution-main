'use strict';
const assert=require('node:assert/strict'),fs=require('node:fs'),vm=require('node:vm');
const source=require('./portal-document.cjs')();const calls=[],nodes=new Map();const node=id=>{if(!nodes.has(id))nodes.set(id,{isConnected:true,disabled:false,value:'',querySelectorAll:()=>[]});return nodes.get(id)};
let checks=[{value:'TX',checked:true},{value:'FL',checked:true}];const folderButtons=[{dataset:{folder:'0'}},{dataset:{folder:'1'}}];
const S={myPage:4,myFolder:{type:'Pro5'},myFolders:[{lead_type:'Other'}],myStates:[],myStateOptions:[],mySearch:'Alice',pageSize:500,tab:'my-leads'};
const ctx=vm.createContext({S,api:async(url,{body})=>{calls.push({url,body:JSON.parse(JSON.stringify(body))});return{data:[{id:'lead'}],count:501,states:[{state:'TX',lead_count:500},{state:'FL',lead_count:1}]}},pageCount:n=>Math.max(1,Math.ceil(n/500)),q:node,qa:s=>s==='.my-lead-folder'?folderButtons:s==='#myLeadStatesForm input:checked'?checks:[],render(){},flash(){},esc:s=>String(s),console});
for(const name of ['loadMyLeadsPage','myLeadStates','bindMyFolders','bindMyLeadSearch']){const line=source.split('\n').find(s=>s.startsWith('function '+name+'(')||s.startsWith('async function '+name+'('));vm.runInContext(line,ctx);}
(async()=>{vm.runInContext('bindMyFolders()',ctx);await node('#myLeadStatesForm').onsubmit({preventDefault(){}});assert.deepEqual(S.myStates,['TX','FL']);assert.equal(S.myPage,1);assert.deepEqual(calls.at(-1).body,{p_search:'Alice',p_lead_type:'Pro5',p_folder:true,p_page:1,p_limit:500,p_states:['TX','FL']});assert.equal(S.myCount,501);assert.equal(S.myStateOptions.length,2);
 S.myPage=2;await vm.runInContext('loadMyLeadsPage()',ctx);assert.equal(calls.at(-1).body.p_page,2);assert.deepEqual(calls.at(-1).body.p_states,['TX','FL']);
 await folderButtons[1].onclick();assert.equal(S.myFolder.type,'Other');assert.equal(S.myPage,1);assert.equal(S.myStates.length,0);
 S.myStates=['TX'];node('#myLeadSearch').value='Bob';await node('#myLeadSearchForm').onsubmit({preventDefault(){}});assert.equal(calls.at(-1).body.p_search,'Bob');assert.deepEqual(calls.at(-1).body.p_states,['TX']);assert.ok(vm.runInContext('myLeadStates()',ctx).includes('States to dial'));
 S.myFilterBusy=true;const before=calls.length;await folderButtons[0].onclick();assert.equal(calls.length,before);
 console.log('PASS: My Leads state choices, folder resets, search plus states, pagination, server counts and request lock.');})().catch(e=>{console.error(e);process.exitCode=1;});
