'use strict';
const assert=require('node:assert/strict');const {requireVerification}=require('../lib/portal-verification');
(async()=>{
 let called=0,allowed=false,status=403;
 global.fetch=async(url,opt)=>{called++;assert(url.endsWith('/rest/v1/rpc/require_portal_mfa'));assert.equal(opt.headers.Authorization,'Bearer signed-user-token');assert.equal(opt.body,'{}');return {ok:status===200,json:async()=>allowed};};
 await requireVerification('Bearer signed-user-token',{aal:'aal2'});assert.equal(called,0);
 await assert.rejects(requireVerification('Bearer signed-user-token',{aal:'aal1'}),{status:403});
 status=200;await assert.rejects(requireVerification('Bearer signed-user-token',{aal:'aal1'}),{status:403});
 allowed=true;await requireVerification('Bearer signed-user-token',{aal:'aal1'});
 status=503;await assert.rejects(requireVerification('Bearer signed-user-token',{aal:'aal1'}),{status:403});
 console.log('PASS: existing TOTP and server-confirmed passkey proof accepted; password-only, false proof and unavailable verifier fail closed.');
})().catch(e=>{console.error(e);process.exitCode=1;});
