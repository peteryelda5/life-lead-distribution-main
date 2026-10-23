'use strict';
const fs=require('node:fs'),vm=require('node:vm'),assert=require('node:assert/strict');
const source=fs.readFileSync('portal-app.js','utf8');
const names=['portalConnectionError','raw','rawPage','isAuthError','api','apiPage'];
const code=source.split('\n').filter(line=>names.some(name=>line.startsWith('function '+name+'(')||line.startsWith('async function '+name+'('))).join('\n');
(async()=>{
 let calls=0,refreshes=0,failure=Object.assign(new Error('aborted'),{name:'AbortError'});
 const session={access_token:'test-token'};
 const c={BASE:'https://example.test',KEY:'test-key',S:{session},portalSessionEpoch:0,navigator:{onLine:true},window:{},sessionExpiresWithin:()=>false,
  refreshToken:async()=>{refreshes++;return true;},portalFetch:async()=>{calls++;if(failure)throw failure;return {ok:true,text:async()=> '[]',headers:{get:()=> '0-0/0'}};}};
 vm.createContext(c);vm.runInContext(code,c);
 await assert.rejects(c.api('/rest/v1/leads',{method:'POST',body:{test:true}}),e=>e.code==='PORTAL_TIMEOUT'&&/check whether it saved/.test(e.message));
 assert.equal(calls,1,'a timed-out write is never automatically replayed');assert.equal(refreshes,0);assert.equal(c.S.session,session);
 await assert.rejects(c.apiPage('/rest/v1/leads'),e=>e.code==='PORTAL_TIMEOUT');assert.equal(refreshes,0);
 failure=new TypeError('Failed to fetch');await assert.rejects(c.raw('/rest/v1/leads'),e=>e.code==='PORTAL_UNREACHABLE'&&!/Check your connection/.test(e.message));
 c.navigator.onLine=false;await assert.rejects(c.rawPage('/rest/v1/leads'),e=>e.code==='PORTAL_OFFLINE'&&/Reconnect/.test(e.message));
 c.navigator.onLine=true;failure=null;assert.equal((await c.apiPage('/rest/v1/leads')).count,0);
 assert.equal(c.isAuthError({status:401}),true);assert.equal(c.isAuthError({code:'PORTAL_TIMEOUT',message:'Request took too long'}),false);
 console.log('PASS: timeout, offline and reachability errors remain distinct; timed-out writes are not replayed and sessions survive.');
})().catch(e=>{console.error(e);process.exitCode=1;});
