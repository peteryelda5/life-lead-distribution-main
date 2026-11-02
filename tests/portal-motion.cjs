'use strict';
const assert=require('node:assert/strict'),fs=require('node:fs'),path=require('node:path');
const {JSDOM}=require('jsdom'),source=fs.readFileSync(path.resolve(__dirname,'../portal-motion.js'),'utf8');
function fixture({reduced=false,supported=true}={}){
 const dom=new JSDOM('<header class="portal-topnav"><nav class="nav"><button class="active">Dashboard</button><button>Leads</button></nav></header><main class="wrap"><div class="head">Heading</div><div class="card">Panel<div class="metric">Nested</div></div><div class="card" hidden>Hidden</div><div class="card offscreen">Offscreen</div></main>',{runScripts:'outside-only'}),w=dom.window,d=w.document,animations=[],pref={matches:reduced,addEventListener:(name,fn)=>pref.change=fn};
 w.matchMedia=()=>pref;w.HTMLElement.prototype.getBoundingClientRect=function(){if(this.classList.contains('offscreen'))return {top:2000,bottom:2100};return {left:this.tagName==='BUTTON'&&this.textContent==='Leads'?120:0,right:this.tagName==='NAV'?400:this.tagName==='BUTTON'&&this.textContent==='Leads'?220:100,width:this.tagName==='NAV'?400:100,top:0,bottom:100};};
 if(supported)w.HTMLElement.prototype.animate=function(frames,options){let resolve;const animation={element:this,frames,options,canceled:false,finished:new Promise(r=>resolve=r),cancel(){this.canceled=true;},finish(){resolve();}};animations.push(animation);return animation;};
 w.eval(source);const nav=d.querySelector('nav'),buttons=[...d.querySelectorAll('button')];
 return {w,d,dom,animations,pref,nav,buttons,go(tab='leads'){const before=w.PortalMotion.capture();buttons[0].classList.remove('active');buttons[1].classList.add('active');w.PortalMotion.enter(before,{tab});}};
}
(async()=>{
 let f=fixture();try{f.nav.scrollLeft=40;f.go();assert.equal(f.animations.length,4,'Page, heading, outer card and tab underline animate');assert.equal(f.animations.filter(a=>a.element.matches('.metric,[hidden],.offscreen')).length,0);assert.equal(f.buttons[1].getAttribute('aria-current'),'page');assert.equal(f.nav.scrollLeft,40);assert(f.d.querySelector('.portal-moving-tab'));assert.equal(f.d.querySelector('main').inert,undefined);for(const a of f.animations)a.finish();await Promise.resolve();assert(!f.d.querySelector('.portal-moving-tab'));assert(!f.buttons[1].classList.contains('portal-tab-moving'));}finally{f.dom.window.close();}
 for(const tab of ['live-chat','power-dialer']){f=fixture();try{f.go(tab);assert.equal(f.animations.filter(a=>a.element.matches('.head,.card')).length,0);assert.equal(f.animations.length,2);}finally{f.dom.window.close();}}
 f=fixture({reduced:true});try{f.go();assert.equal(f.animations.length,0);assert(!f.d.querySelector('.portal-moving-tab'));}finally{f.dom.window.close();}
 f=fixture();try{f.go();f.pref.matches=true;f.pref.change();assert(f.animations.every(a=>a.canceled));assert(!f.d.querySelector('.portal-moving-tab'));}finally{f.dom.window.close();}
 f=fixture({supported:false});try{f.go();assert(!f.d.querySelector('.portal-moving-tab'));assert(!f.buttons[1].classList.contains('portal-tab-moving'));}finally{f.dom.window.close();}
 f=fixture();try{const before=f.w.PortalMotion.capture();f.w.PortalMotion.enter(before,{changed:false});assert.equal(f.animations.length,0);f.go();f.w.PortalMotion.capture();assert(f.animations.every(a=>a.canceled));assert(!f.d.querySelector('.portal-moving-tab'));}finally{f.dom.window.close();}
 console.log('PASS: bounded stagger, no nested/hidden/offscreen animations, moving indicator cleanup, navigation scroll, live dialer/chat, reduced motion, unsupported browser and canceled transitions');
})().catch(e=>{console.error(e);process.exitCode=1;});
