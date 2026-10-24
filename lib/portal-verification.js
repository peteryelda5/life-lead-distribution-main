'use strict';
// Auth APIs validate the JWT first. AAL1 requires a server-held, session-bound
// WebAuthn proof; browser flags and user metadata never grant access.
async function requireVerification(authorization,claims){
 if(claims.aal==='aal2')return;
 const r=await fetch('https://yfuuigykpihoetgaefmu.supabase.co/rest/v1/rpc/require_portal_mfa',{
  method:'POST',headers:{apikey:'sb_publishable_6O3XhhYJrjhN_5U1cFxz2g_fYI-3uE6',Authorization:authorization,'Content-Type':'application/json'},body:'{}',signal:AbortSignal.timeout(8000)});
 if(!r.ok||await r.json()!==true)throw Object.assign(new Error('Verify with Face ID or your authenticator code.'),{status:403});
}
async function requirePortalOnboarding(authorization){
 const r=await fetch('https://yfuuigykpihoetgaefmu.supabase.co/rest/v1/rpc/require_portal_onboarding',{
  method:'POST',headers:{apikey:'sb_publishable_6O3XhhYJrjhN_5U1cFxz2g_fYI-3uE6',Authorization:authorization,'Content-Type':'application/json'},body:'{}',signal:AbortSignal.timeout(8000)});
 const result=await r.json();
 if(r.ok&&result===true)return;
 if(r.status===403&&result?.details==='ONBOARDING_REQUIRED')throw Object.assign(new Error('Complete onboarding and the signed NDA and chargeback agreement before opening the portal.'),{status:403,code:'ONBOARDING_REQUIRED'});
 throw Object.assign(new Error('Could not verify onboarding. Please try again.'),{status:503});
}
module.exports={requireVerification,requirePortalOnboarding};
