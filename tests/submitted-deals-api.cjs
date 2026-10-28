'use strict';
const assert=require('node:assert/strict'),{createHash}=require('node:crypto');
const handler=require('../api/submitted-deals');
const token='vllb_'+'a'.repeat(43),headers={authorization:'Bearer '+token};
process.env.SUPABASE_SECRET_KEY='sb_secret_test_only';
const id='00000000-0000-0000-0000-000000000001';
const row={deal_id:id,agent_id:id,agent_name:'Example Agent',agency:'PRIVATE',monthly_premium:100,annual_premium:1200,submitted_at:'2026-10-28T12:00:00Z',client_name:'PRIVATE',status:'PRIVATE',carrier_status:'PRIVATE',notes:'PRIVATE'};
const data={as_of:row.submitted_at,period:{key:'month',start:'2026-10-01',end_exclusive:'2026-11-01'},deals:[row],next_after:null,crm:'PRIVATE'};
let calls=[],value={status:200,data},ok=true;
global.fetch=async(url,options)=>{calls.push({url,options});return {ok,json:async()=>value};};
async function request(overrides={}){const res={headers:{},setHeader(k,v){this.headers[k]=v;},status(s){this.code=s;return this;},json(body){this.body=body;return this;}};await handler({method:'GET',url:'/api/submitted-deals',headers,...overrides},res);return res;}
(async()=>{
 for(const method of ['POST','PUT','PATCH','DELETE','HEAD','OPTIONS'])assert.equal((await request({method})).code,405);
 for(const authorization of [undefined,'','Bearer '+token+'x',['Bearer '+token]])assert.equal((await request({headers:{authorization}})).code,401);
 for(const query of ['status=issued','select=*','agency=all','division=all','key='+token,'period=all','period=month&period=today','period=previous','month=2026-09-01','period=previous&month=2026-13-01','after=bad','limit=0','limit=501','limit=-1','limit=1.5','limit=01','limit=1&limit=2'])assert.equal((await request({url:'/api/submitted-deals?'+query})).code,400,query);
 assert.equal(calls.length,0);
 let r=await request();assert.equal(r.code,200);assert(!JSON.stringify(r).includes('PRIVATE'));
 assert.deepEqual(Object.keys(r.body.deals[0]).sort(),['deal_id','agent_id','agent_name','agency','monthly_premium','annual_premium','submitted_at'].sort());
 assert.equal(r.body.deals[0].agency,'Vivid Life Advisors');assert.match(r.headers['Cache-Control'],/no-store/);assert.equal(r.headers.Vary,'Authorization');
 assert.deepEqual(JSON.parse(calls[0].options.body),{p_key_hash:createHash('sha256').update(token).digest('hex'),p_period:'month',p_month:null,p_after:null,p_limit:200});
 assert(!calls[0].options.body.includes(token));assert.match(calls[0].url,/\/submitted_deals_api_read$/);
 for(const period of ['today','week','month','previous&month=2026-09-01'])assert.equal((await request({url:'/api/submitted-deals?period='+period+'&limit=2&after='+id})).code,200);
 assert.equal(JSON.parse(calls.at(-1).options.body).p_after,id);
 value={status:200,data:{...data,next_after:id,deals:[{...row,monthly_premium:null,annual_premium:null}]}};r=await request();assert.equal(r.body.next_after,id);assert.equal(r.body.deals[0].monthly_premium,null);
 value={status:200,data:{...data,deals:[]}};assert.deepEqual((await request()).body.deals,[]);
 for(const status of [400,401,429]){value={status,secret:'PRIVATE'};r=await request();assert.equal(r.code,status);assert(!JSON.stringify(r).includes('PRIVATE'));if(status===429)assert.equal(r.headers['Retry-After'],'60');}
 for(const bad of [null,{...data,next_after:'bad'},{...data,deals:[{...row,deal_id:'bad'}]},{...data,deals:[{...row,annual_premium:'PRIVATE'}]}]){value={status:200,data:bad};assert.equal((await request()).code,503);}
 ok=false;assert.equal((await request()).code,503);
 global.fetch=async()=>{throw Error('PRIVATE');};assert(!JSON.stringify(await request()).includes('PRIVATE'));
 delete process.env.SUPABASE_SECRET_KEY;assert.equal((await request()).code,503);
 console.log('PASS submitted deals: exact field allowlist, no statuses/PII, fixed agency, hashed header credentials, scoped parameters, pagination, nullable amounts, read-only, rate limits, no caching, sanitized failures');
})().catch(e=>{console.error(e);process.exitCode=1;});
