/* Code-entry presentation only. The portal's MFA provider decides whether a code is valid. */
(()=>{
 'use strict';let dispose;
 function bind(form,{verify,retry,isCurrent=()=>true}){
  dispose?.();
  const card=form.closest('.pv-card'),inputs=[...form.querySelectorAll('[data-code-digit]')],button=form.querySelector('[type=submit]'),status=form.querySelector('.pv-status'),retryButton=form.querySelector('.pv-retry'),success=form.querySelector('.pv-success'),entry=form.querySelector('.pv-entry'),passkey=card.querySelector('#usePortalPasskey');
  const events=new AbortController(),options={signal:events.signal};let busy=false,verified=false,stopped=false,timer,finishAnimation;
  const current=()=>!stopped&&form.isConnected&&isCurrent();
  const reduced=()=>window.matchMedia?.('(prefers-reduced-motion: reduce)').matches===true;
  const paint=()=>inputs.forEach(input=>input.classList.toggle('pv-filled',!!input.value));
  const lock=value=>{busy=value;inputs.forEach(input=>input.disabled=value);button.disabled=value;retryButton.disabled=value;if(passkey)passkey.disabled=value;form.setAttribute('aria-busy',String(value));};
  function resetError(){form.dataset.state='idle';status.textContent='';inputs.forEach(input=>input.removeAttribute('aria-invalid'));}
  function focus(index){inputs[Math.max(0,Math.min(5,index))].focus();inputs[Math.max(0,Math.min(5,index))].select();}
  function put(value,index){
   if(busy||verified)return;
   const digits=String(value).replace(/\D/g,'').slice(0,6);resetError();
   if(digits.length===6){inputs.forEach((input,i)=>input.value=digits[i]);index=0;}
   else{inputs[index].value=digits[0]||'';for(let i=1;i<digits.length&&index+i<6;i++)inputs[index+i].value=digits[i];}
   paint();if(digits.length)focus(Math.min(5,index+digits.length));
   if(inputs.every(input=>/^\d$/.test(input.value)))void submit();
  }
  async function showSuccess(){
   if(!current())throw Error('Your verification screen changed. Please continue signing in.');
   verified=true;inputs.forEach(input=>input.value='');paint();entry.hidden=true;success.hidden=false;form.dataset.state='success';status.textContent='Verified successfully. Opening your workspace…';
   card.querySelector('.pv-title').textContent='Verified successfully';card.querySelector('.pv-subtitle').textContent='Your account is verified.';
   if(passkey)passkey.hidden=true;
   if(!reduced())await new Promise(resolve=>{finishAnimation=resolve;timer=setTimeout(resolve,800);});
  }
  async function submit(){
   if(busy||verified||!current())return;const code=inputs.map(input=>input.value).join('');
   if(!/^\d{6}$/.test(code)){status.textContent='Enter all six digits from your authenticator app.';focus(Math.max(0,inputs.findIndex(input=>!input.value)));return;}
   resetError();lock(true);form.dataset.state='checking';button.textContent='Verifying…';status.textContent='Checking your code…';
   try{await verify(code,showSuccess);}
   catch(error){if(!current())return;
    if(verified){form.dataset.state='load-error';status.textContent='Your code was verified, but your workspace could not load. Try opening it again.';retryButton.hidden=false;retryButton.disabled=false;form.setAttribute('aria-busy','false');}
    else{lock(false);form.dataset.state='error';button.textContent='Verify code';status.textContent=error?.message||'We could not verify that code. Enter the current code and try again.';inputs.forEach(input=>{input.value='';input.setAttribute('aria-invalid','true');});paint();focus(0);}
   }
  }
  for(const [index,input] of inputs.entries()){
   input.addEventListener('focus',()=>input.select(),options);
   input.addEventListener('input',event=>{if(!event.isComposing)put(input.value,index);},options);
   input.addEventListener('compositionend',()=>put(input.value,index),options);
   input.addEventListener('paste',event=>{event.preventDefault();put(event.clipboardData?.getData('text')||'',index);},options);
   input.addEventListener('keydown',event=>{
    if(busy)return;
    if(event.key==='Backspace'&&!input.value&&index>0){event.preventDefault();resetError();inputs[index-1].value='';paint();focus(index-1);}
    if(['ArrowLeft','ArrowRight','Home','End'].includes(event.key)){event.preventDefault();focus(event.key==='Home'?0:event.key==='End'?5:index+(event.key==='ArrowLeft'?-1:1));}
   },options);
  }
  form.addEventListener('submit',event=>{event.preventDefault();void submit();},options);
  retryButton.addEventListener('click',async()=>{if(!current()||retryButton.disabled)return;retryButton.disabled=true;form.setAttribute('aria-busy','true');status.textContent='Opening your workspace…';try{await retry();}catch{if(current()){retryButton.disabled=false;form.setAttribute('aria-busy','false');status.textContent='Your workspace still could not load. Please try again.';}}},options);
  if(passkey){const original=passkey.onclick;passkey.onclick=async event=>{if(busy||verified||!current())return;lock(true);try{await original?.call(passkey,event);}finally{if(current()){lock(false);paint();}}};}
  const observer=new MutationObserver(()=>{if(!form.isConnected)cleanup();});observer.observe(document.getElementById('app'),{childList:true});
  function cleanup(){if(stopped)return;stopped=true;events.abort();observer.disconnect();clearTimeout(timer);finishAnimation?.();inputs.forEach(input=>input.value='');}
  dispose=cleanup;paint();if(form.id==='mfaChallengeForm')focus(0);
 }
 window.PortalVerification={bind};
})();
