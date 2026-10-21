'use strict';
const {randomBytes}=require('node:crypto');
const webauthn=require('@simplewebauthn/server');
const {requireVerification}=require('./portal-verification');
const BASE='https://yfuuigykpihoetgaefmu.supabase.co',KEY='sb_publishable_6O3XhhYJrjhN_5U1cFxz2g_fYI-3uE6';
const ORIGIN='https://www.lldportal.com',RP='lldportal.com';
const UUID=/^[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}$/i;
const fail=(status,message)=>Object.assign(new Error(message),{status});
async function authenticate(req){
 const auth=req.headers.authorization||'';
 if(!/^Bearer [A-Za-z0-9_.-]+$/.test(auth))throw fail(401,'Sign in to the portal first.');
 const r=await fetch(BASE+'/auth/v1/user',{headers:{apikey:KEY,Authorization:auth},signal:AbortSignal.timeout(8000)});
 if(!r.ok)throw fail(401,'Your session expired. Sign in again.');
 const user=await r.json();let claims;
 try{claims=JSON.parse(Buffer.from(auth.slice(7).split('.')[1],'base64url'));}catch{throw fail(401,'Invalid session.');}
 if(claims.sub!==user.id||!UUID.test(user.id||'')||!UUID.test(claims.session_id||'')||!Number.isFinite(claims.exp)||claims.exp<=Date.now()/1000||!['aal1','aal2'].includes(claims.aal))throw fail(401,'Invalid session.');
 return {user,claims,auth};
}
async function manage(u,action,data={}){
 const key=process.env.SUPABASE_SECRET_KEY;
 if(!/^sb_secret_[A-Za-z0-9_-]+$/.test(key||''))throw fail(503,'Face ID setup is temporarily unavailable.');
 const r=await fetch(BASE+'/rest/v1/rpc/portal_passkey_manage',{method:'POST',headers:{apikey:key,'Content-Type':'application/json'},
  body:JSON.stringify({p_user:u.user.id,p_session:u.claims.session_id,p_aal:u.claims.aal,p_action:action,p_data:data}),signal:AbortSignal.timeout(12000)});
 const d=await r.json();if(!r.ok){const safe=/^(Sign in again|Verify your authenticator|Too many Face ID|Remove an old passkey|Face ID request expired|This passkey does not belong|Passkey changed)/.test(d?.message||'');throw fail(d?.code==='42501'?403:409,safe?d.message:'Face ID could not be updated. Please try again.');}return d;
}
async function action(req){
 const u=await authenticate(req),b=req.body;
 if(!b||typeof b!=='object'||Array.isArray(b)||!['status','register_options','register_verify','authenticate_options','authenticate_verify','remove'].includes(b.action))throw fail(400,'Invalid Face ID request.');
 if(b.action==='status')return manage(u,'status');
 if(b.action.startsWith('register_')||b.action==='remove')await requireVerification(u.auth,u.claims);
 if(b.action==='remove'){
  if(typeof b.credential!=='string'||b.credential.length>2048)throw fail(400,'Select a passkey.');
  await manage(u,'remove',{credential:b.credential});return manage(u,'status');
 }
 if(b.action.endsWith('_options')){
  const challenge=randomBytes(32).toString('base64url'),record=await manage(u,b.action,{challenge});
  const registering=b.action==='register_options';
  if(!registering&&!record.credentials.length)throw fail(409,'Set up Face ID after signing in with your authenticator code.');
  const options=registering?await webauthn.generateRegistrationOptions({rpName:'Vivid Life Portal',rpID:RP,userName:u.user.email||'Portal account',userID:Buffer.from(u.user.id),challenge,
   attestationType:'none',excludeCredentials:record.credentials,authenticatorSelection:{residentKey:'required',userVerification:'required',authenticatorAttachment:'platform'},supportedAlgorithmIDs:[-7,-257],timeout:60000}):
   await webauthn.generateAuthenticationOptions({rpID:RP,challenge,allowCredentials:record.credentials,userVerification:'required',timeout:60000});
  return {id:record.id,options};
 }
 if(!UUID.test(b.id||'')||!b.credential||typeof b.credential!=='object'||typeof b.credential.id!=='string'||b.credential.id.length>2048||JSON.stringify(b.credential).length>64000)throw fail(400,'Invalid passkey response.');
 const registering=b.action==='register_verify',saved=await manage(u,'take',{id:b.id,kind:registering?'register':'authenticate',credential:b.credential.id});
 let result;
 try{
  result=registering?await webauthn.verifyRegistrationResponse({response:b.credential,expectedChallenge:saved.challenge,expectedOrigin:ORIGIN,expectedRPID:RP,requireUserVerification:true}):
   await webauthn.verifyAuthenticationResponse({response:b.credential,expectedChallenge:saved.challenge,expectedOrigin:ORIGIN,expectedRPID:RP,requireUserVerification:true,
    credential:{id:saved.credential.id,publicKey:Buffer.from(saved.credential.public_key,'base64url'),counter:saved.credential.counter,transports:saved.credential.transports}});
 }catch{throw fail(403,'Face ID could not verify this request. Try again or use your authenticator code.');}
 if(!result.verified)throw fail(403,'Face ID verification failed.');
 if(registering){
  const info=result.registrationInfo,c=info.credential;
  await manage(u,'register_finish',{id:b.id,credential:c.id,public_key:Buffer.from(c.publicKey).toString('base64url'),counter:c.counter,transports:c.transports||[],name:typeof b.name==='string'?b.name.trim().slice(0,80):'My device'});
 }else await manage(u,'authenticate_finish',{id:b.id,credential:saved.credential.id,counter:result.authenticationInfo.newCounter,previous_counter:saved.credential.counter});
 return manage(u,'status');
}
async function handler(req,res){
 res.setHeader('Cache-Control','no-store');
 if(req.method!=='POST')return res.status(405).json({error:'Use POST.'});
 if(req.headers.origin!==ORIGIN)return res.status(403).json({error:'Open Face ID from the portal.'});
 if(process.env.VERCEL_ENV&&process.env.VERCEL_ENV!=='production')return res.status(503).json({error:'Face ID is available on lldportal.com.'});
 try{return res.status(200).json(await action(req));}
 catch(e){if(!e.status)console.error('portal_passkey_request_failed');return res.status(e.status||503).json({error:e.status?e.message:'Face ID is temporarily unavailable. Use your authenticator code.'});}
}
module.exports={handler,action,authenticate,manage};
