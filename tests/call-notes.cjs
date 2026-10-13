'use strict';
const fs=require('node:fs'),assert=require('node:assert/strict'),{JSDOM}=require('jsdom');
const source=fs.readFileSync(__dirname+'/../call-notes.js','utf8');
const tick=()=>new Promise(r=>setImmediate(r));
const deferred=()=>{let resolve,reject;const promise=new Promise((a,b)=>{resolve=a;reject=b;});return {promise,resolve,reject};};
function setup(){
 const dom=new JSDOM('<body><main></main></body>',{url:'https://portal.test',runScripts:'outside-only'}),w=dom.window;
 const timers=new Map();let seq=0;w.setTimeout=fn=>{timers.set(++seq,fn);return seq;};w.clearTimeout=id=>timers.delete(id);
 w.S={session:{user:{id:'agent'}},profile:{id:'agent'},leads:[]};w.portalSessionEpoch=0;w.confirm=()=>true;
 w.HTMLDialogElement.prototype.showModal=function(){this.open=true;};w.HTMLDialogElement.prototype.close=function(){this.dispatchEvent(new w.Event('close'));};
 const requests=[];w.api=async(path,options)=>{requests.push({path,...options.body});return {saved:true,notes:options.body.p_notes.replace(/^ +| +$/g,'')||null};};
 w.eval(source);const notes=w.PortalCallNotes;
 function bind(lead){const input=w.document.createElement('textarea');w.document.querySelector('main').append(input);const dispose=notes.bind(lead,input);return {input,dispose};}
 function type(input,text){input.value=text;input.dispatchEvent(new w.Event('input'));}
 function debounce(){const pending=[...timers.values()];timers.clear();pending.forEach(fn=>fn());}
 return {dom,w,notes,requests,bind,type,debounce,timers};
}
(async()=>{
 const t=setup(),{w,notes,requests,bind,type}=t;try{
  const lead={id:'one',first_name:'Test',call_notes:null};w.S.leads=[lead];const a=bind(lead),b=bind(lead);
  type(a.input,'first');type(a.input,'latest');assert.equal(requests.length,0);assert.equal(t.timers.size,1);assert.equal(b.input.value,'latest');
  t.debounce();await tick();assert.equal(requests.length,1);assert.equal(requests[0].p_notes,'latest');assert.equal(lead.call_notes,'latest');assert.equal(notes.hasPending(),false);assert(w.document.body.textContent.includes('Saved'));
  const gate=deferred();w.api=(path,opt)=>{requests.push(opt.body);return gate.promise;};type(a.input,'in flight');const saving=notes.flush('one');await tick();type(b.input,'newer typing');assert.equal(requests.length,2);
  w.api=async(path,opt)=>{requests.push(opt.body);return {saved:true,notes:opt.body.p_notes};};gate.resolve({saved:true,notes:'in flight'});assert.equal(await saving,true);assert.equal(requests.length,3);assert.equal(requests[2].p_expected_notes,'in flight');assert.equal(a.input.value,'newer typing');assert.equal(lead.call_notes,'newer typing');
  // Detached dialer bindings keep working when its cached root is reattached.
  b.input.parentElement.removeChild(b.input);type(a.input,'cached view');await notes.flush('one');assert.equal(b.input.value,'cached view');w.document.querySelector('main').append(b.input);
  w.api=async()=>{throw Error('Offline');};type(a.input,'keep my draft');assert.equal(await notes.flush('one'),false);assert.equal(a.input.value,'keep my draft');assert(w.document.querySelector('.notes-save-notice'));assert.equal(notes.hasPending(),true);
  const unload=new w.Event('beforeunload',{cancelable:true});w.dispatchEvent(unload);assert(unload.defaultPrevented);
  a.dispose();a.input.remove();const rerender=bind({...lead});assert.equal(rerender.input.value,'keep my draft');assert.equal(await notes.beforeLogout(),false);assert(w.document.querySelector('dialog').open);
  w.document.querySelector('dialog').close();w.api=async(path,opt)=>({saved:true,notes:opt.body.p_notes});assert.equal(await notes.flushAll(),true);assert.equal(notes.hasPending(),false);assert.equal(w.document.querySelector('.notes-save-notice'),null);
  // A lost response is uncertain even if the user restores the original text.
  const old=lead.call_notes;w.api=async()=>{throw Error('Lost response');};type(rerender.input,'possibly saved');await notes.flush('one');type(rerender.input,old);let retries=0;w.api=async()=>{retries++;return {saved:false,notes:'possibly saved'};};assert.equal(await notes.flush('one'),false);assert.equal(retries,1);
  const panel=rerender.input.nextElementSibling;assert.equal(panel.dataset.state,'conflict');assert.equal(rerender.input.value,old);assert(panel.textContent.includes('possibly saved'));
  w.api=async(path,opt)=>{assert.equal(opt.body.p_expected_notes,'possibly saved');return {saved:true,notes:opt.body.p_notes};};[...panel.querySelectorAll('button')].find(b=>b.textContent==='Keep my draft').click();await tick();assert.equal(notes.hasPending(),false);
  type(rerender.input,'draft again');w.api=async()=>({saved:false,notes:'other window'});await notes.flush('one');[...panel.querySelectorAll('button')].find(b=>b.textContent==='Use saved note').click();assert.equal(rerender.input.value,'other window');assert.equal(lead.call_notes,'other window');assert.equal(notes.hasPending(),false);
  // Separate leads do not block one another, and account changes drop all old drafts.
  const other={id:'two',call_notes:null},c=bind(other),late=deferred();w.api=async(path,opt)=>opt.body.p_lead_id==='one'?late.promise:{saved:true,notes:opt.body.p_notes};type(rerender.input,'old account');const lateSave=notes.flush('one');await tick();type(c.input,'independent');assert.equal(await notes.flush('two'),true);assert.equal(other.call_notes,'independent');
  w.S={session:{user:{id:'other-agent'}},profile:{id:'other-agent'},leads:[]};w.portalSessionEpoch++;notes.sync();assert.equal(rerender.input.value,'');assert.equal(c.input.value,'');assert.equal(notes.hasPending(),false);late.resolve({saved:true,notes:'old account'});assert.equal(await lateSave,false);assert.equal(lead.call_notes,'other window');assert.equal(t.timers.size,0);
  const fresh=bind({id:'one',call_notes:'new account note'});assert.equal(fresh.input.value,'new account note');
  console.log('PASS: debounce, shared inputs, serialized saves, detached views, retry, rerender drafts, unload/logout protection, lost responses, conflict choices, independent leads and account isolation.');
 }finally{t.dom.window.close();}
})().catch(e=>{console.error(e);process.exitCode=1;});
