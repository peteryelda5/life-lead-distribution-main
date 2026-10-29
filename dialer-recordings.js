/* Private Media Streams archive. Owner-only, consented test capture. */
(() => {
 'use strict';
 window.createDialerRecordings=function(root,options){
  const owner=options.owner,master=owner==='8139e230-055d-4247-8133-684ed817b4fa';
  let disposed=false,view='',flight=false,rows=[],candidates=[],audio=null;
  const same=()=>{try{return !disposed&&JSON.parse(localStorage.getItem('lld_session')||'null')?.user?.id===owner;}catch{return false;}};
  const el=(tag,text)=>{const e=document.createElement(tag);if(text)e.textContent=text;return e;};
  const tab=el('button','Call recordings');tab.dataset.view='recordings';tab.setAttribute('aria-selected','false');tab.onclick=()=>options.openView('recordings');root.querySelector('.workspace-tabs').append(tab);
  const panel=el('main');panel.id='recordings';panel.className='secondary-view recording-library';panel.hidden=true;
  panel.innerHTML='<header class="agent-ops-heading"><div><span class="agent-eyebrow">PRIVATE AUDIO LIBRARY</span><h2>Call recordings</h2><p>Saved in your portal’s private storage. Older unrecorded calls have no audio.</p></div><button data-refresh>Refresh</button></header><p data-message role="status"></p><div class="recording-filters"><label>Agent, client or phone<input data-search type="search" placeholder="Search recordings"></label><label>Date<input data-date type="date"></label></div><div data-player></div><div data-rows></div>';
  root.append(panel);
  const test=el('section');test.className='recording-test';test.hidden=!master;
  test.innerHTML='<strong>Private recording test</strong><span>Only Peters main phone · 248-238-3969 · maximum 10 minutes</span><label><input data-consent type="checkbox"> Everyone on this test call agrees to being recorded.</label><div><button data-start>Start recording connected test call</button><button data-stop hidden>Stop recording</button></div><p data-test-message role="status">Recording off. Connect the test phone in Power Dialer, then start here.</p>';
  if(master)root.querySelector('#parallel .power-heading')?.after(test);
  const $=s=>panel.querySelector(s),t=s=>test.querySelector(s);
  async function request(action,extra={}){if(!same())throw Error('Reload after changing accounts');const s=await options.getSession();if(!same())throw Error('Account changed');const r=await fetch('/api/dialer/recordings',{method:'POST',headers:{'Content-Type':'application/json',Authorization:'Bearer '+s.access_token},body:JSON.stringify({action,...extra}),cache:'no-store',signal:AbortSignal.timeout(25000)});const d=await r.json();if(!same())throw Error('Account changed');if(!r.ok)throw Error(d.error||'Recordings unavailable');return d;}
  function clearAudio(){if(audio){audio.pause();audio.removeAttribute('src');audio.load();audio=null;}$('[data-player]').replaceChildren();}
  function draw(){
   const q=$('[data-search]').value.trim().toLowerCase(),date=$('[data-date]').value,box=$('[data-rows]');box.replaceChildren();
   const filtered=rows.filter(r=>[r.agent_name,r.client_name,r.phone].join(' ').toLowerCase().includes(q)&&(!date||new Date(r.created_at).toLocaleDateString('en-CA')===date));
   if(!filtered.length)box.append(el('p','No recordings match. Only calls recorded after setup appear here.'));
   for(const r of filtered){const card=el('article');card.className='recording-row';const details=el('div');details.append(el('strong',r.client_name||r.phone),el('p',(r.agent_name||'Agent')+' · '+r.phone+' · '+new Date(r.created_at).toLocaleString()),el('small',r.state+' · '+Math.round(r.duration_ms/1000)+' seconds'+(r.provider_recordings_checked?' · No Twilio recording found':'')));if(r.issue)details.append(el('p',r.issue));card.append(details);const play=el('button','Play recording');play.disabled=!r.playable;play.onclick=async()=>{play.disabled=true;try{clearAudio();const d=await request('play',{id:r.id});audio=el('audio');audio.controls=true;audio.preload='metadata';audio.src=d.url;audio.onerror=()=>{$('[data-message]').textContent='Audio could not load. Click Play recording again to refresh access.';};$('[data-player]').append(el('strong',(r.client_name||r.phone)+' — '+(r.agent_name||'Agent')),audio);await audio.play().catch(()=>{});}catch(e){$('[data-message]').textContent=e.message;}finally{play.disabled=false;}};card.append(play);box.append(card);}
  }
  async function refresh(){if(flight||!same())return;flight=true;try{const d=await request('list');rows=d.recordings||[];candidates=d.candidates||[];draw();$('[data-message]').textContent='Showing up to 100 recent recordings within your permitted scope.';
   if(master){const active=rows.find(r=>r.user_id===owner&&['starting','streaming'].includes(r.state));t('[data-stop]').hidden=!active;t('[data-stop]').dataset.id=active?.id||'';t('[data-start]').disabled=!!active||!candidates.length;t('[data-test-message]').textContent=active?(active.state==='streaming'?'Recording to private portal storage.':'Connecting the private recorder…'):candidates.length?'Test phone connected. Confirm consent, then start recording.':'Recording off. Connect Peters main phone using Power Dialer.';}
  }catch(e){$('[data-message]').textContent=e.message;if(master)t('[data-test-message]').textContent=e.message;}finally{flight=false;}}
  t('[data-start]').onclick=async()=>{if(!t('[data-consent]').checked){t('[data-test-message]').textContent='Confirm everyone agrees before recording.';return;}t('[data-start]').disabled=true;try{await request('start',{powerId:candidates[0]?.id,consent:true});t('[data-consent]').checked=false;await refresh();}catch(e){t('[data-test-message]').textContent=e.message;t('[data-start]').disabled=false;}};
  t('[data-stop]').onclick=async()=>{t('[data-stop]').disabled=true;try{await request('stop',{id:t('[data-stop]').dataset.id});t('[data-test-message]').textContent='Saving audio…';}catch(e){t('[data-test-message]').textContent=e.message;}finally{t('[data-stop]').disabled=false;}};
  $('[data-refresh]').onclick=refresh;$('[data-search]').oninput=draw;$('[data-date]').onchange=draw;
  const timer=setInterval(()=>{if(!same()){dispose();return;}if(!document.hidden&&(view==='recordings'||master&&!root.querySelector('#parallel')?.hidden))refresh();},5000);
  function dispose(){if(disposed)return;disposed=true;clearInterval(timer);clearAudio();test.remove();tab.remove();panel.remove();}
  if(master)refresh();
  return {show(name){view=name;if(name==='recordings')refresh();else clearAudio();},dispose};
 };
})();
