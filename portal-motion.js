/* Presentation-only tab transitions: no waiting, data changes or navigation ownership. */
(()=>{
 'use strict';
 let running=[];
 const preference=window.matchMedia?.('(prefers-reduced-motion: reduce)');
 const reduced=()=>preference?.matches===true;
 function clear(){for(const stop of running.splice(0))stop();}
 function animate(element,frames,options,done=()=>{}){
  if(!element?.animate){done();return;}
  try{const animation=element.animate(frames,options);let stopped=false;
   const stop=()=>{if(stopped)return;stopped=true;animation.cancel();done();const index=running.indexOf(stop);if(index>=0)running.splice(index,1);};
   running.push(stop);animation.finished.then(stop,stop);
  }catch{done();}
 }
 function capture(){
  clear();const nav=document.querySelector('.portal-topnav .nav'),active=nav?.querySelector('button.active');
  if(!nav)return null;const n=nav.getBoundingClientRect(),a=active?.getBoundingClientRect();
  return {scroll:nav.scrollLeft,left:a?a.left-n.left+nav.scrollLeft:null,width:a?.width||0};
 }
 function enter(previous,{changed=true,tab=''}={}){
  clear();const nav=document.querySelector('.portal-topnav .nav'),wrap=document.querySelector('.portal-topnav + main.wrap');
  if(nav&&previous)nav.scrollLeft=previous.scroll;
  const active=nav?.querySelector('button.active');
  if(active){
   const n=nav.getBoundingClientRect(),a=active.getBoundingClientRect();
   if(a.left<n.left)nav.scrollLeft-=n.left-a.left;
   else if(a.right>n.right)nav.scrollLeft+=a.right-n.right;
   active.setAttribute('aria-current','page');
  }
  if(!changed||reduced()||!wrap)return;
  animate(wrap,[{opacity:.35},{opacity:1}],{duration:200,easing:'ease-out'});
  // Live calling/chat surfaces stay mounted and get only the page fade.
  if(!['power-dialer','live-chat'].includes(tab)){
   const candidates=[...wrap.querySelectorAll('.head,.card,.metric,.db-agency-card')];const selected=new Set(candidates);
   const panels=candidates.filter(el=>{if(el.closest('[hidden],.hidden,.modal'))return false;let p=el.parentElement;while(p&&p!==wrap){if(selected.has(p))return false;p=p.parentElement;}const r=el.getBoundingClientRect();return r.bottom>0&&r.top<window.innerHeight;}).slice(0,12);
   panels.forEach((panel,index)=>animate(panel,[{opacity:0,transform:'translateY(12px)'},{opacity:1,transform:'translateY(0)'}],{duration:280,delay:Math.min(index*30,180),easing:'cubic-bezier(.2,.75,.25,1)',fill:'backwards'}));
  }
  if(nav&&active&&previous?.left!=null&&previous.width>0){
   const n=nav.getBoundingClientRect(),a=active.getBoundingClientRect(),left=a.left-n.left+nav.scrollLeft;
   if(a.width>0){const marker=document.createElement('span');marker.className='portal-moving-tab';marker.setAttribute('aria-hidden','true');marker.style.width=a.width+'px';marker.style.transform='translateX('+left+'px)';nav.append(marker);active.classList.add('portal-tab-moving');
    animate(marker,[{transform:'translateX('+previous.left+'px) scaleX('+previous.width/a.width+')'},{transform:'translateX('+left+'px) scaleX(1)'}],{duration:280,easing:'cubic-bezier(.2,.75,.25,1)'},()=>{marker.remove();active.classList.remove('portal-tab-moving');});
   }
  }
 }
 preference?.addEventListener?.('change',()=>{if(reduced())clear();});
 window.addEventListener('pagehide',clear);
 window.PortalMotion={capture,enter,clear};
})();
