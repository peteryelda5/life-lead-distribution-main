(function(){

'use strict';
const $=id=>document.getElementById('manual-'+id);window.manualCalling=()=>busy||!!activeCall;
let connectedAt=0;
let device=null,activeCall=null,busy=false,ready=false,callEpoch=0,startingToken=null;
function session(){try{return JSON.parse(localStorage.getItem('lld_session')||'null')}catch{return null}}
function status(text,error=false){$('status').textContent=text;$('status').classList.toggle('error',error)}
function controls(){ $('check').disabled=busy||!!activeCall;$('call').disabled=busy||!!activeCall||!ready||!$('permission').checked||!$('destination').value.trim();$('destination').disabled=$('caller').disabled=busy||!!activeCall;$('mute').disabled=!activeCall;$('hangup').disabled=!activeCall;}
async function authorization(){
 const sess=session();if(!sess?.access_token)throw Error('Sign in to the portal and complete two-step verification.');
 const response=await fetch('/api/dialer/token-v2',{method:'POST',headers:{'Content-Type':'application/json',Authorization:'Bearer '+sess.access_token},body:JSON.stringify({phoneNumber:$('destination').value,callerSlot:Number($('caller').value),permission:$('permission').checked}),cache:'no-store',signal:AbortSignal.timeout(60000)});
 const data=await response.json();if(!response.ok)throw Error(data.error||'Call could not be authorized.');if(session()?.access_token!==sess.access_token)throw Error('Your portal session changed. Check setup again.');return {...data,sessionToken:sess.access_token};
}
function display(data){}
async function checkSetup(){const sess=session();if(!sess?.access_token)throw Error('Sign in to the portal first.');const response=await fetch('/api/dialer/account',{method:'POST',headers:{'Content-Type':'application/json',Authorization:'Bearer '+sess.access_token},body:JSON.stringify({action:'state'}),cache:'no-store',signal:AbortSignal.timeout(60000)});const data=await response.json();if(!response.ok)throw Error(data.error||'Account unavailable.');if(session()?.access_token!==sess.access_token)throw Error('Session changed.');const select=$('caller');select.replaceChildren();for(const number of data.numbers||[]){if(number.state==='active'){const o=document.createElement('option');o.value=String(number.slot);o.textContent=number.phoneNumber;select.append(o);}}if(!data.entitled||!data.realCallingAllowed)throw Error('An active calling subscription is required. Agent calling is unavailable in Stripe test mode.');if(!select.options.length)throw Error('Activate a number in Numbers & billing first.');}
function cleanup(){connectedAt=0;callEpoch++;activeCall=null;busy=false;startingToken=null;$('mute').textContent='Mute';if(device){device.destroy();device=null}controls();}
$('check').onclick=async()=>{busy=true;ready=false;controls();status('Checking your portal login and calling setup…');try{if(!window.Twilio?.Device)throw new Error('Calling support did not load. Check your internet connection and refresh.');await checkSetup();ready=true;status('Setup is ready. Click Call now and allow microphone access.');}catch(e){status(e.message,true)}finally{busy=false;controls()}};
$('call').onclick=async()=>{
  if(busy||activeCall||!ready||!$('permission').checked)return;
  busy=true;controls();const epoch=++callEpoch;
  try{
    $('test-timer').textContent='00:00';status('Preparing your call…');const data=await authorization();if(epoch!==callEpoch)return;display(data);startingToken=data.sessionToken;
    device=new Twilio.Device(data.token,{logLevel:0,closeProtection:true});
    device.on('error',e=>{if(epoch!==callEpoch)return;status('Calling error '+(e.code||'')+': '+(e.message||'Check your Twilio settings.'),true);cleanup()});
    const call=await device.connect({params:{CallGrant:data.callGrant}});
    if(epoch!==callEpoch){call.disconnect();return}
    activeCall=call;busy=false;controls();status('Calling…');
    call.on('ringing',()=>{if(epoch===callEpoch)status('Ringing…')});
    call.on('accept',()=>{if(epoch===callEpoch){connectedAt=Date.now();status('Call connected. Check that you can hear both directions.');}});
    for(const event of ['disconnect','cancel','reject'])call.on(event,()=>{if(epoch===callEpoch){status('Call ended. You can place another test call.');cleanup()}});
    call.on('error',e=>{if(epoch===callEpoch){status('Call error '+(e.code||'')+': '+(e.message||'Please try again.'),true);cleanup()}});
  }catch(e){if(epoch===callEpoch){status(e.name==='NotAllowedError'?'Allow microphone access in your browser, then try again.':e.message,true);cleanup()}}
};
$('mute').onclick=()=>{if(!activeCall)return;const muted=!activeCall.isMuted();activeCall.mute(muted);$('mute').textContent=muted?'Unmute':'Mute'};
$('hangup').onclick=()=>{if(activeCall)activeCall.disconnect();cleanup();status('Call ended.');};
setInterval(()=>{if(startingToken&&session()?.access_token!==startingToken){if(activeCall)activeCall.disconnect();cleanup();ready=false;controls();status('Your portal session changed. Click Check setup to continue.',true)}},1000);
window.addEventListener('pagehide',()=>{if(activeCall)activeCall.disconnect();cleanup()});
$('clearphone').onclick=()=>{if(!busy&&!activeCall){$('destination').value='';controls();}};$('permission').onchange=controls;$('destination').oninput=controls;$('caller').onchange=controls;
for(const [digit,letters] of [['1',''],['2','ABC'],['3','DEF'],['4','GHI'],['5','JKL'],['6','MNO'],['7','PQRS'],['8','TUV'],['9','WXYZ'],['*',''],['0','+'],['#','']]){const button=document.createElement('button');button.type='button';button.textContent=digit;button.setAttribute('aria-label','Send digit '+digit);const sub=document.createElement('small');sub.textContent=letters||' ';button.append(sub);button.onclick=()=>{if(activeCall?.status()==='open')activeCall.sendDigits(digit);else if(!busy){$('destination').value+=digit;controls();}};$('test-keypad').append(button);}
setInterval(()=>{if(connectedAt){const seconds=Math.floor((Date.now()-connectedAt)/1000);$('test-timer').textContent=String(Math.floor(seconds/60)).padStart(2,'0')+':'+String(seconds%60).padStart(2,'0');}},1000);
$('sdk-note').textContent=window.Twilio?.Device?'Calling support loaded.':'Calling support failed to load. Refresh or check your connection.';

})();
