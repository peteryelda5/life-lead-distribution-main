const el=id=>document.getElementById(id);let busy=false;
async function refresh(){const r=await window.keySetup.status();if(!r.ok)throw Error(r.error);const s=r.value;
el('state').textContent=!s.available?'Windows-protected storage is unavailable. Setup is disabled.':!s.exists?'No key prepared on this computer.':(s.unlocked?'Unlocked. ':'Locked. ')+(s.verified?'Recovery check passed. Not enrolled in production.':'Recovery still needs to be tested.');
el('fingerprint').textContent=s.fingerprint?'Key fingerprint: '+s.fingerprint:'';
for(const id of ['create','restore'])el(id).disabled=busy||!s.available||s.exists;
for(const id of ['backup','verify','unlock'])el(id).disabled=busy||!s.available||!s.exists;
el('lock').disabled=busy||!s.unlocked;}
async function run(task){if(busy)return;busy=true;document.querySelectorAll('button').forEach(b=>b.disabled=true);el('message').textContent='Working…';try{const r=await task();if(!r.ok)throw Error(r.error);el('message').textContent=r.value?.message||'Done.';}catch(e){el('message').textContent=e.message;}finally{busy=false;el('password').value='';el('confirm').value='';await refresh().catch(e=>el('message').textContent=e.message);}}
el('setup').onsubmit=e=>{e.preventDefault();if(el('password').value!==el('confirm').value){el('message').textContent='The passwords do not match.';return;}const p=el('password').value;run(()=>window.keySetup.create(p));};
for(const id of ['verify','restore','unlock'])el(id).onclick=()=>{const p=el('password').value;run(()=>window.keySetup[id](p));};
for(const id of ['backup','lock'])el(id).onclick=()=>run(()=>window.keySetup[id]());
refresh().catch(e=>el('message').textContent=e.message);
setInterval(()=>{if(!busy)refresh().catch(()=>{});},15000);
