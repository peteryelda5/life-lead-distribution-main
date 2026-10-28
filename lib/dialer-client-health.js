'use strict';
const {rpc,UUID,failure}=require('./dialer-full');
const EVENTS=new Set(['started','accepted','ringing','reconnecting','reconnected','sdk_disconnect','cancel','reject','call_error','device_error','warning','warning_cleared','audio_sample','user_hangup','page_exit','offline','online','session_end','prepared','headset_ready','launch_requested','conversation_presented','batch_finished','setup_failed']);
const WARNINGS=new Set(['high-rtt','high-jitter','high-packet-loss','low-mos','low-bytes-received','low-bytes-sent','constant-audio-input-level','constant-audio-output-level','ice-connectivity-lost','signaling-connection-disconnected']);
function cleanEvent(e){
 if(!e||!UUID.test(e.id||'')||!EVENTS.has(e.type)||!Number.isInteger(e.ms)||e.ms<0||e.ms>7200000)throw failure(400,'Invalid call diagnostic event.');
 const value={id:e.id,type:e.type,ms:e.ms};
 if(Number.isInteger(e.code)&&e.code>0&&e.code<100000)value.code=e.code;
 if(WARNINGS.has(e.warning))value.warning=e.warning;
 if(['pending','connecting','ringing','open','reconnecting','closed'].includes(e.state))value.state=e.state;
 if(typeof e.online==='boolean')value.online=e.online;
 if(typeof e.hidden==='boolean')value.hidden=e.hidden;
 if(e.metrics&&typeof e.metrics==='object'){
  const metrics={};for(const key of ['setupMs','jitter','rtt','mos','packetsLostFraction','bytesReceived','bytesSent','audioInputLevel','audioOutputLevel']){
   const n=e.metrics[key];if(typeof n==='number'&&Number.isFinite(n)&&n>=0&&n<=1e12)metrics[key]=Math.round(n*1000)/1000;
  }if(Object.keys(metrics).length)value.metrics=metrics;
 }
 return value;
}
async function action(req,u){
 const b=req.body;if(!['call','parallel'].includes(b.kind)||!UUID.test(b.id||'')||!Array.isArray(b.events)||b.events.length<1||b.events.length>20)throw failure(400,'Invalid call diagnostics.');
 return rpc('dialer_record_client_health',{p_user:u.id,p_session:u.sessionId,p_kind:b.kind,p_target:b.id,p_events:b.events.map(cleanEvent)});
}
module.exports={action,cleanEvent};
