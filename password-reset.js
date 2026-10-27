'use strict';
(async()=>{
 const q=s=>document.querySelector(s),status=q('#status'),client=window.supabase.createClient('https://yfuuigykpihoetgaefmu.supabase.co','sb_publishable_6O3XhhYJrjhN_5U1cFxz2g_fYI-3uE6',{auth:{persistSession:false,autoRefreshToken:true,detectSessionInUrl:false}});
 let ready=false,factor=null;
 const showPassword=()=>{ready=true;q('#verify').hidden=true;q('#change').hidden=false;status.textContent='Choose a password with at least 12 characters.';};
 async function submit(form,action){form.addEventListener('submit',async e=>{e.preventDefault();const b=form.querySelector('button');if(b.disabled)return;b.disabled=true;status.textContent='';try{await action(new FormData(form));}catch(e){status.textContent=e.message||'Please try again.';}finally{b.disabled=false;}});}
 submit(q('#request'),async f=>{const {error}=await client.auth.resetPasswordForEmail(String(f.get('email')).trim(),{redirectTo:'https://www.lldportal.com/'});if(error)throw new Error(error.status===429?'Please wait before requesting another link.':'Could not send the reset email. Try again shortly or ask the portal owner to reset your password.');status.textContent='If an account exists for that email, you’ll receive a reset link. Check your spam folder too.';});
 submit(q('#verify'),async f=>{const {error}=await client.auth.mfa.challengeAndVerify({factorId:factor,code:String(f.get('code')).trim()});if(error)throw new Error('Could not verify that code. Try the current code from your authenticator.');q('#verify').reset();showPassword();});
 submit(q('#change'),async f=>{if(!ready)throw new Error('Open a fresh password reset link.');if(f.get('password')!==f.get('confirm'))throw new Error('Passwords do not match.');const {error}=await client.auth.updateUser({password:String(f.get('password'))});if(error)throw new Error(error.message||'Could not update your password. Request a new reset link.');ready=false;q('#change').reset();q('#change').hidden=true;await client.auth.signOut().catch(()=>{});localStorage.removeItem('lld_session');q('#heading').textContent='Password updated';q('#intro').textContent='Sign in with your new password. Your existing verification and onboarding requirements still apply.';status.textContent='Your new password is saved.';});
 const hash=new URLSearchParams((window.recoveryFragment||'').replace(/^#/,''));delete window.recoveryFragment;
 if(hash.has('error')||hash.has('error_code')){status.textContent='This reset link has expired or is invalid. Request a new one below.';return;}
 if(hash.get('type')!=='recovery')return;
 q('#request').hidden=true;q('#heading').textContent='Reset your password';q('#intro').textContent='Verifying your reset link…';
 try{
  if(!hash.get('access_token')||!hash.get('refresh_token'))throw Error('Invalid link');
  const {error}=await client.auth.setSession({access_token:hash.get('access_token'),refresh_token:hash.get('refresh_token')});hash.delete('access_token');hash.delete('refresh_token');if(error)throw error;
  const {data,error:factorError}=await client.auth.mfa.listFactors();if(factorError)throw factorError;
  const verified=(data?.totp||[]).find(f=>f.status==='verified');
  q('#intro').textContent=verified?'Enter your authenticator code to protect your account. If you cannot access it, contact your agency admin.':'Enter your new password below.';
  if(verified){factor=verified.id;q('#verify').hidden=false;}else showPassword();
 }catch{q('#request').hidden=false;q('#intro').textContent='Request a fresh reset link to continue.';status.textContent='This reset link could not be verified.';}
})();
