'use strict';
const assert=require('node:assert/strict'),crypto=require('node:crypto');
const {isoCBOR}=require('@simplewebauthn/server/helpers');
process.env.SUPABASE_SECRET_KEY='sb_secret_fixture';process.env.VERCEL_ENV='production';
const api=require('../lib/portal-passkeys');
const user='11111111-1111-4111-8111-111111111111',session='22222222-2222-4222-8222-222222222222',challengeId='33333333-3333-4333-8333-333333333333';
const {privateKey,publicKey}=crypto.generateKeyPairSync('ec',{namedCurve:'prime256v1'}),jwk=publicKey.export({format:'jwk'});
const cose=Buffer.from(isoCBOR.encode(new Map([[1,2],[3,-7],[-1,1],[-2,Buffer.from(jwk.x,'base64url')],[-3,Buffer.from(jwk.y,'base64url')]])));
const rawId=crypto.randomBytes(32),id=rawId.toString('base64url');
let stored=null,challenge=null,used=false,proof=false,finishes=0,calls=[];
const json=(d,status=200)=>({ok:status>=200&&status<300,status,json:async()=>d});
global.fetch=async(url,opt)=>{
 if(url.endsWith('/auth/v1/user'))return json({id:user,email:'fixture@example.invalid'});
 if(url.endsWith('/require_portal_mfa'))return json(proof,proof?200:403);
 assert(url.endsWith('/portal_passkey_manage'));const b=JSON.parse(opt.body);calls.push(b);assert.equal(b.p_user,user);assert.equal(b.p_session,session);
 const status=()=>json({verified:b.p_aal==='aal2'||proof,expires_at:proof?new Date(Date.now()+3600000).toISOString():null,credentials:stored?[{id,name:'Fixture'}]:[]});
 if(b.p_action==='status')return status();
 if(b.p_action.endsWith('_options')){challenge=b.p_data.challenge;used=false;return json({id:challengeId,credentials:stored?[{id,transports:['internal']}]:[]});}
 if(b.p_action==='take'){if(used)return json({code:'42501',message:'Face ID request expired. Try again'},403);used=true;if(b.p_data.kind==='authenticate'&&b.p_data.credential!==id)return json({code:'42501',message:'This passkey does not belong to your account'},403);return json({challenge,credential:stored});}
 if(b.p_action==='register_finish'){stored={id,public_key:b.p_data.public_key,counter:b.p_data.counter,transports:b.p_data.transports};assert.equal(stored.public_key,cose.toString('base64url'));finishes++;return json({ok:true});}
 if(b.p_action==='authenticate_finish'){assert.equal(b.p_data.previous_counter,stored.counter);stored.counter=b.p_data.counter;proof=true;finishes++;return json({ok:true});}
 if(b.p_action==='remove'){stored=null;proof=false;return json({ok:true});}
 throw Error('Unexpected persistence action');
};
const token=aal=>'e30.'+Buffer.from(JSON.stringify({sub:user,session_id:session,aal,exp:Date.now()/1000+3600})).toString('base64url')+'.fixture';
const request=(body,aal='aal1')=>({method:'POST',headers:{origin:'https://www.lldportal.com',authorization:'Bearer '+token(aal)},body});
async function run(req){const res={setHeader(){},status(s){this.code=s;return this;},json(b){this.body=b;return this;}};await api.handler(req,res);return res;}
function response(register=false,{origin='https://www.lldportal.com',uv=true,badSignature=false,badChallenge=false}={}){
 const client=Buffer.from(JSON.stringify({type:register?'webauthn.create':'webauthn.get',origin,challenge:badChallenge?'bad':challenge,crossOrigin:false}));
 const count=Buffer.alloc(4);count.writeUInt32BE(register?0:(stored.counter+1));
 const auth=Buffer.concat([crypto.createHash('sha256').update('lldportal.com').digest(),Buffer.from([(uv?5:1)|(register?64:0)]),count]);
 const common={id,rawId:id,type:'public-key',clientExtensionResults:{},authenticatorAttachment:'platform'};
 if(register){const len=Buffer.alloc(2);len.writeUInt16BE(rawId.length);return {...common,response:{clientDataJSON:client.toString('base64url'),attestationObject:Buffer.from(isoCBOR.encode(new Map([['fmt','none'],['attStmt',new Map()],['authData',Buffer.concat([auth,Buffer.alloc(16),len,rawId,cose])]]))).toString('base64url'),transports:['internal']}};}
 const signed=crypto.sign('sha256',Buffer.concat([auth,crypto.createHash('sha256').update(client).digest()]),privateKey);if(badSignature)signed[signed.length-1]^=1;
 return {...common,response:{clientDataJSON:client.toString('base64url'),authenticatorData:auth.toString('base64url'),signature:signed.toString('base64url'),userHandle:Buffer.from(user).toString('base64url')}};
}
(async()=>{
 assert.equal((await run({...request({action:'status'}),method:'GET'})).code,405);
 assert.equal((await run({...request({action:'status'}),headers:{origin:'https://evil.test'}})).code,403);
 assert.equal((await run({...request({action:'status'}),headers:{origin:'https://www.lldportal.com'}})).code,401);
 assert.equal((await run(request({action:'register_options'}))).code,403);
 let r=await run(request({action:'register_options',userId:'other'},'aal2'));assert.equal(r.code,200);assert.equal(r.body.options.rp.id,'lldportal.com');assert.equal(r.body.options.authenticatorSelection.userVerification,'required');
 r=await run(request({action:'register_verify',id:challengeId,credential:response(true),name:'Fixture'},'aal2'));assert.equal(r.code,200);assert.equal(finishes,1);
 await run(request({action:'authenticate_options'}));const valid=response();r=await run(request({action:'authenticate_verify',id:challengeId,credential:valid}));assert.equal(r.code,200);assert.equal(r.body.verified,true);assert.equal(finishes,2);
 r=await run(request({action:'authenticate_verify',id:challengeId,credential:valid}));assert.equal(r.code,403);assert.equal(finishes,2);
 for(const tweak of [{origin:'https://evil.test'},{uv:false},{badSignature:true},{badChallenge:true}]){
  proof=false;await run(request({action:'authenticate_options'}));r=await run(request({action:'authenticate_verify',id:challengeId,credential:response(false,tweak)}));assert.equal(r.code,403);assert.equal(proof,false);assert.equal(finishes,2);
 }
 await run(request({action:'authenticate_options'}));r=await run(request({action:'authenticate_verify',id:challengeId,credential:{...response(),id:'different_credential_id'}}));assert.equal(r.code,403);
 process.env.VERCEL_ENV='preview';assert.equal((await run(request({action:'status'}))).code,503);process.env.VERCEL_ENV='production';
 r=await run(request({action:'remove',credential:id},'aal2'));assert.equal(r.code,200);assert.equal(r.body.credentials.length,0);
 console.log('PASS: real ES256 registration/assertion, required device verification, RP/origin/challenge checks, rejected tampering/replay/foreign credential, explicit verified enrollment, account binding, removal, and preview isolation. No real accounts modified.');
})().catch(e=>{console.error(e);process.exitCode=1;});
