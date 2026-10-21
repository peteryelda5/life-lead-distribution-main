(()=>{
 'use strict';
 let cache=null,busy=false,panel=null;
 const identity=()=>typeof S==='undefined'?null:(jwtPayload().sub||'')+':'+(jwtPayload().session_id||'');
 const iphone=()=>/iPhone|iPad|iPod/i.test(navigator.userAgent);
 const label=()=>iphone()?'Face ID':'Passkey';
 const available=()=>window.isSecureContext&&!!window.PublicKeyCredential&&!!navigator.credentials&&!!window.SimpleWebAuthnBrowser;
 const verified=()=>!!cache&&cache.owner===identity()&&cache.verified&&Date.parse(cache.expires_at)>Date.now();
 const hasCredential=()=>cache?.owner===identity()&&cache.credentials?.length>0;
 const el=(tag,text,cls)=>{const e=document.createElement(tag);if(text)e.textContent=text;if(cls)e.className=cls;return e;};
 function accept(value,owner){if(owner!==identity())throw Error('Account changed. Please try again.');cache={...value,owner};return value;}
 async function request(action,data={}){
  const owner=identity();if(!S.session?.access_token)throw Error('Sign in first.');
  if(sessionExpiresWithin(90)&&!await refreshToken())throw Error('Sign in again.');
  if(owner!==identity())throw Error('Account changed. Please try again.');
  const controller=new AbortController(),timer=setTimeout(()=>controller.abort(),20000);
  try{
   const r=await fetch('/api/auth/passkeys',{method:'POST',headers:{Authorization:'Bearer '+S.session.access_token,'Content-Type':'application/json'},body:JSON.stringify({action,...data}),signal:controller.signal});
   const result=await r.json();if(owner!==identity())throw Error('Account changed. Please try again.');
   if(!r.ok)throw Error(result.error||'Face ID is unavailable. Use your authenticator code.');
   return {result,owner};
  }finally{clearTimeout(timer);}
 }
 async function check(){
  try{const {result,owner}=await request('status');accept(result,owner);return verified();}
  catch{cache=null;return false;}
 }
 function friendly(e){return ['NotAllowedError','AbortError'].includes(e?.name)||e?.code==='ERROR_CEREMONY_ABORTED'?'Face ID was cancelled. Try again or use your authenticator code.':e.message||'Face ID is unavailable. Use your authenticator code.';}
 async function verify(button){
  if(busy)return;if(!available())return flash('Open the portal in Safari on your iPhone, or use your authenticator code.',true);
  busy=true;if(button)button.disabled=true;
  try{
   const {result:o,owner}=await request('authenticate_options');
   const credential=await SimpleWebAuthnBrowser.startAuthentication({optionsJSON:o.options});
   if(owner!==identity())throw Error('Account changed. Please try again.');
   const {result}=await request('authenticate_verify',{id:o.id,credential});accept(result,owner);
   if(!verified())throw Error('Face ID verification expired. Please try again.');
   S.mfaMode=null;S.mfaEnroll=null;S.err='';await loadCore();render();
  }catch(e){flash(friendly(e),true);}finally{busy=false;if(button)button.disabled=false;}
 }
 async function register(){
  const {result:o,owner}=await request('register_options');
  const credential=await SimpleWebAuthnBrowser.startRegistration({optionsJSON:o.options});
  if(owner!==identity())throw Error('Account changed. Please try again.');
  const {result}=await request('register_verify',{id:o.id,credential,name:iphone()?'My iPhone':'My device'});accept(result,owner);
 }
 function close(){panel?.remove();panel=null;}
 function message(text,error=false){const e=panel?.querySelector('[role=status]');if(e){e.textContent=text;e.className=error?'error':'notice';}}
 async function run(fn,success){
  if(busy)return;busy=true;panel?.querySelectorAll('button').forEach(b=>b.disabled=true);
   try{await fn();if(currentAal()!=='aal2'&&!verified()){close();S.mfaMode='challenge';render();}else{draw();message(success);}}catch(e){message(friendly(e),true);}
  finally{busy=false;panel?.querySelectorAll('button').forEach(b=>b.disabled=false);}
 }
 function button(text,fn,cls='btn secondary'){const b=el('button',text,cls);b.type='button';b.onclick=fn;return b;}
 function draw(){
  close();panel=el('div',null,'pk-overlay');const card=el('section',null,'card stack pk-card');card.setAttribute('role','dialog');card.setAttribute('aria-modal','true');card.setAttribute('aria-label','Face ID and passkeys');
  const top=el('div',null,'row');top.append(el('h2','Face ID & passkeys'),button('Close',close));card.append(top);
  card.append(el('p','Use Face ID in place of the six-digit authenticator code. Your password is still used when you start a new sign-in.'));
  card.append(el('p','Your iPhone handles Face ID privately and may offer its device passcode. Your face is never sent to Vivid Life. Keep your authenticator app as a backup.','muted small'));
  const status=el('div');status.setAttribute('role','status');card.append(status);
  if(!available())card.append(el('div','Open this page in Safari on your iPhone to set up Face ID. You can continue using your authenticator code.','notice'));
  else card.append(button('Set up '+label(),()=>run(register,label()+' is ready. Choose “Use '+label()+'” at your next verification step.'),'btn primary'));
  for(const c of cache?.owner===identity()?cache.credentials||[]:[]){
   const row=el('div',null,'pk-device'),info=el('div');info.append(el('strong',c.name),el('div','Added '+new Date(c.created_at).toLocaleDateString(),'muted small'));
   row.append(info,button('Remove',()=>{if(confirm('Remove this passkey? Use your authenticator code until another passkey is set up.'))run(async()=>{const {result,owner}=await request('remove',{credential:c.id});accept(result,owner);},'Passkey removed.');}));card.append(row);
  }
  panel.append(card);document.body.append(panel);card.querySelector('button')?.focus();panel.onclick=e=>{if(e.target===panel&&!busy)close();};
 }
 async function open(){await check();draw();}
 function challengeHtml(){return available()&&hasCredential()?'<button type="button" id="usePortalPasskey" class="btn primary">Use '+label()+'</button><div class="muted small">Or use your authenticator code below.</div>':'';}
 function bindChallenge(){const b=document.getElementById('usePortalPasskey');if(b)b.onclick=()=>verify(b);}
 function reset(){cache=null;close();}
 document.addEventListener('keydown',e=>{if(e.key==='Escape'&&!busy)close();});
 window.PortalPasskeys={check,verified,open,reset,challengeHtml,bindChallenge,verify};
})();
