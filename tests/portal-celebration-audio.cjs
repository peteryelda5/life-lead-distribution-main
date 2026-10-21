'use strict';
const fs=require('node:fs');
async function runAudioChecks(source){
 const check=(value,message)=>{if(!value)throw Error(message);};
 function setup(options={}){
  let now=10000,blocked=false,enabled=true,active=true,mode=options.mode||'running',next=0;
  const intervals=new Map(),timeouts=new Map(),contexts=[],tones=[],gains=[],document={hidden:false};
  class Context{
   constructor(){this.state='suspended';this.currentTime=5;this.destination={};this.closed=false;contexts.push(this);}
   async resume(){if(mode==='reject')throw Error('Autoplay blocked');this.state=mode;}
   async close(){this.state='closed';this.closed=true;}
   createOscillator(){const tone={frequency:{setValueAtTime(v,t){tone.frequencyValue=v;}},connect(){},disconnect(){tone.disconnected=true;},start(t){tone.startAt=t;},stop(t){tone.stopped=true;tone.stopAt=t;}};tones.push(tone);return tone;}
   createGain(){const gain={gain:{setValueAtTime(){},linearRampToValueAtTime(v){gain.peak=v;},exponentialRampToValueAtTime(){}},connect(){},disconnect(){gain.disconnected=true;}};gains.push(gain);return gain;}
  }
  const window=options.unsupported?{}:{AudioContext:Context};
  new Function('window','document','Date','setInterval','clearInterval','setTimeout','clearTimeout',source)(window,document,{now:()=>now},fn=>{intervals.set(++next,fn);return next;},id=>intervals.delete(id),fn=>{timeouts.set(++next,fn);return next;},id=>timeouts.delete(id));
  const sound=window.createPortalCelebrationSound({enabled:()=>enabled,quiet:()=>blocked,active:()=>active});
  return {sound,document,tones,gains,contexts,intervals,timeouts,tick(){now+=4000;},block(v){blocked=v;},enable(v){enabled=v;},activate(v){active=v;},mode(v){mode=v;}};
 }
 const h=setup();
 check(!await h.sound.play(),'No automatic sound before user interaction');check(h.contexts.length===0,'No AudioContext before interaction');
 check(await h.sound.unlock(),'User interaction unlocks audio');check(h.contexts.length===1,'One dedicated audio context');
 check(await h.sound.play(),'Fresh celebration plays');check(h.tones.length===3,'Three short notes');
 check(h.tones[2].stopAt-h.tones[0].startAt<.75,'Chime stays below one second');check(h.gains.every(g=>g.peak<=.045),'Low gain');
 check(!await h.sound.play(),'Burst alerts do not stack sounds');check(h.tones.length===3,'No overlapping voices');
 h.block(true);[...h.intervals.values()][0]();check(h.tones.every(t=>t.disconnected),'Starting a call stops existing sound');check(h.intervals.size===0&&h.timeouts.size===0,'Sound guards cleaned up');
 h.tick();check(!await h.sound.play(true),'Preview is silent during calls');check(h.tones.length===3,'No call interruption');
 h.block(false);h.enable(false);check(!await h.sound.play(true),'Muted preference suppresses preview and alerts');
 h.enable(true);h.document.hidden=true;check(!await h.sound.play(),'Background tab stays silent');h.document.hidden=false;
 h.activate(false);check(!await h.sound.play(),'Inactive account stays silent');h.activate(true);
 check(await h.sound.play(true),'Preview plays after interaction when safe');check(h.contexts.length===1,'Context reused');
 h.sound.dispose();check(h.contexts[0].closed&&h.intervals.size===0&&h.timeouts.size===0,'Logout disposes context and timers');check(!await h.sound.play(true),'Disposed account cannot replay');
 const unsupported=setup({unsupported:true});check(!await unsupported.sound.play(true),'Unsupported browsers retain visual alerts');unsupported.sound.dispose();
 const rejected=setup({mode:'reject'});check(!await rejected.sound.play(true),'Autoplay rejection is handled');check(rejected.tones.length===0,'Blocked sound is not scheduled');
 rejected.mode('running');await rejected.sound.unlock();check(rejected.tones.length===0,'Unlock does not replay missed sounds');rejected.sound.dispose();
 return 'PASS: short low-volume chime, gesture unlock, preview, burst throttling, active-call and wrap-up suppression, immediate stop on call, mute/background/account guards, autoplay failures, context/timer cleanup.';
}
runAudioChecks(fs.readFileSync(__dirname+'/../portal-celebration-audio.js','utf8')).then(console.log).catch(e=>{console.error(e);process.exitCode=1;});
