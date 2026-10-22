'use strict';
const fs=require('node:fs'),vm=require('node:vm'),assert=require('node:assert/strict'),{JSDOM}=require('jsdom');
const source=fs.readFileSync('portal-app.js','utf8');
const deferred=()=>{let resolve;const promise=new Promise(r=>resolve=r);return {promise,resolve};};
function fixture(role='agent'){
 const dom=new JSDOM('<body><main id="app"></main></body>',{url:'https://www.lldportal.com'}),w=dom.window;
 const lead={id:'lead-1',first_name:'Test client',status:'assigned',lead_type:'Folder',state:'MI',assigned_to:'agent'};
 const S={profile:{id:'agent',role},tab:'my-leads',leads:[lead],myCount:1,myPage:1,pageSize:500,mySearch:'',myFolder:{type:'Folder'},myStates:['MI'],myFolders:[{lead_type:'Folder',lead_count:1}],myStateOptions:[{state:'MI',lead_count:1}],selected:new Set(['lead-1']),msg:'',err:''};
 const calls=[];const c={S,window:w,document:w.document,portalSessionEpoch:0,FormData:w.FormData,console,
  q:s=>w.document.querySelector(s),qa:s=>[...w.document.querySelectorAll(s)],
  esc:s=>String(s??''),csvColumns:()=>[],leadStatusBar:()=>'',myLeadFolders:()=>'',myLeadStates:()=>'',myLeadSearchBar:()=>'',pager:()=>'',pageCount:n=>Math.max(1,Math.ceil(n/500)),scheduleFeedbackClear(){},
  portalCarrierSelectHtml:()=>'<select name="p_carrier" id="closedDealCarrier"><option>Ethos</option></select>',portalFillDealCarriers(){},
  api:async(path,opt)=>{calls.push({path,body:opt.body});return path.endsWith('close_lead')?'deal-1':path.endsWith('my_lead_folders')?[]:{data:[],count:0,states:[]};},
 };
 w.PortalCallNotes={flush:async()=>true};
 vm.createContext(c);
 for(const name of ['loadMyFolders','loadMyLeadsPage','myLeads','modal','closeModal'])vm.runInContext(source.split('\n').find(s=>s.startsWith('function '+name+'(')||s.startsWith('async function '+name+'(')),c);
 vm.runInContext(source.slice(source.indexOf('function removeClosedLeadFromLists('),source.indexOf('\nasync function reload(m)')),c);
 c.render=()=>{w.document.getElementById('app').innerHTML=c.myLeads();};
 c.flash=(m,bad)=>{S[bad?'err':'msg']=m;c.render();};
 function open(){c.closeLeadModal(lead.id);const form=c.q('#cf');form.elements.p_monthly_premium.value='125';form.elements.p_policy_type.value='Term';return form;}
 const submit=form=>form.onsubmit({preventDefault(){},target:form});
 c.render();return {c,S,lead,calls,open,submit,close:()=>w.close()};
}
(async()=>{
 // A committed close must remove the row even when both refresh calls fail.
 for(const role of ['agent','admin']){
  const f=fixture(role);try{
   f.c.api=async(path,opt)=>{f.calls.push({path,body:opt.body});if(path.endsWith('close_lead'))return 'deal';throw Error('statement timeout');};
   await f.submit(f.open());assert.equal(f.S.leads.length,0);assert.equal(f.c.q('.closeLead'),null);assert.equal(f.c.q('#modal'),null);
   assert.equal(f.S.myCount,0);assert.equal(f.S.myFolders.length,0);assert.equal(f.S.myStateOptions.length,0);assert.equal(f.S.selected.size,0);
   assert.match(f.S.err,/saved as closed/);assert.equal(f.calls.length,3);assert(!f.calls.some(x=>/account_bootstrap|my_team_info/.test(x.path)));
  }finally{f.close();}
 }
 // Duplicate submits while saving send one mutation; old reads cannot resurrect the row.
 const f=fixture();try{
  const old=deferred(),save=deferred();let first=true;
  f.c.api=async(path,opt)=>{f.calls.push({path,body:opt.body});if(path.endsWith('close_lead'))return save.promise;if(path.endsWith('my_lead_folders'))return [];if(first){first=false;return old.promise;}return {data:[],count:0,states:[]};};
  const prior=f.c.loadMyLeadsPage(),form=f.open(),pending=f.submit(form);await new Promise(r=>setImmediate(r));
  assert(form.querySelector('button').disabled);await f.submit(form);assert.equal(f.calls.filter(x=>x.path.endsWith('close_lead')).length,1);
  save.resolve('deal');await pending;old.resolve({data:[f.lead],count:1,states:[{state:'MI',lead_count:1}]});await prior;
  assert.equal(f.S.leads.length,0);assert.equal(f.S.myCount,0);assert.equal(f.c.q('.closeLead'),null);
 }finally{f.close();}
 // A rejected save leaves the lead available and the form retryable.
 const failed=fixture();try{
  failed.c.api=async()=>{throw Error('Save rejected');};const form=failed.open();await failed.submit(form);
  assert.equal(failed.S.leads.length,1);assert(failed.c.q('.closeLead'));assert(!form.querySelector('button').disabled);assert.match(failed.S.err,/Save rejected/);
 }finally{failed.close();}
 // Unsaved notes prevent the mutation; late results cannot touch another account.
 const notes=fixture();try{notes.c.window.PortalCallNotes.flush=async()=>false;await notes.submit(notes.open());assert.equal(notes.calls.length,0);assert.equal(notes.S.leads.length,1);}finally{notes.close();}
 const account=fixture();try{
  const wait=deferred();account.c.api=()=>wait.promise;const pending=account.submit(account.open());await new Promise(r=>setImmediate(r));
  account.S.profile={id:'other',role:'agent'};account.c.portalSessionEpoch++;account.S.leads=[{id:'other-lead'}];wait.resolve('deal');await pending;
  assert.equal(account.S.leads[0].id,'other-lead');assert.equal(account.S.myCount,1);
 }finally{account.close();}
 // Old filter/folder requests also cannot overwrite newer reads.
 const race=fixture();try{
  const wait=deferred();let first=true;race.c.api=async()=>first?(first=false,wait.promise):[{lead_type:'New',lead_count:3}];
  const pending=race.c.loadMyFolders();await race.c.loadMyFolders();wait.resolve([{lead_type:'Old',lead_count:9}]);await pending;
  assert.equal(race.S.myFolders[0].lead_type,'New');
 }finally{race.close();}
 console.log('PASS: agent/admin close, refresh failure, immediate row/count removal, double submit, stale reads, save rejection, notes gate and account isolation.');
})().catch(e=>{console.error(e);process.exitCode=1;});
