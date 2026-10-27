'use strict';
const assert=require('node:assert/strict');
const root='AC'+'a'.repeat(32),sub='AC'+'b'.repeat(32),call='CA'+'c'.repeat(32);
Object.assign(process.env,{TWILIO_ACCOUNT_SID:root,TWILIO_AUTH_TOKEN:'fixture-root',TWILIO_API_KEY_SID:'SK'+'a'.repeat(32),TWILIO_API_KEY_SECRET:'fixture',TWILIO_TWIML_APP_SID:'AP'+'a'.repeat(32),TWILIO_PHONE_NUMBER:'+12025550123',TWILIO_TEST_PHONE_NUMBER:'+12025550124'});
let requests=[];global.fetch=async(url,opt)=>{requests.push({url,opt});return new Response(JSON.stringify({account_sid:sub,call_sid:call}),{status:200});};
const provider=require('../lib/dialer-at-cost-provider');
(async()=>{
 await provider.pinned(sub,'Calls/'+call+'.json');assert.equal(requests[0].url,'https://api.twilio.com/2010-04-01/Accounts/'+sub+'/Calls/'+call+'.json');assert.equal(requests[0].opt.headers.Authorization,'Basic '+Buffer.from(root+':fixture-root').toString('base64'));
 await provider.pinned(sub,'Calls/'+call+'/Transcriptions/GT'+'d'.repeat(32)+'.json',{Status:'stopped'});assert.equal(requests[1].opt.method,'POST');
 for(const path of ['IncomingPhoneNumbers.json','../Accounts.json','Calls/'+call+'.json?To=other'])await assert.rejects(provider.pinned(sub,path),/Invalid pinned/);
 await assert.rejects(provider.pinned('malformed','Calls/'+call+'.json'),/Invalid pinned/);assert.equal(requests.length,2);
 console.log('PASS: pinned account routing, root authorization, transcription stop and rejection of unrelated provider operations.');
})().catch(e=>{console.error(e);process.exitCode=1;});
