/* Private, best-effort call diagnostics. Never controls or blocks call audio. */
(() => {
 'use strict';
 const live=call=>{try{return ['open','reconnecting'].includes(call?.status());}catch{return false;}};
 function create(options){
  const started=Date.now(),owner=options.session?.user?.id;let session=options.session,closed=false,sending=false,pending=[],lastSample=0,count=0,retries=0;
  const bindings=[],warnings=new Map();let call=null;
  function record(type,extra={}){if(closed||count>=380)return;pending.push({id:crypto.randomUUID(),type,ms:Math.max(0,Math.min(7200000,Date.now()-started)),online:navigator.onLine,hidden:document.hidden,...extra});count++;}
  async function flush(keepalive=false){
   if(sending||!pending.length||!owner)return;sending=true;let batch;
   try{
    if(!keepalive&&options.getSession)session=await options.getSession();
    if(session?.user?.id!==owner||!session?.access_token){pending=[];return;}
    batch=pending.splice(0,20);const r=await fetch('/api/dialer/client-health',{method:'POST',headers:{'Content-Type':'application/json',Authorization:'Bearer '+session.access_token},body:JSON.stringify({kind:options.kind,id:options.id,events:batch}),keepalive,cache:'no-store',signal:AbortSignal.timeout(8000)});
    if(!r.ok){if(r.status===401||r.status===403||r.status===400){pending=[];return;}throw Error('Diagnostics unavailable');}retries=0;
   }catch{if(batch&&retries++<3)pending.unshift(...batch);}
   finally{sending=false;if(closed&&pending.length&&retries<3)setTimeout(()=>flush(true),250);}
  }
  const state=()=>{try{return call?.status();}catch{return undefined;}};
  function bind(target,event,fn){target.on(event,fn);bindings.push(()=>target.removeListener?.(event,fn));}
  function bindDevice(device){bind(device,'error',e=>{record('device_error',{code:Number(e?.code),state:state()});flush();});}
  function bindCall(c){
   call=c;
   for(const [event,type] of [['accept','accepted'],['ringing','ringing'],['disconnect','sdk_disconnect'],['cancel','cancel'],['reject','reject']])bind(c,event,()=>{record(type,{state:state()});flush();});
   bind(c,'error',e=>{record('call_error',{code:Number(e?.code),state:state()});flush();});
   bind(c,'reconnecting',e=>{record('reconnecting',{code:Number(e?.code),state:state()});options.notice?.('Connection interrupted. Trying to reconnect—keep this call open.',true);flush();});
   bind(c,'reconnected',()=>{record('reconnected',{state:state()});options.notice?.('Call connection restored.',false);flush();});
   for(const event of ['warning','warning-cleared'])bind(c,event,name=>{
    if(typeof name!=='string'||!/^[a-z-]{1,60}$/.test(name))return;
    const key=event+name;if(Date.now()-(warnings.get(key)||0)<10000)return;warnings.set(key,Date.now());record(event==='warning'?'warning':'warning_cleared',{warning:name,state:state()});
    if(event==='warning')options.notice?.('Call audio or network quality needs attention. Check your headset and connection.',true);
   });
   bind(c,'sample',sample=>{if(Date.now()-lastSample<30000)return;lastSample=Date.now();const metrics={};for(const key of ['jitter','rtt','mos','packetsLostFraction','bytesReceived','bytesSent','audioInputLevel','audioOutputLevel'])if(typeof sample?.[key]==='number'&&Number.isFinite(sample[key]))metrics[key]=sample[key];record('audio_sample',{metrics,state:state()});});
   if(live(c))record('accepted',{state:state()});
  }
  const offline=()=>{record('offline',{state:state()});flush();},online=()=>{record('online',{state:state()});flush();},pagehide=()=>{record('page_exit',{state:state()});flush(true);};
  window.addEventListener('offline',offline);window.addEventListener('online',online);window.addEventListener('pagehide',pagehide);
  const timer=setInterval(flush,5000);record('started');
  function close(){if(closed)return;record('session_end',{state:state()});closed=true;clearInterval(timer);window.removeEventListener('offline',offline);window.removeEventListener('online',online);window.removeEventListener('pagehide',pagehide);bindings.forEach(fn=>fn());flush(true);}
  return {record,flush,bindDevice,bindCall,close};
 }
 window.VividCallHealth={create,live};
})();
