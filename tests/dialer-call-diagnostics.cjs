'use strict';
const assert=require('node:assert/strict');
const account='AC'+'a'.repeat(32),parent='CA'+'b'.repeat(32),child='CA'+'c'.repeat(32),user='11111111-1111-4111-8111-111111111111',id='22222222-2222-4222-8222-222222222222';
const ctx={TWILIO_ACCOUNT_SID:account,TWILIO_AUTH_TOKEN:'secret-never-stored'};
const row={id,user_id:user,phone:'+12025550191',caller_id:'+12025550192',parent_sid:parent,child_sid:child,call_kind:'lead',call_status:'failed',created_at:new Date(Date.now()-3600000).toISOString(),finished_at:new Date(Date.now()-3500000).toISOString(),finished:true,duration_seconds:0};
let reads=[],writes=[],enabled=true,mismatch=false,wrongAgent=false,contextReads=0,failSummary=false;
require.cache[require.resolve('../lib/dialer-full')]={exports:{mode:()=>true,identity:uid=>'vivid_'+uid.replaceAll('-',''),database:async(path,body,method)=>{
 if(body){assert.equal(path,'dialer_call_diagnostics');assert.equal(method,'POST');writes.push(body);return[body];}
 if(path.startsWith('dialer_calls?'))return[row];if(path.startsWith('dialer_call_diagnostics?'))return[];throw Error('Unexpected database read');
}}};
require.cache[require.resolve('../lib/dialer-at-cost-provider')]={exports:{context:async u=>{assert.equal(u.id,user);assert.equal(u.live,true);contextReads++;return ctx;}}};
global.fetch=async(url,options)=>{
 reads.push(url);assert.equal(options.method,'GET');assert.equal(options.redirect,'error');assert.equal(options.body,undefined);assert.match(options.headers.Authorization,/^Basic /);
 let data,status=200;
 if(url.includes('monitor.twilio.com'))data={alerts:[{account_sid:account,resource_sid:child,error_code:'21217',log_level:'error',alert_text:'secret customer text',request_headers:{authorization:'secret'},date_generated:new Date().toISOString()}],meta:{next_page_url:null}};
 else if(url.endsWith('/Settings'))data={account_sid:account,advanced_features:enabled};
 else if(url.endsWith('/Summary')){if(failSummary){status=403;data={code:17007};}else data={call_sid:url.includes(parent)?parent:child,account_sid:account,processing_state:'complete',call_state:'fail',properties:{disconnected_by:'callee',last_sip_response_num:404,pdd_ms:1200},tags:['high_packet_loss'],to:{ip_address:'private address'},sdk_edge:{properties:{disconnected_by:'remote',ip_address:'private address'},metrics:{inbound:{jitter:{max:12,avg:3,secret:'do not store'},packets:{lost:2,total:100},ip_address:'private address'}}}};}
 else if(url.endsWith('/'+parent+'.json'))data={sid:parent,account_sid:account,from:wrongAgent?'client:other':'client:vivid_'+user.replaceAll('-',''),status:'completed',duration:'6',start_time:new Date().toISOString()};
 else if(url.endsWith('/'+child+'.json'))data={sid:child,account_sid:mismatch?'AC'+'f'.repeat(32):account,parent_call_sid:parent,from:row.caller_id,to:row.phone,status:'failed',duration:'0'};
 else throw Error('Unexpected provider URL '+url);
 return new Response(JSON.stringify(data),{status});
};
const app=require('../lib/dialer-call-diagnostics');
(async()=>{
 const diagnostics=await app.accountDiagnostics(ctx,row.created_at);
 let result=await app.collect(row,ctx,diagnostics);
 assert.equal(result.state,'complete');assert.equal(result.details.legs.recipient.alerts[0].code,21217);
 assert.equal(result.details.legs.agent.insights.disconnectedBy,'callee');
 assert.equal(result.details.legs.agent.insights.edges.sdk_edge.metrics.inbound.jitter.max,12);
 assert.doesNotMatch(JSON.stringify(result),/secret|private address|authorization|alert_text|request_headers|1202555/);
 mismatch=true;await assert.rejects(()=>app.collect(row,ctx,diagnostics),e=>e.ownership===true);mismatch=false;
 wrongAgent=true;await assert.rejects(()=>app.collect(row,ctx,diagnostics),e=>e.ownership===true);wrongAgent=false;
 enabled=false;reads=[];result=await app.collect(row,ctx,await app.accountDiagnostics(ctx,row.created_at));
 assert.equal(result.details.insightsEnabled,false);assert.ok(!reads.some(url=>url.endsWith('/Summary')),'Disabled paid Insights was queried');
 enabled=true;failSummary=true;result=await app.collect(row,ctx,await app.accountDiagnostics(ctx,row.created_at));
 assert.equal(result.state,'partial');assert.equal(result.details.legs.agent.insightsError.code,17007);failSummary=false;
 const candidates=[row,{...row,id:'new',created_at:new Date().toISOString(),finished_at:new Date().toISOString()},{...row,id:'active',finished:false}];
 assert.deepEqual(app.selectPending(candidates,[]).map(r=>r.id),[id]);
 assert.equal(app.selectPending(candidates,[{call_id:id,state:'complete',checked_at:row.created_at}]).length,0);
 const many=Array.from({length:20},(_,i)=>({...row,id:'a'+i}));many.push({...row,id:'another-agent',user_id:'other',call_status:'completed',duration_seconds:45});
 const pending=app.selectPending(many,[]);assert.equal(pending.length,12);assert.ok(pending.some(r=>r.id==='another-agent'));
 const maintenance=await app.maintenance();assert.deepEqual(maintenance,{checked:1,errors:0});assert.equal(writes.length,1);assert.equal(contextReads,1);
 const route=require('../api/dialer/health-maintenance');process.env.CRON_SECRET='fixture-cron';
 const response=()=>({setHeader(){},status(n){this.code=n;return this;},json(d){this.data=d;return this;},end(){return this;}});
 let res=response();await route({method:'GET',headers:{}},res);assert.equal(res.code,401);assert.equal(writes.length,1);
 res=response();await route({method:'POST',headers:{authorization:'Bearer fixture-cron'}},res);assert.equal(res.code,405);
 res=response();await route({method:'GET',headers:{authorization:'Bearer fixture-cron'}},res);assert.equal(res.code,200);assert.equal(writes.length,2);
 assert.ok(reads.every(url=>!url.includes('/Recordings')&&!url.includes('/Transcriptions')));
 console.log('PASS: read-only provider requests, exact call/account/agent ownership, redacted diagnostics, no paid-feature activation, error evidence, fair bounded sampling, deduplication, active-call exclusion and cron authentication.');
})().catch(e=>{console.error(e);process.exitCode=1;});
