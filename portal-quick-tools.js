/* Floating agency resources. Script permissions and calling authorization stay in existing APIs. */
(()=>{
 'use strict';
 const SHEET='Sales Process / Objection Sheet',PAGE=50;
 let root,owner,division,tab='scripts',opened=false,epoch=0,request=0,bodyRequest=0,timer,rows=[],selected=null,page=0,total=0,sheet=null,editing=false;
 const $=s=>root?.querySelector(s);
 const allowed=()=>!!(S.session&&S.profile?.active&&['agent','admin'].includes(S.profile.role)&&!S.mfaMode&&portalVerified()&&ONBOARDING.userId===S.profile.id&&ONBOARDING.complete);
 const icon=kind=>'<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.7" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path d="'+({tools:'M4 5h16v14H4zM4 10h16M10 10v9',scripts:'M4 3h11l5 5v13H4zM14 3v6h6M8 13h8M8 17h6',dialer:'M5 3h4l2 5-3 2a15 15 0 0 0 6 6l2-3 5 2v4a2 2 0 0 1-2 2C10 21 3 14 3 5a2 2 0 0 1 2-2',process:'M9 5h11M9 12h11M9 19h11M3 5l1 1 2-2M3 12l1 1 2-2M3 19l1 1 2-2',minus:'M5 12h14',up:'m6 14 6-6 6 6'})[kind]+'"/></svg>';
 function reset(){dialerFlight=null;epoch++;request++;bodyRequest++;clearInterval(timer);timer=null;root?.remove();root=null;owner=null;rows=[];selected=null;sheet=null;editing=false;page=0;total=0;opened=false;document.body.classList.remove('has-quick-tools','quick-tools-open');}
 function current(e=epoch,d=division){return e===epoch&&allowed()&&owner===S.profile.id&&d===division;}
 function sync(){
  if(!allowed()){if(root)reset();return;}
  if(owner!==S.profile.id){reset();owner=S.profile.id;division=S.profile.division;tab='scripts';
   try{const pref=JSON.parse(sessionStorage.getItem('vivid-quick-tools:'+owner)||'null');if(['scripts','dialer','process'].includes(pref?.tab))tab=pref.tab;opened=pref?.open===true;}catch{}
   mount();
  }
  if(S.tab==='power-dialer'){
   $('#qtDialerStatus').textContent='Your Agent Dialer is open in the main workspace.';
   $('#qtDialerStatus').hidden=false;$('#qtDialerRetry').hidden=true;
  }else if(opened&&tab==='dialer')void mountDialer();
  paintActivity();
 }
 function savePreference(){try{sessionStorage.setItem('vivid-quick-tools:'+owner,JSON.stringify({open:opened,tab}));}catch{}}
 function setOpen(value){opened=value;$('#qtPanel').hidden=!opened;$('#qtLauncher').setAttribute('aria-expanded',String(opened));document.body.classList.toggle('quick-tools-open',opened);savePreference();if(opened)activate(tab);else if(portalDialerInstance?.root.closest('#portalQuickTools'))portalDialerInstance.setVisible?.(false);}
 function mount(){
  root=document.createElement('aside');root.id='portalQuickTools';root.setAttribute('aria-label','Agent tools');
  root.innerHTML='<section id="qtPanel" class="qt-panel" aria-labelledby="qtTitle" hidden><header class="qt-header"><div class="qt-brand">'+icon('tools')+'<div><strong id="qtTitle">Agent Tools</strong><span>Vivid Life Portal</span></div></div><button type="button" id="qtMinimize" aria-label="Minimize agent tools">'+icon('minus')+'</button></header><div class="qt-tabs" role="tablist" aria-label="Agent tools sections">'+[['scripts','Scripts'],['dialer','Agent Dialer'],['process','Sales process / objection sheet']].map(([key,label])=>'<button type="button" id="qtTab-'+key+'" role="tab" aria-controls="qtPane-'+key+'" aria-selected="false" tabindex="-1" data-qt-tab="'+key+'">'+icon(key)+'<span>'+label+'</span></button>').join('')+'</div><div class="qt-scope"><label for="qtAgency">Agency</label><select id="qtAgency"></select></div><section id="qtPane-scripts" class="qt-pane" role="tabpanel" aria-labelledby="qtTab-scripts" hidden><div class="qt-resource-tools"><label for="qtScript">Call script</label><button type="button" id="qtRefreshScripts" class="qt-link">Refresh</button><select id="qtScript"><option value="">Loading scripts…</option></select></div><div id="qtScriptPages" class="qt-pages" hidden><button type="button" id="qtPrevious">Previous</button><span id="qtPageLabel"></span><button type="button" id="qtNext">Next</button></div><p id="qtScriptStatus" role="status" class="qt-hint"></p><article id="qtScriptReader" class="qt-reader"><h2 id="qtScriptTitle"></h2><div id="qtScriptBody" class="qt-copy"></div></article></section><section id="qtPane-dialer" class="qt-pane qt-dialer-pane" role="tabpanel" aria-labelledby="qtTab-dialer" hidden><div class="qt-dialer-top"><p class="qt-hint">Use your existing caller ID and dialer access.</p><button type="button" id="qtFullDialer" class="qt-link">Open full dialer ↗</button></div><p id="qtDialerStatus" class="qt-hint" role="status">Open Agent Dialer to load the keypad.</p><button type="button" id="qtDialerRetry" class="qt-secondary" hidden>Try again</button><div id="qtDialerMount"></div></section><section id="qtPane-process" class="qt-pane" role="tabpanel" aria-labelledby="qtTab-process" hidden><div class="qt-sheet-head"><h2>Sales process / objection sheet</h2><button type="button" id="qtEditSheet" class="qt-link" hidden>Add sheet</button></div><p id="qtSheetStatus" class="qt-hint" role="status"></p><div id="qtSheetBody" class="qt-copy"></div><form id="qtSheetForm" hidden><label for="qtSheetDraft">Sales process and objection responses</label><textarea id="qtSheetDraft" rows="14" required maxlength="50000" placeholder="Paste your agency’s sales process and objection sheet here…"></textarea><p id="qtSheetError" role="alert"></p><div class="qt-form-actions"><button type="button" id="qtSheetCancel" class="qt-secondary">Cancel</button><button type="submit" id="qtSheetSave" class="qt-primary">Save sheet</button></div></form></section></section><button type="button" id="qtLauncher" class="qt-launcher" aria-controls="qtPanel" aria-expanded="false">'+icon('tools')+'<span>Agent Tools</span><span id="qtActivity" class="qt-activity" hidden>Dialer active</span>'+icon('up')+'</button>';
  document.body.append(root);document.body.classList.add('has-quick-tools');
  const scopes=S.profile.role==='admin'?adminDivisionList():[S.profile.division];
  if(!scopes.includes(division))division=scopes[0]||S.profile.division;
  for(const id of scopes){const o=document.createElement('option');o.value=id;o.textContent=divisionLabel(id);$('#qtAgency').append(o);}$('#qtAgency').value=division;$('.qt-scope').hidden=scopes.length<2;
  $('#qtAgency').onchange=async e=>{if(editing&&!confirm('Discard the unsaved sheet before changing agency?')){e.target.value=division;return;}division=e.target.value;page=0;selected=null;sheet=null;editing=false;$('#qtSheetForm').hidden=true;await loadResources();};
  $('#qtLauncher').onclick=()=>setOpen(!opened);$('#qtMinimize').onclick=()=>{setOpen(false);$('#qtLauncher').focus();};
  root.addEventListener('keydown',e=>{if(e.key==='Escape'&&opened){e.preventDefault();setOpen(false);$('#qtLauncher').focus();}});
  for(const button of root.querySelectorAll('[data-qt-tab]')){button.onclick=()=>activate(button.dataset.qtTab);button.onkeydown=e=>{const keys=['scripts','dialer','process'],index=keys.indexOf(tab);let next;if(e.key==='ArrowRight')next=keys[(index+1)%3];if(e.key==='ArrowLeft')next=keys[(index+2)%3];if(e.key==='Home')next=keys[0];if(e.key==='End')next=keys[2];if(next){e.preventDefault();activate(next);$('#qtTab-'+next).focus();}};}
  $('#qtScript').onchange=e=>{selected=e.target.value;void loadScript();};$('#qtRefreshScripts').onclick=()=>loadResources();
  $('#qtPrevious').onclick=()=>{if(page>0){page--;void loadResources();}};$('#qtNext').onclick=()=>{if((page+1)*PAGE<total){page++;void loadResources();}};
  $('#qtDialerRetry').onclick=()=>mountDialer();$('#qtFullDialer').onclick=async()=>{try{await navigatePortalTab('power-dialer');if(S.tab==='power-dialer')setOpen(false);}catch(e){$('#qtDialerStatus').textContent=e.message;}};
  $('#qtEditSheet').onclick=()=>{editing=true;$('#qtSheetBody').hidden=true;$('#qtSheetForm').hidden=false;$('#qtSheetDraft').value=sheet?.body||'';$('#qtSheetDraft').focus();};
  $('#qtSheetCancel').onclick=()=>{editing=false;paintSheet();};$('#qtSheetForm').onsubmit=saveSheet;
  timer=setInterval(paintActivity,1000);setOpen(opened);
 }
 function activate(key){
  if(!allowed())return sync();tab=key;savePreference();
  for(const button of root.querySelectorAll('[data-qt-tab]')){const active=button.dataset.qtTab===tab;button.setAttribute('aria-selected',String(active));button.tabIndex=active?0:-1;$('#qtPane-'+button.dataset.qtTab).hidden=!active;}
  $('.qt-scope').hidden=tab==='dialer'||$('#qtAgency').options.length<2;
  if(portalDialerInstance?.root.closest('#portalQuickTools'))portalDialerInstance.setVisible?.(opened&&tab==='dialer');
  if(tab==='dialer')void mountDialer();else if(!root.dataset.loaded)void loadResources();
 }
 async function loadResources(){
  if(!allowed())return sync();const e=epoch,d=division,r=++request;bodyRequest++;
  root.dataset.loaded='';$('#qtScriptStatus').textContent='Loading scripts…';$('#qtScriptBody').textContent='';$('#qtScriptTitle').textContent='';$('#qtScript').disabled=true;
  if(!editing){$('#qtSheetBody').textContent='';$('#qtSheetStatus').textContent='Loading sheet…';$('#qtEditSheet').hidden=true;}
  const p=new URLSearchParams({select:'id,title,lead_type',division:'eq.'+d,lead_type:'neq.'+SHEET,order:'title.asc,id.asc',limit:String(PAGE),offset:String(page*PAGE)});
  const sheetParams=new URLSearchParams({select:'id,body',division:'eq.'+d,lead_type:'eq.'+SHEET,order:'created_at.desc,id.desc',limit:'1'});
  const [scriptsResult,sheetResult]=await Promise.allSettled([apiPage('/rest/v1/sales_scripts?'+p),api('/rest/v1/sales_scripts?'+sheetParams)]);
  if(!current(e,d)||r!==request)return;
  root.dataset.loaded='true';$('#qtScript').disabled=false;
  if(scriptsResult.status==='fulfilled'){
   rows=scriptsResult.value.data||[];total=Number(scriptsResult.value.count||rows.length);if(page&&page*PAGE>=total){page=Math.max(0,Math.ceil(total/PAGE)-1);return loadResources();}
   if(!rows.some(x=>x.id===selected))selected=rows[0]?.id||null;$('#qtScript').replaceChildren();
   for(const row of rows){const option=document.createElement('option');option.value=row.id;option.textContent=row.title;$('#qtScript').append(option);}$('#qtScript').value=selected||'';$('#qtScript').disabled=!rows.length;
   $('#qtScriptStatus').textContent=rows.length?'':S.profile.role==='admin'?'No scripts yet. Add your agency scripts from Sales scripts in the main menu.':'Your agency has not added scripts yet.';
   $('#qtScriptPages').hidden=total<=PAGE;$('#qtPageLabel').textContent=(page+1)+' / '+Math.max(1,Math.ceil(total/PAGE));$('#qtPrevious').disabled=page===0;$('#qtNext').disabled=(page+1)*PAGE>=total;
   if(selected)void loadScript();
  }else{$('#qtScriptStatus').textContent='Scripts could not load. Use Refresh to try again.';$('#qtScript').replaceChildren();$('#qtScript').disabled=true;$('#qtScriptPages').hidden=true;}
  if(!editing){if(sheetResult.status==='fulfilled'){sheet=sheetResult.value?.[0]||null;paintSheet();}else{$('#qtSheetStatus').textContent='The sheet could not load. Reopen Agent Tools or refresh Scripts to try again.';root.dataset.loaded='';}}
 }
 async function loadScript(){
  const e=epoch,d=division,id=selected,r=++bodyRequest;$('#qtScriptBody').textContent='';$('#qtScriptTitle').textContent='';$('#qtScriptStatus').textContent='Loading script…';
  try{const p=new URLSearchParams({select:'title,body',id:'eq.'+id,division:'eq.'+d,lead_type:'neq.'+SHEET,limit:'1'}),data=await api('/rest/v1/sales_scripts?'+p);if(!current(e,d)||r!==bodyRequest)return;$('#qtScriptTitle').textContent=data[0]?.title||'';$('#qtScriptBody').textContent=data[0]?.body||'';$('#qtScriptStatus').textContent=data.length?'':'This script is no longer available. Refresh the list.';}catch{if(current(e,d)&&r===bodyRequest)$('#qtScriptStatus').textContent='This script could not load. Use Refresh to try again.';}
 }
 function paintSheet(){if(editing)return;$('#qtSheetForm').hidden=true;$('#qtSheetBody').hidden=false;$('#qtSheetBody').textContent=sheet?.body||'';$('#qtSheetStatus').textContent=sheet?'':S.profile.role==='admin'?'Add your agency’s sales process and objection responses here.':'Your agency’s sales process / objection sheet will appear here once your admin adds it.';$('#qtEditSheet').hidden=S.profile.role!=='admin';$('#qtEditSheet').textContent=sheet?'Edit sheet':'Add sheet';}
 async function saveSheet(event){
  event.preventDefault();if(!allowed()||S.profile.role!=='admin'||$('#qtSheetSave').disabled)return;
  const body=$('#qtSheetDraft').value.trim();if(!body)return;const e=epoch,d=division,id=sheet?.id,save=$('#qtSheetSave');save.disabled=true;$('#qtSheetError').textContent='';
  try{const query=id?'?'+new URLSearchParams({id:'eq.'+id,division:'eq.'+d,lead_type:'eq.'+SHEET}):'',result=await api('/rest/v1/sales_scripts'+query,{method:id?'PATCH':'POST',headers:{Prefer:'return=representation'},body:id?{body}:{title:SHEET,lead_type:SHEET,body,division:d}});if(!current(e,d))return;if(!result?.length)throw Error('The sheet could not be saved. Refresh and try again.');sheet=result[0];editing=false;paintSheet();$('#qtSheetStatus').textContent='Saved for '+divisionLabel(d)+'.';}
  catch(error){if(current(e,d))$('#qtSheetError').textContent=error.message||'The sheet could not be saved.';}finally{if(save.isConnected)save.disabled=false;}
 }
 let dialerFlight=null;
 async function mountDialer(){
  if(!allowed()||!opened||tab!=='dialer')return;if(S.tab==='power-dialer'){sync();return;}
  if(dialerFlight)return dialerFlight;
  const e=epoch,slot=$('#qtDialerMount');$('#qtDialerStatus').hidden=false;$('#qtDialerStatus').textContent='Loading your dialer…';$('#qtDialerRetry').hidden=true;
  const flight=(async()=>{try{const instance=await ensurePortalDialer();if(!current(e)||!slot.isConnected)return;if(S.tab==='power-dialer')return sync();
   if(!instance.root.closest('#portalQuickTools')&&!instance.showQuickDialer()){$('#qtDialerStatus').textContent='Finish the current call or save its outcome in the full dialer before opening the mini dialer.';$('#qtDialerRetry').hidden=false;return;}
   instance.root.classList.add('qt-compact-dialer');slot.append(instance.root);instance.setVisible?.(opened&&tab==='dialer');$('#qtDialerStatus').hidden=true;
  }catch(error){if(current(e)){$('#qtDialerStatus').textContent=error.message||'The dialer could not load.';$('#qtDialerRetry').hidden=false;}}})();dialerFlight=flight;try{await flight;}finally{if(dialerFlight===flight)dialerFlight=null;}
 }
 function paintActivity(){if(!root)return;if(!allowed()||owner!==S.profile.id){reset();return;}const active=!!portalDialerInstance?.quickCallActive?.();$('#qtActivity').hidden=!active;$('#qtLauncher').classList.toggle('qt-calling',active);}
 window.PortalQuickTools={sync,reset};
})();
