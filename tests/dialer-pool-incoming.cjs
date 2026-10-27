'use strict';
const assert=require('node:assert/strict');let signed=true,route='+13135550123',seen;
require.cache[require.resolve('../lib/dialer-full')]={exports:{ORIGIN:'https://www.lldportal.com',rpc:async(name,args)=>{assert.equal(name,'dialer_pool_callback_route');seen=args;return{phone:route};}}};
require.cache[require.resolve('../lib/dialer-incoming')]={exports:{signedRequest:async(req,paths)=>{assert.deepEqual(paths,['/api/dialer/pool-incoming']);if(!signed)throw Object.assign(Error('signature'),{status:403});return{b:req.body};}}};
const handler=require('../api/dialer/pool-incoming');const body={AccountSid:'AC'+'a'.repeat(32),To:'+12025550123',From:'+12485550124'};
const run=async()=>{const res={setHeader(){},status(n){this.code=n;return this;},send(d){this.data=d;return this;}};await handler({body},res);return res;};
(async()=>{
 let r=await run();assert.equal(r.code,200);assert.match(r.data,/<Number>\+13135550123<\/Number>/);assert(!r.data.includes('callerId='));assert.equal(seen.p_from,body.From);
 body.From='anonymous';r=await run();assert(r.data.includes('callerId="'+body.To+'"'));
 route=body.To;r=await run();assert.equal(r.code,503);route='+13135550123';signed=false;r=await run();assert.equal(r.code,403);
 console.log('PASS: signed-only shared callbacks, original caller preservation, anonymous fallback and forwarding-loop rejection.');
})().catch(e=>{console.error(e);process.exitCode=1;});
