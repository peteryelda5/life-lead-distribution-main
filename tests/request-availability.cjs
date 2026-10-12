'use strict';
const assert=require('node:assert/strict'),fs=require('node:fs'),vm=require('node:vm');
const {JSDOM}=require('jsdom'),dom=new JSDOM('<!doctype html><body></body>'),document=dom.window.document;
const q=s=>document.querySelector(s),qa=s=>Array.from(document.querySelectorAll(s));
const rows=['ready','short','none','blocked','done'].map(id=>({id,agent_name:'Agent',recipient_name:'Admin',division:'vivid_life',lead_type:'PRO9',quantity:100,fulfilled_quantity:0,status:id==='done'?'completed':'pending'}));
const S={profile:{id:'admin',role:'admin'},tab:'lead-requests',requests:rows,requestPage:1,requestCount:5,pageSize:500};
const calls=[],pending=[];
const ctx=vm.createContext({S,portalSessionEpoch:0,document,q,qa,URLSearchParams,Map,Set,console,
 esc:s=>String(s).replaceAll('&','&amp;').replaceAll('<','&lt;').replaceAll('>','&gt;').replaceAll('"','&quot;'),
 divisionLabel:s=>s,pager:()=>'',pageCount:()=>1,
 api:async(path,{body})=>{calls.push({path,body:JSON.parse(JSON.stringify(body))});return new Promise((resolve,reject)=>pending.push({resolve,reject}));},
 apiPage:async()=>({data:rows,count:rows.length})
});
vm.runInContext(fs.readFileSync('team-leaders.js','utf8'),ctx);vm.runInContext(fs.readFileSync('request-fulfillment.js','utf8'),ctx);
const run=s=>vm.runInContext(s,ctx),tick=()=>new Promise(r=>setImmediate(r));
const data=[{request_id:'ready',remaining:100,available:140,can_deliver:true,sources:[{source_name:'Owner <img src=x>'}]},{request_id:'short',remaining:80,available:60,can_deliver:true},{request_id:'none',remaining:100,available:0,can_deliver:true},{request_id:'blocked',can_deliver:false}];
(async()=>{
 // The request page resolves before stock finishes, with one aggregate read.
 await ctx.loadLeadRequests();assert.equal(pending.length,1);assert.deepEqual(calls[0].body.p_request_ids,['ready','short','none','blocked']);
 document.body.innerHTML=run('leadRequestsPage()');assert(q('[data-request-availability="ready"]').textContent.includes('Checking stock'));
 pending[0].resolve(data);await tick();
 assert(q('[data-request-availability="ready"]').textContent.includes('Available'));assert(!q('img'));
 assert(q('[data-request-availability="short"]').textContent.includes('Short by 20'));
 assert(q('[data-request-availability="none"]').textContent.includes('No batch match'));
 assert(q('[data-request-availability="blocked"]').textContent.includes('Review agent'));
 assert.equal(q('[data-request-availability="done"]').textContent,'—');
 // A newer page/load wins even if an older HTTP request finishes last.
 const old=ctx.loadLeadRequestAvailability(),fresh=ctx.loadLeadRequestAvailability();pending[2].resolve(data.map(x=>({...x,available:0})));await fresh;pending[1].resolve(data);await old;
 assert(q('[data-request-availability="ready"]').textContent.includes('No batch match'));
 const stale=ctx.loadLeadRequestAvailability();ctx.portalSessionEpoch++;pending[3].resolve(data);await stale;
 assert(run('requestAvailabilityHtml(S.requests[0])').includes('Checking stock'));
 const failed=ctx.loadLeadRequestAvailability();pending[4].reject(Error('Unavailable'));await failed;assert(q('[data-request-availability="ready"]').textContent.includes('Check in Add leads'));
 const before=calls.length;S.profile={id:'agent',role:'agent',is_team_leader:true};await ctx.loadLeadRequestAvailability();assert.equal(calls.length,before);assert(!run('leadRequestsPage()').includes('Matching stock'));
 // Recommendations prefer a full matching delivery, then the agent's own agency.
 ctx.inventory=[{source:'vivid_life',lead_type:' pro9 ',state:'TX',lead_count:20},{source:'owner',lead_type:'PRO9',state:'TX',lead_count:150},{source:'owner',lead_type:'Other',state:'TX',lead_count:1000}];
 ctx.request=rows[0];assert.equal(run('requestDeliveryRecommendation(inventory,request,100).source'),'owner');
 ctx.inventory[0].lead_count=200;assert.equal(run('requestDeliveryRecommendation(inventory,request,100).source'),'vivid_life');
 ctx.inventory[0].lead_count=20;ctx.inventory[1].lead_count=70;assert.equal(run('requestDeliveryRecommendation(inventory,request,100).source'),'owner');
 ctx.request={...rows[0],lead_type:'Unavailable'};assert.equal(run('requestDeliveryRecommendation(inventory,request,100)'),null);
 console.log('PASS: nonblocking batched stock, shortages/no matches, escaped names, inactive targets, completed requests, races/session isolation, safe failure, role visibility and matching-stock recommendations.');
})().catch(e=>{console.error(e);process.exitCode=1;}).finally(()=>dom.window.close());
