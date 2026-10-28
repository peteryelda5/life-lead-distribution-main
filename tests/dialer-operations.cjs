'use strict';
const assert=require('node:assert/strict');
Object.assign(process.env,{SUPABASE_SECRET_KEY:'sb_secret_test',STRIPE_SECRET_KEY:'sk_live_test',DIALER_LIVE_BILLING_ENABLED:'true'});
const user='11111111-1111-4111-8111-111111111111',session='22222222-2222-4222-8222-222222222222',id='33333333-3333-4333-8333-333333333333';
let authenticated=true,supervisor=true,calls=[];
const json=(data,status=200)=>new Response(JSON.stringify(data),{status});
global.fetch=async(url,opt={})=>{
 if(url.endsWith('/rpc/require_portal_onboarding'))return json(true);
 if(url.endsWith('/rpc/require_portal_mfa'))return json(false);
 if(url.includes('/auth/v1/user'))return authenticated?json({id:user,email:'fixture@example.invalid'}):json({},401);
 if(url.includes('/rest/v1/profiles?'))return json([{id:user,active:true,archived:false,role:'agent'}]);
 if(url.includes('/rest/v1/dialer_priority_tasks?')){const q=new URL(url).searchParams;assert.equal(q.get('user_id'),'eq.'+user);assert.equal(q.get('resolved_at'),'is.null');assert.equal(opt.method,'PATCH');return json([{id}]);}
 if(url.includes('/rest/v1/rpc/')){const name=url.split('/').at(-1),body=JSON.parse(opt.body);calls.push({name,body});
  if(name==='dialer_session_valid')return json(true);
  assert.equal(body.p_user,user,'Client selected another actor');assert.equal(body.p_live,true);
  if(name==='dialer_supervisor_workspace'&&!supervisor)return json({message:'Supervisor access required'},403);
  if(name==='dialer_priority_list')return json({due:1,total:1,tasks:[{id,matches:[{id,first_name:'Fixture',phone:'+12025550194',csv_headers:['DOB'],csv_values:['1980-01-02']}]}]});
  return json({saved:true,mode:body.p_mode||'ready',supervisor});
 }
 throw Error('Unexpected request '+url);
};
const handler=require('../api/dialer/operations');
const token=aal=>['x',Buffer.from(JSON.stringify({sub:user,aal,session_id:session,exp:Math.floor(Date.now()/1000)+3600})).toString('base64url'),'x'].join('.');
async function run(body,{aal='aal2',origin='https://www.lldportal.com',method='POST'}={}){const res={headers:{},setHeader(k,v){this.headers[k]=v;},status(n){this.code=n;return this;},json(d){this.data=d;return this;}};await handler({method,headers:{origin,authorization:'Bearer '+token(aal)},body},res);return res;}
(async()=>{
 let r=await run({action:'presence',browserId:id,activity:'idle',visible:true,mode:'break',userId:id});assert.equal(r.code,200);assert.equal(calls.at(-1).body.p_session,session);assert.equal(calls.at(-1).body.p_mode,'break');
 r=await run({action:'presence',browserId:id,activity:'invented',visible:true});assert.equal(r.code,400);
 r=await run({action:'schedule',id,leadId:id,dueAt:'invalid',note:''});assert.equal(r.code,400);
 r=await run({action:'schedule',id,leadId:id,dueAt:new Date(Date.now()+3600000).toISOString(),note:'Call tomorrow'});assert.equal(r.code,200);
 r=await run({action:'priority'});assert.equal(r.code,200);assert.equal(r.data.tasks[0].matches[0].csv_values[0],'1980-01-02');
 r=await run({action:'resolve',id});assert.equal(r.code,200);assert.equal(calls.at(-1).body.p_id,id);
 r=await run({action:'reschedule',id,dueAt:new Date(Date.now()+900000).toISOString()});assert.equal(r.code,200);
 r=await run({action:'reschedule',id:session,dueAt:new Date(Date.now()+900000).toISOString()});assert.equal(r.code,403);
 r=await run({action:'reschedule',id,dueAt:new Date(Date.now()-1000).toISOString()});assert.equal(r.code,400);
 supervisor=false;r=await run({action:'supervisor',userId:id});assert.notEqual(r.code,200);
 r=await run({action:'priority'},{aal:'aal1'});assert.equal(r.code,403);
 r=await run({action:'priority'},{origin:'https://example.invalid'});assert.equal(r.code,403);
 r=await run({action:'priority'},{method:'GET'});assert.equal(r.code,405);
 authenticated=false;r=await run({action:'priority'});assert.equal(r.code,401);
 console.log('PASS: operations route MFA/origin/method, server-derived owner/mode/session, input validation, scoped denial, callback lead-card response.');
})().catch(e=>{console.error(e);process.exitCode=1;});
