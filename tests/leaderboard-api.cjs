'use strict';
const assert=require('node:assert/strict'),{createHash}=require('node:crypto');
const handler=require('../api/leaderboard');
const token='vllb_'+'a'.repeat(43),headers={authorization:'Bearer '+token};
const secret='sb_secret_test_backend_only';
process.env.SUPABASE_SECRET_KEY=secret;
let calls=[],upstream;
global.fetch=async(url,options)=>{calls.push({url,options});return upstream;};
const row={agent_name:'Sample Agent',annual_premium:1320,recorded_annual_premium:1200,imported_annual_premium_adjustment:120,deals:2,email:'PRIVATE',phone:'PRIVATE',notes:'PRIVATE',agent_id:'PRIVATE'};
const fixture={status:200,data:{scope:'Vivid Life',as_of:'2026-10-28T12:00:00Z',period:{key:'month',start:'2026-10-01',end_exclusive:'2026-11-01',secret:'PRIVATE'},totals:{annual_premium:1320,deals:2,secret:'PRIVATE'},rankings:[row],clients:[{ssn:'PRIVATE'}],credentials:'PRIVATE'}};
function good(value=fixture){upstream={ok:true,json:async()=>value};}
async function request(overrides={}){
 const res={headers:{},setHeader(k,v){this.headers[k]=v;},status(s){this.code=s;return this;},json(body){this.body=body;return this;}};
 await handler({method:'GET',url:'/api/leaderboard',headers,...overrides},res);return res;
}
(async()=>{
 good();
 for(const method of ['POST','PUT','PATCH','DELETE','HEAD','OPTIONS'])assert.equal((await request({method})).code,405);
 for(const authorization of [undefined,'','Bearer '+secret,'Bearer eyJ.fake.jwt','Bearer '+token+'extra',['Bearer '+token]])assert.equal((await request({headers:{authorization}})).code,401);
 for(const url of ['/api/leaderboard?key='+token,'/api/leaderboard?division=legacy_life','/api/leaderboard?select=*','/api/leaderboard?table=profiles','/api/leaderboard?period=month&period=today','/api/leaderboard?period=all','/api/leaderboard?period=previous','/api/leaderboard?month=2026-09-01','/api/leaderboard?period=previous&month=2026-13-01','/api/leaderboard?period=previous&month=2026-09-02'])assert.equal((await request({url})).code,400,url);
 assert.equal(calls.length,0,'Reject invalid requests before any database read');
 let response=await request();assert.equal(response.code,200);assert.equal(response.body.scope,'Vivid Life');assert.equal(response.body.rankings[0].position,1);assert.equal(response.body.rankings[0].average_annual_premium,660);
 assert(!JSON.stringify(response).includes('PRIVATE'),'No extra upstream fields may escape');
 assert.match(response.headers['Cache-Control'],/no-store/);assert.equal(response.headers['Vercel-CDN-Cache-Control'],'no-store');assert.equal(response.headers.Vary,'Authorization');
 assert.equal(calls[0].url,'https://yfuuigykpihoetgaefmu.supabase.co/rest/v1/rpc/leaderboard_api_read');
 assert.equal(calls[0].options.headers.apikey,secret);assert.equal(calls[0].options.headers.Authorization,undefined);
 assert.deepEqual(JSON.parse(calls[0].options.body),{p_key_hash:createHash('sha256').update(token).digest('hex'),p_period:'month',p_month:null});assert(!calls[0].options.body.includes(token));
 for(const period of ['today','week','month']){assert.equal((await request({url:'/api/leaderboard?period='+period})).code,200);assert.equal(JSON.parse(calls.at(-1).options.body).p_period,period);}
 assert.equal((await request({url:'/api/leaderboard?period=previous&month=2026-09-01'})).code,200);assert.equal(JSON.parse(calls.at(-1).options.body).p_month,'2026-09-01');
 for(const status of [401,400,429]){good({status,secret:'PRIVATE'});response=await request();assert.equal(response.code,status);assert(!JSON.stringify(response).includes('PRIVATE'));if(status===429)assert.equal(response.headers['Retry-After'],'60');}
 good({...fixture,data:{...fixture.data,rankings:[{...row,deals:null},{...row,deals:0}]}});response=await request();assert.deepEqual(response.body.rankings.map(r=>r.average_annual_premium),[null,0]);
 for(const invalid of [null,{status:200,data:null},{status:200,data:{...fixture.data,rankings:[{...row,annual_premium:'PRIVATE'}]}},{status:200,data:{...fixture.data,rankings:[{...row,deals:-1}]}},{status:500,error:secret}]){good(invalid);response=await request();assert.equal(response.code,503);assert.deepEqual(response.body,{error:'Leaderboard temporarily unavailable.'});}
 upstream={ok:false,json:async()=>({error:'SQL '+secret})};assert.equal((await request()).code,503);
 global.fetch=async()=>{throw Error(secret);};response=await request();assert.equal(response.code,503);assert(!JSON.stringify(response).includes(secret));
 delete process.env.SUPABASE_SECRET_KEY;assert.equal((await request()).code,503);
 console.log('PASS: leaderboard-only response allowlist, header-only hashed keys, read-only methods, input restrictions, null historical counts, rate-limit mapping, cache protection, and sanitized failures.');
})().catch(e=>{console.error(e);process.exitCode=1;});
