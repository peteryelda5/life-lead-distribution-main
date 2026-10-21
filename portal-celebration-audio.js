/* Local celebration chime; no media downloads and no connection to call audio. */
(() => {
 'use strict';
 window.createPortalCelebrationSound=function({enabled,quiet,active}){
  let context=null,disposed=false,lastPlayed=-Infinity,guard=null,finish=null,voices=[];
  const allowed=()=>!disposed&&active()&&!document.hidden&&enabled()&&!quiet();
  function stop(){clearInterval(guard);clearTimeout(finish);guard=null;finish=null;for(const {tone,gain} of voices){try{tone.stop();}catch{}try{tone.disconnect();gain.disconnect();}catch{}}voices=[];}
  async function unlock(){
   if(!allowed())return false;
   try{const Audio=window.AudioContext||window.webkitAudioContext;if(!Audio)return false;if(!context)context=new Audio();const ctx=context;if(ctx.state==='suspended')await ctx.resume();return !disposed&&context===ctx&&ctx.state==='running';}catch{return false;}
  }
  async function play(preview=false){
   if(!allowed()||(!preview&&Date.now()-lastPlayed<3000))return false;
   // Automatic alerts never wait for permission and then surprise the user later.
   if(preview&&!await unlock())return false;
   if(!allowed()||!context||context.state!=='running'||(!preview&&Date.now()-lastPlayed<3000))return false;
   stop();lastPlayed=Date.now();
   try{
    const start=context.currentTime;
    [659.25,830.61,1108.73].forEach((frequency,i)=>{
     const tone=context.createOscillator(),gain=context.createGain(),at=start+i*.12;
     voices.push({tone,gain});tone.type='sine';tone.frequency.setValueAtTime(frequency,at);
     gain.gain.setValueAtTime(0,at);gain.gain.linearRampToValueAtTime(.045,at+.012);gain.gain.exponentialRampToValueAtTime(.0001,at+.45);
     tone.connect(gain);gain.connect(context.destination);tone.start(at);tone.stop(at+.46);
    });
    guard=setInterval(()=>{if(!allowed())stop();},60);finish=setTimeout(stop,750);return true;
   }catch{stop();return false;}
  }
  return {unlock,play,stop,dispose(){disposed=true;stop();const ctx=context;context=null;if(ctx)try{Promise.resolve(ctx.close()).catch(()=>{});}catch{}}};
 };
})();
