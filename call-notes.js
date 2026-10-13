/* One in-memory draft per lead and signed-in session, shared by both notes views. */
(() => {
 'use strict';
 const entries=new Map();let owner=null,banner=null,review=null,myBindings=[];
 const identity=()=>typeof S!=='undefined'&&S.session&&S.profile?.id===S.session.user?.id?S.profile.id+':'+portalSessionEpoch:null;
 // Match PostgreSQL btrim (spaces), preserving line breaks in the user's draft.
 const normalized=value=>String(value??'').replace(/^ +| +$/g,'')||null;
 const dirty=e=>normalized(e.text)!==normalized(e.base);
 const pending=e=>dirty(e)||!!e.flight||e.status==='conflict'||e.status==='error';
 function reset(){for(const e of entries.values()){clearTimeout(e.timer);for(const b of [...e.bindings]){b.input.value='';b.dispose();}}entries.clear();banner?.remove();banner=null;review?.remove();review=null;owner=identity();}
 function sync(){if(owner!==identity())reset();return !!owner;}
 function valid(e){return sync()&&entries.get(e.id)===e&&e.owner===owner;}
 function acknowledge(e,value){e.base=value;for(const lead of e.leads)lead.call_notes=value;const lead=typeof S!=='undefined'?S.leads?.find(l=>l.id===e.id):null;if(lead)lead.call_notes=value;}
 function entry(lead){if(!sync())return null;let e=entries.get(lead.id);if(!e){e={id:lead.id,owner,label:[lead.first_name,lead.last_name].filter(Boolean).join(' ')||lead.lead_type||'Lead',base:lead.call_notes??null,text:lead.call_notes||'',status:'idle',bindings:new Set(),leads:new Set(),timer:null,flight:null,error:'',remote:null};entries.set(e.id,e);}else if(!pending(e)&&!e.leads.has(lead)&&e.base!==(lead.call_notes??null)){acknowledge(e,lead.call_notes??null);e.text=lead.call_notes||'';e.status='idle';}e.leads.add(lead);return e;}
 function button(label,action){const b=document.createElement('button');b.type='button';b.className='note-action';b.textContent=label;b.onclick=action;return b;}
 function refreshBanner(){
  const failed=[...entries.values()].filter(e=>e.status==='error'||e.status==='conflict');
  if(!failed.length){banner?.remove();banner=null;return;}
  if(!banner){banner=document.createElement('aside');banner.className='notes-save-notice';banner.setAttribute('role','status');document.body.append(banner);}
  banner.replaceChildren();const text=document.createElement('span');text.textContent=failed.length+' call '+(failed.length===1?'note needs':'notes need')+' attention. Your drafts are still here.';banner.append(text,button('Review notes',openReview));
 }
 function paint(e){
  if(!valid(e))return;
  for(const b of e.bindings){
   if(b.input.value!==e.text)b.input.value=e.text;
   b.panel.dataset.state=e.status;
   b.status.textContent=e.status==='saving'?'Saving…':e.status==='pending'?'Waiting to save…':e.status==='saved'?'Saved':e.status==='error'?'Not saved. '+e.error:e.status==='conflict'?'This note changed in another window. Choose which version to keep.':'Notes save automatically';
   b.save.textContent=e.status==='error'?'Retry':'Save now';b.save.hidden=e.status==='conflict'||(!dirty(e)&&e.status!=='error');b.save.disabled=!!e.flight;
   b.mine.hidden=b.saved.hidden=b.remote.hidden=e.status!=='conflict';b.remote.textContent=e.status==='conflict'?'Saved note: '+(e.remote||'(empty)'):'';
  }
  refreshBanner();
 }
 function edit(e,text){if(!e||!valid(e))return;e.text=text;clearTimeout(e.timer);if(e.status==='conflict'){paint(e);return;}e.status=e.flight?'saving':(dirty(e)||e.uncertain)?'pending':'saved';e.error='';paint(e);if((dirty(e)||e.uncertain)&&!e.flight)e.timer=setTimeout(()=>flush(e.id),900);}
 async function flush(id){
  if(!sync())return false;const e=entries.get(id);if(!e)return true;clearTimeout(e.timer);
  if(e.flight)return e.flight;
  if(e.status==='conflict')return false;
  if(!dirty(e)&&!e.uncertain){e.status='saved';paint(e);return true;}
  // Start in a microtask so all callers share the same promise, even on sync errors.
  e.flight=Promise.resolve().then(async()=>{
   try{
    while(valid(e)&&(dirty(e)||e.uncertain)){
     const text=e.text;e.status='saving';paint(e);
     const response=await api('/rest/v1/rpc/save_lead_call_notes',{method:'POST',body:{p_lead_id:e.id,p_notes:text,p_expected_notes:e.base}});
     if(!valid(e))return false;
     if(typeof response?.saved!=='boolean'||!(response.notes===null||typeof response.notes==='string'))throw Error('Unexpected save response. Please retry.');
     e.uncertain=false;
     if(!response.saved){e.remote=response.notes;e.status='conflict';return false;}
     acknowledge(e,response.notes);
    }
    if(!valid(e))return false;e.status='saved';e.error='';return true;
   }catch(error){if(valid(e)){e.uncertain=true;e.status='error';e.error=error.message||'Check your connection and retry.';}return false;}
   finally{e.flight=null;if(valid(e))paint(e);}
  });paint(e);return e.flight;
 }
 function bind(lead,input,saveButton){
  const e=entry(lead);if(!e||!input)return ()=>{};
  const panel=document.createElement('div');panel.className='note-save-state';
  const status=document.createElement('span');status.setAttribute('role','status');status.setAttribute('aria-live','polite');
  const save=saveButton||button('Save now',()=>flush(e.id));save.type='button';save.onclick=()=>flush(e.id);
  const mine=button('Keep my draft',()=>{if(!valid(e))return;acknowledge(e,e.remote);e.status='pending';flush(e.id);});
  const saved=button('Use saved note',()=>{if(!valid(e))return;clearTimeout(e.timer);acknowledge(e,e.remote);e.text=e.base||'';e.status='saved';paint(e);});
  const remote=document.createElement('pre');remote.className='note-saved-copy';
  panel.append(status,save,remote,mine,saved);input.insertAdjacentElement('afterend',panel);
  const onInput=()=>edit(e,input.value),onBlur=()=>{if(e.status==='pending')flush(e.id);};
  const b={input,panel,status,save,mine,saved,remote,dispose(){input.removeEventListener('input',onInput);input.removeEventListener('blur',onBlur);e.bindings.delete(b);panel.remove();}};
  e.bindings.add(b);input.addEventListener('input',onInput);input.addEventListener('blur',onBlur);input.maxLength=10000;
  // A new surface adopts the shared draft. It never replaces an unsaved edit.
  input.value=e.text;paint(e);return b.dispose;
 }
 async function flushAll(){if(!sync())return true;const key=owner;const results=await Promise.all([...entries.values()].filter(pending).map(e=>flush(e.id)));return identity()===key&&results.every(Boolean)&&![...entries.values()].some(pending);}
 function openReview(){
  if(!sync())return;if(review)review.close();review=document.createElement('dialog');review.className='notes-review';
  const title=document.createElement('h2');title.textContent='Unsaved call notes';review.append(title);
  const cleanups=[];
  for(const e of entries.values()){if(!pending(e))continue;const section=document.createElement('section'),label=document.createElement('label'),input=document.createElement('textarea');label.textContent=e.label;input.id='review-note-'+e.id;label.htmlFor=input.id;section.append(label,input);review.append(section);document.body.append(review);cleanups.push(bind([...e.leads][0],input));section.append(button('Discard draft',()=>{if(!valid(e)||e.flight)return;if(!confirm('Discard this unsaved call note?'))return;clearTimeout(e.timer);if(e.status==='conflict')acknowledge(e,e.remote);e.text=e.base||'';e.uncertain=false;e.status='idle';paint(e);section.remove();}));}
  review.append(button('Done',()=>review.close()));document.body.append(review);review.addEventListener('close',()=>{cleanups.forEach(fn=>fn());review?.remove();review=null;},{once:true});review.showModal();
 }
 function clearMyLeads(){myBindings.forEach(fn=>fn());myBindings=[];}
 function bindMyLeads(){clearMyLeads();if(!sync())return;for(const [id,e] of entries)if(!e.bindings.size&&!pending(e))entries.delete(id);document.querySelectorAll('.saveCallNotes').forEach(b=>{const l=S.leads.find(x=>x.id===b.dataset.id);if(l)myBindings.push(bind(l,document.getElementById('callnotes-'+l.id),b));});}
 window.PortalCallNotes={bind,bindMyLeads,clearMyLeads,flush,flushAll,reset,sync,openReview,
  edit(lead,text){edit(entry(lead),text);},
  hasPending(){return sync()&&[...entries.values()].some(pending);},
  async beforeLogout(){if(await flushAll())return true;openReview();return false;}
 };
 window.addEventListener('beforeunload',event=>{if(window.PortalCallNotes.hasPending()){event.preventDefault();event.returnValue='';}});
 window.addEventListener('online',()=>{if(sync())for(const e of entries.values())if(e.status==='error')flush(e.id);});
 document.addEventListener('visibilitychange',()=>{if(document.hidden&&sync())for(const e of entries.values())if(e.status==='pending')flush(e.id);});
})();
