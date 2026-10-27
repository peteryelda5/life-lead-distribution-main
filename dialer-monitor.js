/* Listen-only supervisor headset. No agent/customer call controls are exposed. */
(() => {'use strict';
 window.createDialerMonitor=function(root,options){
  let disposed=false,id=null,device=null,call=null,busy=false,generation=0,polling=false;
  const box=document.createElement('section');box.className='power-panel';box.hidden=true;
  box.innerHTML='<h3>Listen to live calls</h3><p>Listen-only monitoring for connected Power Dialer calls. Your microphone is muted. Additional provider calling charges apply.</p><p data-listen-status role="status"></p><button data-listen-stop hidden>Stop listening</button><div data-listen-calls></div>';
  root.prepend(box);const status=box.querySelector('[data-listen-status]'),stopButton=box.querySelector('[data-listen-stop]'),rows=box.querySelector('[data-listen-calls]');
  const current=()=>{try{return !disposed&&JSON.parse(localStorage.getItem('lld_session')||'null')?.user?.id===options.owner;}catch{return false;}};
  async function request(action,extra={}){if(!current())throw Error('Account changed.');const s=await options.getSession();if(!current())throw Error('Account changed.');const r=await fetch('/api/dialer/monitor',{method:'POST',headers:{'Content-Type':'application/json',Authorization:'Bearer '+s.access_token},body:JSON.stringify({action,...extra}),signal:AbortSignal.timeout(15000)});const d=await r.json();if(!current())throw Error('Account changed.');if(!r.ok)throw Error(d.error||'Live listening is unavailable.');return d;}
  async function stop(message='Listening stopped.'){generation++;const old=id;id=null;busy=false;const c=call,d=device;call=null;device=null;try{c?.disconnect();d?.destroy();}catch{}stopButton.hidden=true;status.textContent=message;if(old&&current())await request('stop',{id:old}).catch(()=>{});}
  async function listen(item){if(busy||id)return;if(options.getActivity()!=='idle'){status.textContent='Finish your own call before listening.';return;}busy=true;const turn=++generation;status.textContent='Connecting listener…';stopButton.hidden=false;
   try{if(!window.Twilio?.Device)throw Error('Calling support did not load. Refresh Agent Dialer.');const d=await request('prepare',{powerId:item.id});if(!current()||turn!==generation){if(current())await request('stop',{id:d.id}).catch(()=>{});return;}id=d.id;
    device=new Twilio.Device(d.token,{logLevel:0,closeProtection:true});device.on('error',()=>{if(turn===generation)stop('Listener connection failed. The agent’s call is unchanged.');});
    const connection=await device.connect({params:{MonitorGrant:d.id}});if(!current()||turn!==generation){connection.disconnect();return;}call=connection;call.mute(true);busy=false;status.textContent='Listening to '+item.agent+' · microphone muted';
    for(const event of ['disconnect','cancel','reject','error'])call.on(event,()=>{if(turn===generation)stop('Listening ended.');});
   }catch(e){if(turn===generation)await stop(e.message);}
  }
  stopButton.onclick=()=>stop();
  async function refresh(){if(polling||!current())return;polling=true;try{const d=await request('list');box.hidden=false;rows.replaceChildren();for(const item of d.calls){const row=document.createElement('div'),label=document.createElement('strong'),button=document.createElement('button');row.className='row';label.textContent=item.agent+' · Connected';button.textContent='Listen live';button.disabled=busy||!!id||options.getActivity()!=='idle';button.onclick=()=>listen(item);row.append(label,button);rows.append(row);}if(!d.calls.length){const p=document.createElement('p');p.textContent='No connected Power Dialer calls in your agency scope.';rows.append(p);}}catch(e){rows.replaceChildren();if(id)await stop(e.message);else{box.hidden=true;}}finally{polling=false;}}
  const timer=setInterval(async()=>{if(!current()){dispose();return;}if(id){try{await request('heartbeat',{id});}catch(e){await stop(e.message);}}if(!root.hidden)refresh();},15000);
  function dispose(){if(disposed)return;stop();disposed=true;clearInterval(timer);box.remove();}
  return {refresh,dispose,active:()=>busy||!!id};
 };
})();
