/* The selected cash-register sample; cached locally and separate from call audio. */
(() => {
 'use strict';
 window.createPortalCelebrationSound=function({enabled,quiet,active}){
  let context=null,buffer=null,loading=null,request=null,disposed=false,lastPlayed=-Infinity,guard=null,finish=null,voices=[];
  const allowed=()=>!disposed&&active()&&!document.hidden&&enabled()&&!quiet();
  function stop(){clearInterval(guard);clearTimeout(finish);guard=null;finish=null;for(const {tone,gain} of voices){try{tone.stop();}catch{}try{tone.disconnect();gain.disconnect();}catch{}}voices=[];}
  async function unlock(){
   if(!allowed())return false;
   try{
    const Audio=window.AudioContext||window.webkitAudioContext;if(!Audio)return false;if(!context)context=new Audio();const ctx=context;
    if(ctx.state==='suspended')await ctx.resume();if(disposed||context!==ctx||ctx.state!=='running')return false;
    if(!buffer&&!loading){
     request=new AbortController();
     loading=(async()=>{try{const response=await window.fetch('/celebration-cash.wav?v=20261020-cash-register',{credentials:'omit',cache:'force-cache',signal:request.signal});if(!response.ok)throw Error('Sound unavailable');const decoded=await ctx.decodeAudioData(await response.arrayBuffer());if(!disposed&&context===ctx)buffer=decoded;}catch{}finally{loading=null;request=null;}})();
    }
    if(loading)await loading;
    return !disposed&&context===ctx&&ctx.state==='running'&&!!buffer;
   }catch{return false;}
  }
  async function play(preview=false){
   if(!allowed()||(!preview&&Date.now()-lastPlayed<3000))return false;
   // Automatic alerts never wait for permission and then surprise the user later.
   if(preview&&!await unlock())return false;
   if(!allowed()||!context||!buffer||context.state!=='running'||(!preview&&Date.now()-lastPlayed<3000))return false;
   stop();lastPlayed=Date.now();
   try{
    const tone=context.createBufferSource(),gain=context.createGain();voices.push({tone,gain});tone.buffer=buffer;
    gain.gain.setValueAtTime(1,context.currentTime);tone.connect(gain);gain.connect(context.destination);tone.start();
    guard=setInterval(()=>{if(!allowed())stop();},60);finish=setTimeout(stop,Math.ceil(buffer.duration*1000)+50);return true;
   }catch{stop();return false;}
  }
  return {unlock,play,stop,dispose(){disposed=true;stop();request?.abort();buffer=null;const ctx=context;context=null;if(ctx)try{Promise.resolve(ctx.close()).catch(()=>{});}catch{}}};
 };
})();

