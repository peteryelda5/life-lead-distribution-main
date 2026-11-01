/* Presentation only: authentication is handled by the existing login form. */
(()=>{
 'use strict';
 let dispose;
 function mount(){
  dispose?.();
  const root=document.querySelector('.portal-login');
  if(!root)return;
  const video=root.querySelector('.portal-login-video'),motion=root.querySelector('.portal-login-motion'),reveal=root.querySelector('.portal-login-reveal'),password=root.querySelector('#portalLoginPassword');
  const events=new AbortController(),options={signal:events.signal},reduced=window.matchMedia?.('(prefers-reduced-motion: reduce)')||{matches:true,addEventListener(){}};
  let stopped=false,wantsMotion=false,pausedByUser=false;
  try{pausedByUser=sessionStorage.getItem('vivid-login-motion-paused')==='1';}catch{}
  const update=()=>{const paused=video.paused;motion.textContent=paused?'Play motion':'Pause motion';motion.setAttribute('aria-label',paused?'Play background video':'Pause background video');};
  async function play(){
   if(stopped||!root.isConnected||document.hidden)return;
   video.muted=true;
   if(!video.getAttribute('src'))video.src=video.dataset.src;
   try{await video.play();if(stopped)video.pause();}catch{wantsMotion=false;}
   update();
  }
  motion.hidden=false;
  motion.addEventListener('click',()=>{
   wantsMotion=video.paused;pausedByUser=!wantsMotion;
   try{sessionStorage.setItem('vivid-login-motion-paused',pausedByUser?'1':'0');}catch{}
   if(wantsMotion)play();else video.pause();update();
  },options);
  video.addEventListener('playing',()=>{video.style.opacity='1';update();},options);
  video.addEventListener('pause',update,options);
  video.addEventListener('error',()=>{video.style.opacity='0';wantsMotion=false;update();},options);
  document.addEventListener('visibilitychange',()=>{if(document.hidden)video.pause();else if(wantsMotion)play();},options);
  reduced.addEventListener('change',()=>{wantsMotion=!reduced.matches&&!navigator.connection?.saveData&&!pausedByUser;if(wantsMotion)play();else video.pause();update();},options);
  reveal.addEventListener('click',()=>{const show=password.type==='password';password.type=show?'text':'password';reveal.setAttribute('aria-label',show?'Hide password':'Show password');reveal.setAttribute('aria-pressed',String(show));},options);
  const observer=new MutationObserver(()=>{if(!root.isConnected)cleanup();});
  observer.observe(root.parentNode,{childList:true});
  function cleanup(){if(stopped)return;stopped=true;observer.disconnect();events.abort();video.pause();video.removeAttribute('src');video.load();}
  dispose=cleanup;
  wantsMotion=!reduced.matches&&!navigator.connection?.saveData&&!pausedByUser;
  if(wantsMotion)play();else update();
 }
 window.PortalLogin={mount};
})();
