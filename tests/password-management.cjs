const assert=require('node:assert/strict'),handler=require('../api/auth/agent-password');
const owner='00000000-0000-4000-8000-000000000001',agent='00000000-0000-4000-8000-000000000002';
process.env.SUPABASE_SECRET_KEY='sb_secret_test';process.env.VERCEL_ENV='production';
(async()=>{let state,calls;global.fetch=async(url,opt)=>{calls.push({url,opt});let data={},status=200;if(url.endsWith('/auth/v1/user')){data={id:owner};if(state.unauth)status=401;}else if(url.includes('require_portal_mfa'))data=!state.noMfa;else if(url.includes('/profiles?'))data=[url.includes(owner)?{role:state.agentCaller?'agent':'admin',active:true,archived:false,is_super_admin:!state.agentCaller}:{role:state.adminTarget?'admin':'agent',active:true,archived:false}];else if(url.includes('audit_logs?'))data=state.limited?[1,2,3,4,5]:[];else if(url.includes('/auth/v1/admin/')){data={id:agent};if(state.providerFailure)status=400;}return {ok:status<300,status,text:async()=>JSON.stringify(data)};};
 async function run(s={},body={agent_id:agent,password:'Fictional-test-password-123'},headers={origin:'https://www.lldportal.com',authorization:'Bearer test.token.sig'}){state=s;calls=[];const res={setHeader(){},status(n){this.code=n;return this},json(d){this.data=d;return this}};await handler({method:'POST',headers,body},res);return res;}
 for(const [s,code] of [[{unauth:true},401],[{noMfa:true},403],[{agentCaller:true},403],[{adminTarget:true},404],[{limited:true},429]]){assert.equal((await run(s)).code,code);assert(!calls.some(c=>c.url.includes('/auth/v1/admin/')));}
 assert.equal((await run({}, {agent_id:agent,password:'short'})).code,400);
 assert.equal((await run({},undefined,{origin:'https://evil.invalid',authorization:'Bearer token'})).code,403);
 assert.equal((await run({providerFailure:true})).code,400);
 assert.equal((await run()).code,200);assert.equal(calls.filter(c=>c.url.includes('/auth/v1/admin/')).length,1);assert(!JSON.stringify(calls.filter(c=>c.url.includes('audit_logs'))).includes('Fictional-test-password'));
 console.log('PASS: verified owner only, MFA, agent target, password validation, origin, throttling, provider failure, audit excludes password');
})().catch(e=>{console.error(e);process.exit(1)});
