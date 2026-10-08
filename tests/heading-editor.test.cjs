'use strict';
const assert=require('node:assert/strict'),vm=require('node:vm'),fs=require('node:fs');
const html=fs.readFileSync(__dirname+'/../index.html','utf8');
const code=html.slice(html.indexOf('function headingSaveKey()'),html.indexOf('function bindLeadColumnLayout'));
const values=new Map(),requests=[];let mode='fail',failures=0,nodes,inputs,closed=false;
const submit={disabled:false,textContent:'Save headings'},select={value:'0',disabled:false,focus(){}},error={className:'error',textContent:'',setAttribute(){}};
const field={set innerHTML(v){inputs=[...v.matchAll(/<input[^>]*value="([^"]*)"([^>]*)>/g)].map(m=>({value:m[1],disabled:m[2].includes('disabled')}))}};
const panel={isConnected:true,contains(){return false},remove(){this.isConnected=false},querySelector(){return submit},querySelectorAll(s){return s==='.headingInput'?inputs:s==='button'?[submit]:s==='input,select'?[...inputs,select]:[submit,...inputs,select]}};
function mount(){panel.isConnected=true;select.value='0';nodes={'#headingPanel':panel,'#headingForm':{},'#headingFields':field,'#headingBatch':select,'#headingError':error,'#headingCancel':{},'#headingClose':{}}}
const ctx={S:{profile:{id:'master'},poolLeads:[{id:'sample',csv_headers:['Name','Phone'],csv_filename:'import.csv',lead_type:'Batch',uploaded_by:null}]},q:s=>nodes[s],jsonArray:v=>Array.isArray(v)?v:[],esc:String,sessionStorage:{getItem:k=>values.get(k)||null,setItem:(k,v)=>values.set(k,v),removeItem:k=>values.delete(k)},closeHeadingPanel(){closed=true;panel.isConnected=false},document:{body:{insertAdjacentHTML:mount},addEventListener(){},removeEventListener(){}},flash(){},loadPoolPage:async()=>{},setTimeout:fn=>fn(),api:async(path,opt)=>{requests.push(JSON.parse(JSON.stringify(opt.body)));if(mode==='fail'){if(!opt.body.p_after)return {updated:25,done:false,nextCursor:'cursor-1'};failures++;throw new Error('canceling statement due to statement timeout')}if(opt.body.p_after==='cursor-1')return {updated:0,done:false,nextCursor:'cursor-2'};return {updated:1,done:true,nextCursor:'cursor-3'}}};
vm.createContext(ctx);vm.runInContext(code,ctx);
(async()=>{
ctx.editBatchHeadings();inputs[0].value='Client';await nodes['#headingForm'].onsubmit({preventDefault(){},submitter:submit});
assert.equal(failures,3);assert.equal(requests.filter(r=>r.p_after==='cursor-1').length,3);let saved=JSON.parse(values.get('vivid_heading_save_v1:master'));assert.equal(saved.cursor,'cursor-1');assert.equal(saved.updated,25);assert.deepEqual(saved.headers,['Client','Phone']);assert(inputs.every(i=>i.disabled));assert(error.textContent.includes('progress is saved'));
mode='resume';closed=false;const before=requests.length;ctx.editBatchHeadings();assert(inputs.every(i=>i.disabled));await nodes['#headingForm'].onsubmit({preventDefault(){},submitter:submit});assert.equal(requests[before].p_after,'cursor-1');assert.equal(requests[before+1].p_after,'cursor-2');assert.equal(values.size,0);assert.equal(closed,true);
ctx.S.profile.id='another';values.set('vivid_heading_save_v1:master',JSON.stringify(saved));assert.equal(ctx.readHeadingSave(),null);
ctx.editBatchHeadings();inputs[0].value='Phone';const n=requests.length;await nodes['#headingForm'].onsubmit({preventDefault(){},submitter:submit});assert.equal(requests.length,n);assert(error.textContent.includes('different name'));
console.log('Passed: bounded timeout retries, saved cursor, reload resume, zero-update progress, account isolation, duplicate validation.');
})().catch(e=>{console.error(e);process.exitCode=1});
