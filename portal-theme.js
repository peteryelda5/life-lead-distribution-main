/* Appearance only: no account, session, or database access. */
(()=>{
 'use strict';
 const key='vivid-portal-theme',root=document.documentElement;
 const valid=value=>value==='dark'||value==='light';
 let theme='light';
 try{const saved=localStorage.getItem(key);if(valid(saved))theme=saved;}catch{}
 function apply(value){
  theme=valid(value)?value:'light';root.dataset.theme=theme;
  document.querySelector('meta[name="theme-color"]')?.setAttribute('content',theme==='dark'?'#0b1423':'#0b2848');
  document.querySelectorAll('[data-portal-theme-choice]').forEach(button=>button.setAttribute('aria-pressed',String(button.dataset.portalThemeChoice===theme)));
 }
 apply(theme);
 function mount(){
  document.querySelectorAll('.portal-account-menu').forEach(menu=>{
   if(menu.querySelector('[data-portal-theme-control]'))return;
   const control=document.createElement('div');control.className='portal-theme-control';control.dataset.portalThemeControl='';
   control.setAttribute('role','group');control.setAttribute('aria-label','Appearance');
   const label=document.createElement('span');label.textContent='Appearance';control.append(label);
   const options=document.createElement('div');options.className='portal-theme-options';
   for(const [value,text] of [['light','Light'],['dark','Dark']]){
    const button=document.createElement('button');button.type='button';button.dataset.portalThemeChoice=value;
    button.textContent=text;button.setAttribute('aria-pressed',String(value===theme));
    button.addEventListener('click',event=>{event.stopPropagation();apply(value);try{localStorage.setItem(key,value);}catch{}});
    options.append(button);
   }
   control.append(options);menu.prepend(control);
  });
 }
 function start(){mount();const app=document.getElementById('app');if(app)new MutationObserver(mount).observe(app,{childList:true,subtree:true});}
 if(document.readyState==='loading')document.addEventListener('DOMContentLoaded',start,{once:true});else start();
 window.addEventListener('storage',event=>{if(event.key===key||event.key===null)apply(event.newValue);});
})();
